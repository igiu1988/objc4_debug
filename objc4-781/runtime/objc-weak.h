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

#ifndef _OBJC_WEAK_H_
#define _OBJC_WEAK_H_

#include <objc/objc.h>
#include "objc-config.h"

__BEGIN_DECLS

/*
The weak table is a hash table governed控制 by a single spin lock.
An allocated blob块 of memory, most often an object, but under GC any such
allocation, may have its address stored in a __weak marked storage location 
through use of compiler generated write-barriers or hand coded uses of the 
register weak primitive. Associated with the registration can be a callback 
block for the case when one of the allocated chunks of memory is reclaimed. 
The table is hashed on the address of the allocated memory.  When __weak 
marked memory changes its reference, we count on the fact that we can still 
see its previous reference.

So, in the hash table, indexed by the weakly referenced item, is a list of 
all locations where this address is currently being stored.
 
For ARC, we also keep track of whether an arbitrary object is being 
deallocated by briefly placing it in the table just prior to invoking 
dealloc, and removing it via objc_clear_deallocating just prior to memory 
reclamation.

*/

// The address of a __weak variable.
// These pointers are stored disguised伪装的 so memory analysis tools
// don't see lots of interior内部 pointers from the weak table into objects.
// 使用DisguisedPtr对指针再包装了一次，即所谓的伪装的指针（DisguisedPtr)。
// 这样，内存分析工具就不会从weak table看到很多内部指针
typedef DisguisedPtr<objc_object *> weak_referrer_t;

// weak引用表的哈希数组长度
#if __LP64__
#define PTR_MINUS_2 62
#else
#define PTR_MINUS_2 30
#endif

/**
 * The internal structure stored in the weak references table. 
 * It maintains and stores
 * a hash set of weak references pointing to an object.
 * If out_of_line_ness != REFERRERS_OUT_OF_LINE then the set
 * is instead a small inline array.
 */
#define WEAK_INLINE_COUNT 4

// out_of_line_ness field overlaps with the low two bits of inline_referrers[1].
// inline_referrers[1] is a DisguisedPtr of a pointer-aligned address.
// The low two bits of a pointer-aligned DisguisedPtr will always be 0b00
// (disguised nil or 0x80..00) or 0b11 (any other address).
// Therefore out_of_line_ness == 0b10 is used to mark the out-of-line state.
// 这段注释的理解见笔记：weak_referrer_t 是存储在哪个数组中的
#define REFERRERS_OUT_OF_LINE 2

struct weak_entry_t {
    DisguisedPtr<objc_object> referent; // 对象地址，详见笔记 DisguisedPtr

    /*
     当指向 referent 的弱引用个数小于等于 4 时使用 inline_referrers 数组保存这些弱引用变量的地址，
     大于 4 以后用 referrers 这个哈希数组保存。
    
     共用 32 个字节内存空间的联合体
     */
    union {
        struct {
            // 保存 weak_referrer_t 的哈希数组
            weak_referrer_t *referrers;
            
            // out_of_line_ness 和 num_refs 构成位域存储，共占 64 位
            uintptr_t        out_of_line_ness : 2;  // 标记使用哈希数组referrers 还是 inline_referrers
            uintptr_t        num_refs : PTR_MINUS_2;    // referrers数组长度
            uintptr_t        mask;  // 数组下标最大值(数组大小 - 1)，会参与哈希函数计算
            
            // 可能会发生 hash 冲突的最大次数，用于判断是否出现了逻辑错误，（hash 表中的冲突次数绝对不会超过该值）
            // 该值在新建 weak_entry_t 和插入新的 weak_referrer_t 时会被更新，它一直记录的都是最大偏移值
            uintptr_t        max_hash_displacement; // 最大哈希偏移值
        };
        struct {
            // 这是一个取名叫内联引用的数组, 宏定义的值是 4
            // out_of_line_ness field is low bits of inline_referrers[1]
            // out_of_line_ness 和 inline_referrers[1] 的低两位的内存空间重合。这个是如何做到的？？？
            // 长度为 4 的 weak_referrer_t（Dsiguised<objc_object *>）数组
            weak_referrer_t  inline_referrers[WEAK_INLINE_COUNT];
        };
    };

    // 返回 true 表示使用第一个结构体中的 referrers 哈希数组
    // 返回 false 表示使用第二个结构体中的 inline_referrers 数组保存 weak_referrer_t
    bool out_of_line() {
        return (out_of_line_ness == REFERRERS_OUT_OF_LINE);
    }

    // 重载操作符
    // 赋值操作，直接使用 memcpy 函数拷贝 other 内存里面的内容到 this 中，
    // 而不是用复制构造函数什么的形式实现，应该也是为了提高效率考虑的...
    weak_entry_t& operator=(const weak_entry_t& other) {
        memcpy(this, &other, sizeof(other));
        return *this;
    }

    // weak_entry_t 的构造函数
    
    // newReferent 是原始对象的指针
    // newReferrer 是指向 newReferent 的弱引用变量的地址
    
    // 初始化列表 referent(newReferent) 会调用: DisguisedPtr(T* ptr) : value(disguise(ptr)) { } 构造函数，

    weak_entry_t(objc_object *newReferent, objc_object **newReferrer)
        : referent(newReferent)
    {
        // 把 newReferrer 放在数组 0 位，也会调用 DisguisedPtr 构造函数，把 newReferrer 转化为整数保存
        inline_referrers[0] = newReferrer;
        for (int i = 1; i < WEAK_INLINE_COUNT; i++) {
            // 循环把 inline_referrers 数组的剩余 3 位都置为 nil
            inline_referrers[i] = nil;
        }
    }
};

/**
 * The global weak references table. Stores object ids as keys,
 * and weak_entry_t structs as their values.
 */
struct weak_table_t {
    weak_entry_t *weak_entries; // 存储 weak_entry_t 的哈希数组
    size_t    num_entries;  // 当前 weak_entries 内保存的 weak_entry_t 的数量，哈希数组内保存的元素个数
    uintptr_t mask; // 数组下标最大值，即数组大小减1，会参与 hash 函数计算
    
    // 记录所有项的最大偏移量，即发生 hash 冲突的最大次数
    // 用于判断是否出现了逻辑错误，hash 表中的冲突次数绝对不会超过这个值，
    // 下面关于 weak_entry_t 的操作函数中会看到这个成员变量的使用，这里先对它有一些了解即可，
    // 因为会有 hash 碰撞的情况，而 weak_table_t 采用了开放寻址法来解决，
    // 所以某个 weak_entry_t 实际存储的位置并不一定是 hash 函数计算出来的位置

    uintptr_t max_hash_displacement;    //最大哈希偏移值
};

/// Adds an (object, weak pointer) pair to the weak table.
/// 添加一对（object, weak pointer）到弱引用表里
id weak_register_no_lock(weak_table_t *weak_table, id referent, 
                         id *referrer, bool crashIfDeallocating);

/// Removes an (object, weak pointer) pair from the weak table.
/// 从弱引用表里移除一对（object, weak pointer）
void weak_unregister_no_lock(weak_table_t *weak_table, id referent, id *referrer);

#if DEBUG
/// Returns true if an object is weakly referenced somewhere.
/// 如果一个对象在弱引用表的到某处，即该对象被保存在弱引用表里，则返回 true.
bool weak_is_registered_no_lock(weak_table_t *weak_table, id referent);
#endif

/// Called on object destruction. Sets all remaining weak pointers to nil.
/// 当对象销毁的时候该函数被调用。设置所有剩余的 __weak 变量指向 nil.
/// 此处正对应了，__weak 变量在它指向的对象销毁后它会被置为 nil 的机制
void weak_clear_no_lock(weak_table_t *weak_table, id referent);

__END_DECLS

#endif /* _OBJC_WEAK_H_ */
