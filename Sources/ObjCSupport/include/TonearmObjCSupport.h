#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block` and returns the Objective-C exception it raised, or nil.
///
/// Swift cannot catch an NSException; an uncaught one aborts the app. AVFoundation raises them
/// for API misuse it could have reported as an error (`AVPlayer` preroll or synchronized playback
/// before the player is ready to play — TestFlight 520 and 521 crashed mid-mix on exactly that).
/// Playback code guards those preconditions first; this is the backstop so a precondition we
/// haven't learned about yet degrades a crossfade instead of killing playback.
/// Only for calls that raise before mutating state (argument/state validation).
NSException * _Nullable TonearmCatchObjCException(NS_NOESCAPE void (^block)(void));

NS_ASSUME_NONNULL_END
