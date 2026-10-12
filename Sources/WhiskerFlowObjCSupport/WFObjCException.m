#import "WFObjCException.h"

BOOL WFPerformCatchingObjCException(NS_NOESCAPE void (^block)(void), NSError * _Nullable * _Nullable error) {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        if (error) {
            // Only the exception name is kept: its reason can carry device details.
            *error = [NSError errorWithDomain:@"agency.thatworks.WhiskerFlow.ObjCException"
                                         code:1
                                     userInfo:@{ @"exceptionName": exception.name ?: @"unknown" }];
        }
        return NO;
    }
}
