/*
 * Copyright (c) 2010-2011 Apple Inc. All rights reserved.
 *
 * @APPLE_LICENSE_HEADER_START@
 * 
 * This file contains Original Code and/or Modifications of Original Code
 * as defined in and that are subject to the Apple Public Source License
 * Version 2.0 (the 'License'). You may not use this file except in
 * compliance with the License. Please obtain a copy of the License at
 * http://www.opensource.apple.com/apsl/ and read it before using this
 * file.
 * 
 * The Original Code and all software distributed under the License are
 * distributed on an 'AS IS' basis, WITHOUT WARRANTY OF ANY KIND, EITHER
 * EXPRESS OR IMPLIED, AND APPLE HEREBY DISCLAIMS ALL SUCH WARRANTIES,
 * INCLUDING WITHOUT LIMITATION, ANY WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE, QUIET ENJOYMENT OR NON-INFRINGEMENT.
 * Please see the License for the specific language governing rights and
 * limitations under the License.
 * 
 * @APPLE_LICENSE_HEADER_END@
 */

#include "objc-private.h"

#include "objc-weak.h"

#include <stdint.h>
#include <stdbool.h>
#include <sys/types.h>
#include <libkern/OSAtomic.h>

#define TABLE_SIZE(entry) (entry->mask ? entry->mask + 1 : 0)
// 有些函数依赖这个函数，所以提前声明一下。
static void append_referrer(weak_entry_t *entry, objc_object **new_referrer);

// 参考链接:GCC扩展 attribute ((visibility("hidden")))
BREAKPOINT_FUNCTION(
    void objc_weak_error(void)
);

/**
 _objc_fatal 用来退出程序或者中止运行并打印原因。
  这里表示 weak_table_t 中的的某个 weak_entry_t 发生了内存错误，全局搜索发现该函数只会在发生 hash 冲突时 index 持续增加直到和 begin 相等时被调用。
 */
static void bad_weak_table(weak_entry_t *entries)
{
    _objc_fatal("bad weak table at %p. This may be a runtime bug or a "
                "memory error somewhere else.", entries);
}

/** 
 * Unique hash function for object pointers only.
 * 唯一的哈希函数仅适用于对象指针。对一个 objc_object 对象的指针求哈希值，用于从 weak_table_t 哈希表中取得对象对应的 weak_entry_t。
 * @param key The object pointer
 * 
 * @return Size unrestricted hash of pointer.
 */
static inline uintptr_t hash_pointer(objc_object *key) {
    // 把指针强转为 unsigned long，然后调用 ptr_hash 函数
    return ptr_hash((uintptr_t)key);
}

/** 
 * Unique hash function for weak object pointers only.
 * 对一个 objc_object 对象的指针的指针（此处指 weak 变量的地址）求哈希值，
 * 用于从 weak_entry_t 哈希表中取得 weak_referrer_t，把其保存的弱引用变量的指向置为 nil 或者从哈希表中移除等。
 * @param key The weak object pointer. 
 * 
 * @return Size unrestricted hash of pointer.
 */
static inline uintptr_t w_hash_pointer(objc_object **key) {
    return ptr_hash((uintptr_t)key);
}

/** 
 * Grow the entry's hash table of referrers. Rehashes each
 * of the referrers.
 * 对 weak_entry_t 的哈希数组进行扩容，并插入一个新的 new_referrer，原有数据重新哈希化放在新空间内。
 * @param entry Weak pointer hash set for a particular object.
 */
__attribute__((noinline, used))
static void grow_refs_and_insert(weak_entry_t *entry, 
                                 objc_object **new_referrer)
{
    // DEBUG 下的断言，确保当前 weak_entry_t 使用的是 hash 数组模式
    ASSERT(entry->out_of_line());

    size_t old_size = TABLE_SIZE(entry);
    size_t new_size = old_size ? old_size * 2 : 8;

    // 记录当前已使用容量
    size_t num_refs = entry->num_refs;
    // 记录旧哈希数组起始地址，在最后要进行释放
    weak_referrer_t *old_refs = entry->referrers;
    // mask 依然是总容量减 1
    entry->mask = new_size - 1;
    
    // 为新 hash 数组申请空间
    // 长度为：总容量 * sizeof(weak_referrer_t)（8）个字节
    entry->referrers = (weak_referrer_t *)
        calloc(TABLE_SIZE(entry), sizeof(weak_referrer_t));
    entry->num_refs = 0;
    entry->max_hash_displacement = 0;
    
    for (size_t i = 0; i < old_size && num_refs > 0; i++) {
        if (old_refs[i] != nil) {
            // 把旧哈希数组里的数据都放进新哈希数组内
            append_referrer(entry, old_refs[i]);
            num_refs--;
        }
    }
    // Insert. 然后把入参传入的 new_referrer，插入新哈希数组，前面的铺垫都是在做 "数据转移"
    append_referrer(entry, new_referrer);
    // 把旧哈希数据释放
    if (old_refs) free(old_refs);
}

/** 
 * Add the given referrer to set of weak pointers in this entry.
 * Does not perform duplicate checking (b/c weak pointers are never
 * added to a set twice). 
 * 添加给定的 referrer 到 weak_entry_t 的哈希数组（或定长为 4 的内部数组）。不执行重复检查，weak 指针永远不会添加两次。
 * @param entry The entry holding the set of weak pointers. 
 * @param new_referrer The new weak pointer to be added.
 */
static void append_referrer(weak_entry_t *entry, objc_object **new_referrer)
{
    if (! entry->out_of_line()) {
        // Try to insert inline.
        // 如果 weak_entry 尚未使用哈希数组，走这里
        for (size_t i = 0; i < WEAK_INLINE_COUNT; i++) {
            // 找到空位把 new_referrer 放进去
            if (entry->inline_referrers[i] == nil) {
                entry->inline_referrers[i] = new_referrer;
                return;
            }
        }

        // Couldn't insert inline. Allocate out of line.
        // 如果 inline_referrers 存满了，则要转到 referrers 哈希数组
        // 为哈希数组申请空间
        weak_referrer_t *new_referrers = (weak_referrer_t *)
            calloc(WEAK_INLINE_COUNT, sizeof(weak_referrer_t));
        // This constructed table is invalid, but grow_refs_and_insert
        // will fix it and rehash it.
        // 把 inline_referrers 内部的数据放进 hash 数组
        // 这里看似是直接循环按下标放的，其实后面会进行扩容和哈希化
        // 目前还只是把原来的4个放到新开辟的哈希数组中。还没有处理待添加的referrer
        for (size_t i = 0; i < WEAK_INLINE_COUNT; i++) {
            new_referrers[i] = entry->inline_referrers[i];
        }
        entry->referrers = new_referrers;
        entry->num_refs = WEAK_INLINE_COUNT;    // 表示目前弱引用是 4
        entry->out_of_line_ness = REFERRERS_OUT_OF_LINE;    // 标记 weak_entry_t 开始使用哈希数组保存弱引用的指针
        entry->mask = WEAK_INLINE_COUNT-1;  // mask 赋值，总容量减 1
        entry->max_hash_displacement = 0;   // 此时哈希冲突偏移为 0
    }

    // 以下都是对于哈希数组的添加referrer处理，会涉及扩容处理
    
    // 断言： 此时一定使用的动态数组
    ASSERT(entry->out_of_line());
    
    // 扩容判断：如果大于总容量的 3/4
    if (entry->num_refs >= TABLE_SIZE(entry) * 3/4) {
        // weak_entry_t 哈希数组扩容并插入 new_referrer
        return grow_refs_and_insert(entry, new_referrer);
    }
    
    // 不需要扩容，则进行正常插入
    size_t begin = w_hash_pointer(new_referrer) & (entry->mask);
    size_t index = begin;
    size_t hash_displacement = 0;
    while (entry->referrers[index] != nil) {
        hash_displacement++;
        index = (index+1) & entry->mask;
        // 在 index == begin 之前一定能找到空位置，因为前面已经有一个超过 3/4 占用后的扩容机制，
        if (index == begin) bad_weak_table(entry);
    }
    // 更新最大偏移值
    if (hash_displacement > entry->max_hash_displacement) {
        entry->max_hash_displacement = hash_displacement;
    }
    // 找到空位置放入弱引用的指针
    weak_referrer_t &ref = entry->referrers[index];
    ref = new_referrer;
    entry->num_refs++;  // 自增
}

/** 
 * Remove old_referrer from set of referrers, if it's present.
 * Does not remove duplicates, because duplicates should not exist. 
 * 从 weak_entry_t 中删除弱引用的地址。
 * @todo this is slow if old_referrer is not present. Is this ever the case? 
 *
 * @param entry The entry holding the referrers.
 * @param old_referrer The referrer to remove. 
 */
static void remove_referrer(weak_entry_t *entry, objc_object **old_referrer)
{
    // 如果目前使用的是定长为 4 的内部数组
    if (! entry->out_of_line()) {
        // 循环找到 old_referrer 的位置，把它的原位置放置 nil，表示把 old_referrer 从数组中移除了
        for (size_t i = 0; i < WEAK_INLINE_COUNT; i++) {
            if (entry->inline_referrers[i] == old_referrer) {
                entry->inline_referrers[i] = nil;
                return;
            }
        }
        // 如果当前 weak_entry_t 不包含传入的 old_referrer
        // 则明显发生了错误，执行 objc_weak_error 函数
        _objc_inform("Attempted to unregister unknown __weak variable "
                     "at %p. This is probably incorrect use of "
                     "objc_storeWeak() and objc_loadWeak(). "
                     "Break on objc_weak_error to debug.\n", 
                     old_referrer);
        objc_weak_error();
        return;
    }

    // 从 hash 数组中找到 old_referrer 并置为 nil（移除 old_referrer）
    size_t begin = w_hash_pointer(old_referrer) & (entry->mask);
    size_t index = begin;
    size_t hash_displacement = 0;
    while (entry->referrers[index] != old_referrer) {
        index = (index+1) & entry->mask;
        if (index == begin) bad_weak_table(entry);
        hash_displacement++;
        if (hash_displacement > entry->max_hash_displacement) {
            _objc_inform("Attempted to unregister unknown __weak variable "
                         "at %p. This is probably incorrect use of "
                         "objc_storeWeak() and objc_loadWeak(). "
                         "Break on objc_weak_error to debug.\n", 
                         old_referrer);
            objc_weak_error();
            return;
        }
    }
    // 把 old_referrer 所在的位置置为 nil，num_refs 自减
    entry->referrers[index] = nil;
    entry->num_refs--;
}

/** 
 * Add new_entry to the object's table of weak references.
 * Does not check whether the referent is already in the table.
 * 添加一个新的 weak_entry_t 到给定的 weak_table_t 的哈希数组中. 不检查 referent 是否已在 weak_table_t 中。
 */
static void weak_entry_insert(weak_table_t *weak_table, weak_entry_t *new_entry)
{
    weak_entry_t *weak_entries = weak_table->weak_entries;
    ASSERT(weak_entries != nil);

    size_t begin = hash_pointer(new_entry->referent) & (weak_table->mask);
    size_t index = begin;
    size_t hash_displacement = 0;
    while (weak_entries[index].referent != nil) {
        index = (index+1) & weak_table->mask;
        if (index == begin) bad_weak_table(weak_entries);
        // 记录偏移值，用于更新 max_hash_displacement
        hash_displacement++;
    }

    // new_entry 放入哈希数组
    weak_entries[index] = *new_entry;
    weak_table->num_entries++;

    // 此步操作正记录了 weak_table_t 哈希数组发生哈希冲突时的最大偏移值
    if (hash_displacement > weak_table->max_hash_displacement) {
        weak_table->max_hash_displacement = hash_displacement;
    }
}

// 调整 weak_table_t 哈希数组的容量大小，并把原始哈希数组里面的 weak_entry_t 重新哈希化放进新空间内。
static void weak_resize(weak_table_t *weak_table, size_t new_size)
{
    size_t old_size = TABLE_SIZE(weak_table);

    weak_entry_t *old_entries = weak_table->weak_entries;
    weak_entry_t *new_entries = (weak_entry_t *)
        calloc(new_size, sizeof(weak_entry_t));

    weak_table->mask = new_size - 1;
    weak_table->weak_entries = new_entries;
    weak_table->max_hash_displacement = 0;
    weak_table->num_entries = 0;  // restored by weak_entry_insert below
    
    if (old_entries) {
        weak_entry_t *entry;
        weak_entry_t *end = old_entries + old_size;
        // 注意指针+1 = 指针P + sizeof（指针的类型） *  1
        // 这算是一个很古老的C语言知识了，不过我们用纯OC时，真的很少用
        for (entry = old_entries; entry < end; entry++) {
            if (entry->referent) {
                weak_entry_insert(weak_table, entry);
            }
        }
        free(old_entries);
    }
}

// Grow the given zone's table of weak references if it is full.
// 判断 weak_table_t 的哈希数组的占用长度情况，如有必要则进行扩容。
static void weak_grow_maybe(weak_table_t *weak_table)
{
    // #define TABLE_SIZE(entry) (entry->mask ? entry->mask + 1 : 0)
    // mask + 1 表示当前 weak_table 哈希数组的总长度
    size_t old_size = TABLE_SIZE(weak_table);

    // Grow if at least 3/4 full.
    // 如果目前哈希数组中存储的 weak_entry_t 的数量超过了总长度的 3/4，则进行扩容
    if (weak_table->num_entries >= old_size * 3 / 4) {
        // 如果是 weak_table 是新建的，则初始其哈希数组长度为 64，如果是非空，则扩容为之前长度的两倍
        weak_resize(weak_table, old_size ? old_size*2 : 64);
    }
}

// Shrink the table if it is mostly empty.
// 即当 weak_table_t 的 weak_entry_t *weak_entries 数组大部分空间为空的情况下，缩小 weak_entries 的长度
static void weak_compact_maybe(weak_table_t *weak_table)
{
    // 统计当前哈希数组的总长度
    size_t old_size = TABLE_SIZE(weak_table);

    // Shrink if larger than 1024 buckets and at most 1/16 full.
    // old_size 超过了 1024 并且 低于 1/16 的空间占用率，则进行缩小
    if (old_size >= 1024  && old_size / 16 >= weak_table->num_entries) {
        // 缩小容量为 ols_size 的 1/8
        weak_resize(weak_table, old_size / 8);
        // leaves new table no more than 1/2 full
        // 缩小为 1/8 和上面的空间占用少于 1/16，两个条件合并在一起，保证缩小后的容量占用少于 1/2
    }
}


/**
 * Remove entry from the zone's table of weak references.
 * 从 weak_table_t 的哈希数组中删除指定的 weak_entry_t。
 */
static void weak_entry_remove(weak_table_t *weak_table, weak_entry_t *entry)
{
    // remove entry
    if (entry->out_of_line()) free(entry->referrers);
    
    // 把从 entry 开始的 sizeof(*entry) 个字节空间置为 0
    bzero(entry, sizeof(*entry));

    weak_table->num_entries--;

    // 缩小 weak_table_t 的哈希数组容量
    weak_compact_maybe(weak_table);
}


/** 
 * Return the weak reference table entry for the given referent. 
 * If there is no entry for referent, return NULL. 
 * Performs a lookup.
 * 从 weak_table_t 的哈希数组中找到 referent 所对应的的 weak_entry_t，如果未找到则返回 NULL。
 * 注意：这个查找并不代表referent此时已经在哈希数组中。
 * @param weak_table 通过 &SideTables()[referent] 可从全局的 SideTables 中找到 referent 所处的 SideTable->weak_table_t
 * @param referent The object. Must not be nil.
 * 
 * @return The table of weak referrers to this object. 返回值是 weak_entry_t 指针，weak_entry_t 中保存了 referent 的所有弱引用变量的地址
 */
static weak_entry_t *
weak_entry_for_referent(weak_table_t *weak_table, objc_object *referent)
{
    ASSERT(referent);
    // weak_table_t 中哈希数组的入口
    weak_entry_t *weak_entries = weak_table->weak_entries;

    if (!weak_entries) return nil;
    // 哈希函数：hash_pointer 函数返回值与 mask 做与操作，防止 index 越界
    // 这里的 & mask 操作很巧妙，下面会进行详细讲解
    size_t begin = hash_pointer(referent) & weak_table->mask;
    size_t index = begin;
    size_t hash_displacement = 0;
    
    // 如果未发生哈希冲突的话，这 weak_table->weak_entries[index] 就是要找的 weak_entry_t 了
    while (weak_table->weak_entries[index].referent != referent) {
        // 如果发生了哈希冲突，+1 继续往下探测（开放寻址法）
        index = (index+1) & weak_table->mask;
        
        // 如果 index 每次加 1 加到值等于 begin 还没有找到 weak_entry_t，则触发 bad_weak_table 致命错误
        if (index == begin) bad_weak_table(weak_table->weak_entries);
        
        // 记录探测偏移了多远
        hash_displacement++;
        
        // 如果探测偏移超过了 weak_table_t 的 max_hash_displacement，
        // 说明在 weak_table 中没有 referent 的 weak_entry_t，则直接返回 nil
        if (hash_displacement > weak_table->max_hash_displacement) {
            return nil;
        }
    }
    
    // 到这里，说明index位置的 weak_entry_t 就是要查询的，然后取它的地址返回
    return &weak_table->weak_entries[index];
}

/**
 * 从 referent 对应的 weak_entry_t 的哈希数组（或定长为 4 的内部数组）中注销指定的弱引用。
 *
 * Unregister an already-registered weak reference.
 * This is used when referrer's storage is about to go away, but referent
 * isn't dead yet. (Otherwise, zeroing referrer later would be a
 * bad memory access.)
 * Does nothing if referent/referrer is not a currently active weak reference.
 * Does not zero referrer.
 * 注销以前注册的弱引用。该方法用于 referrer 的存储即将消失，但是 referent 还正常存在。（否则，referrer 被释放后，可能会造成一个错误的内存访问，即对象还没有释放，但是 weak 变量已经释放了，这时候再去访问 weak 变量会导致野指针访问。）如果  referent/referrer 不是当前有效的弱引用，则不执行任何操作。
 
 *
 * FIXME currently requires old referent value to be passed in (lame)
 * FIXME unregistration should be automatic if referrer is collected
 * 从弱引用表里移除一对（object, weak pointer）
 * @param weak_table The global weak table.
 * @param referent The object.
 * @param referrer The weak reference.
 */
void
weak_unregister_no_lock(weak_table_t *weak_table, id referent_id, 
                        id *referrer_id)
{
    objc_object *referent = (objc_object *)referent_id;
    objc_object **referrer = (objc_object **)referrer_id;

    weak_entry_t *entry;

    if (!referent) return;

    if ((entry = weak_entry_for_referent(weak_table, referent))) {
        remove_referrer(entry, referrer);
        bool empty = true;
        
        // 注销 referrer 以后判断是否需要删除对应的 weak_entry_t，
        // 如果 weak_entry_t 目前使用哈希数组，且 num_refs 不为 0，
        // 表示此时哈希数组还不为空，不需要删除
        if (entry->out_of_line()  &&  entry->num_refs != 0) {
            empty = false;
        }
        else {
            // 循环判断 weak_entry_t 内部定长为 4 的数组内是否还有 weak_referrer_t
            for (size_t i = 0; i < WEAK_INLINE_COUNT; i++) {
                if (entry->inline_referrers[i]) {
                    empty = false; 
                    break;
                }
            }
        }

        if (empty) {
            weak_entry_remove(weak_table, entry);
        }
    }

    // Do not set *referrer = nil. objc_storeWeak() requires that the 
    // value not change.
}

/** 
 * Registers a new (object, weak pointer) pair. Creates a new weak
 * object entry if it does not exist.
 * 添加一对（object, weak pointer）到弱引用表里
 * @param weak_table The global weak table.
 * @param referent The object pointed to by the weak reference.
 * @param referrer The weak pointer address.
 */
id 
weak_register_no_lock(weak_table_t *weak_table, id referent_id, 
                      id *referrer_id, bool crashIfDeallocating)
{
    objc_object *referent = (objc_object *)referent_id;
    objc_object **referrer = (objc_object **)referrer_id;

    if (!referent  ||  referent->isTaggedPointer()) return referent_id;

    // ensure that the referenced object is viable
    // 下面这个if else是取出是否当前正在释放。具体是否在释放的判断是封装在allowsWeakReference方法中的
    bool deallocating;
    if (!referent->ISA()->hasCustomRR()) {  // 没有自定义的allowsWeakReference方法
        deallocating = referent->rootIsDeallocating();
    }
    else {  // 有自定义的allowsWeakReference方法
        // 判断入参对象是否能进行 weak 引用 allowsWeakReference
        BOOL (*allowsWeakReference)(objc_object *, SEL) = 
            (BOOL(*)(objc_object *, SEL))
            object_getMethodImplementation((id)referent, 
                                           @selector(allowsWeakReference));
        if ((IMP)allowsWeakReference == _objc_msgForward) {
            return nil;
        }
        // 通过函数指针执行函数
        deallocating =
            ! (*allowsWeakReference)(referent, @selector(allowsWeakReference));
    }

    if (deallocating) {
        if (crashIfDeallocating) {
            _objc_fatal("Cannot form weak reference to instance (%p) of "
                        "class %s. It is possible that this object was "
                        "over-released, or is in the process of deallocation.",
                        (void*)referent, object_getClassName((id)referent));
        } else {
            return nil;
        }
    }

    // now remember it and where it is being stored
    weak_entry_t *entry;
    // referent会被放到一个weak_entry_t中，会被放在哪个里，则可以由weak_entry_for_referent函数来确定。
    // 但 weak_entry_for_referent 也可能返回NULL，表示还没有一个weak_entry_t可以用来放置referent，此时那就创建一个
    if ((entry = weak_entry_for_referent(weak_table, referent))) {
        // 如果有一个已经创建的weak_entry_t符合上面判断的条件，就会走这里。
        append_referrer(entry, referrer);
    } 
    else { // 从没有创建过一个weak_entry_t，就会走这里
        weak_entry_t new_entry(referent, referrer);
        weak_grow_maybe(weak_table);
        weak_entry_insert(weak_table, &new_entry);
    }

    // Do not set *referrer. objc_storeWeak() requires that the 
    // value not change.

    return referent_id;
}


#if DEBUG
bool
weak_is_registered_no_lock(weak_table_t *weak_table, id referent_id) 
{
    return weak_entry_for_referent(weak_table, (objc_object *)referent_id);
}
#endif


/** 
 * Called by dealloc; nils out all weak pointers that point to the 
 * provided object so that they can no longer be used.
 * 当对象的 dealloc 函数执行时会调用此函数，主要功能是当对象被释放废弃时，把该对象的弱引用指针全部指向 nil。
 * @param weak_table 
 * @param referent The object being deallocated. 
 */
void 
weak_clear_no_lock(weak_table_t *weak_table, id referent_id) 
{
    objc_object *referent = (objc_object *)referent_id;

    weak_entry_t *entry = weak_entry_for_referent(weak_table, referent);
    if (entry == nil) {
        /// XXX shouldn't happen, but does with mismatched CF/objc
        //printf("XXX no entry for clear deallocating %p\n", referent);
        return;
    }

    // zero out references
    weak_referrer_t *referrers;
    size_t count;
    
    if (entry->out_of_line()) {
        referrers = entry->referrers;
        count = TABLE_SIZE(entry);
    } 
    else {
        referrers = entry->inline_referrers;
        count = WEAK_INLINE_COUNT;
    }
    
    // 循环把 inline_referrers 数组或者 hash 数组中的 weak 变量指向置为 nil
    for (size_t i = 0; i < count; ++i) {
        objc_object **referrer = referrers[i];
        if (referrer) {
            if (*referrer == referent) {
                *referrer = nil;
            }
            else if (*referrer) {
                _objc_inform("__weak variable at %p holds %p instead of %p. "
                             "This is probably incorrect use of "
                             "objc_storeWeak() and objc_loadWeak(). "
                             "Break on objc_weak_error to debug.\n", 
                             referrer, (void*)*referrer, (void*)referent);
                objc_weak_error();
            }
        }
    }
    // 最后把 entry 从 weak_table_t 中移除	
    weak_entry_remove(weak_table, entry);
}

