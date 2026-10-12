#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block`, converting an Objective-C exception into a returned error.
/// AVAudioNode's installTap raises NSException (which Swift cannot catch) when
/// the hardware format changes between the format query and the install, for
/// example while a call app reconfigures the shared microphone.
BOOL WFPerformCatchingObjCException(NS_NOESCAPE void (^block)(void), NSError * _Nullable * _Nullable error);

NS_ASSUME_NONNULL_END
