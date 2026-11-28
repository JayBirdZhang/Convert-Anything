#import "ObjCException.h"

NSError *CACatchException(NS_NOESCAPE void (^block)(void)) {
    @try {
        block();
        return nil;
    } @catch (NSException *exception) {
        return [NSError errorWithDomain:exception.name code:0
                               userInfo:@{NSLocalizedDescriptionKey: exception.reason ?: exception.name}];
    }
}
