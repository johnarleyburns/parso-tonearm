#import "TonearmObjCSupport.h"

NSException * _Nullable TonearmCatchObjCException(NS_NOESCAPE void (^block)(void)) {
    @try {
        block();
        return nil;
    } @catch (NSException *exception) {
        return exception;
    }
}
