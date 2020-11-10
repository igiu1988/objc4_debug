//
//  main.m
//  KCObjc
//
//  Created by Cooci on 2020/7/24.
//

#import <Foundation/Foundation.h>
#import "LGPerson.h"

@interface Person : NSObject
@property (nonatomic, strong) Person *father;
@property (nonatomic, copy) NSString *name;
@end

@implementation Person

@end

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        // insert code here...
        NSString *name = @"";
        Person *objc1 = [[Person alloc] init];
        NSString *pName = objc1.name;
        Person *father = objc1.father;
        __weak Person *weakFater = objc1;
        __weak NSString *weakName = name;
//        LGPerson *objc2 = [[LGPerson alloc] init];

        NSLog(@"Hello, World! %@ - %@",objc1, weakFater);
    }
    return 0;
}
