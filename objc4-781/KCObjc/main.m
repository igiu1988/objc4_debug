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
        
        Person *objc1 = [[Person alloc] init];
        NSString *pName = objc1.name;
        Person *father = objc1.father;
//        LGPerson *objc2 = [[LGPerson alloc] init];

//        NSLog(@"Hello, World! %@ - %@",objc1,objc2);
    }
    return 0;
}
