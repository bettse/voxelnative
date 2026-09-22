#import <Foundation/Foundation.h>
#import "ShaderTypes.h"

/// Run `block`, catching any Objective-C NSException it throws. AVAudioEngine's
/// connect/attach/play raise NSExceptions on an invalid graph (format error
/// -10868, a disconnected node, an interrupted session) and Swift's try/catch
/// cannot catch those, so a single audio hiccup aborted the whole app. Wrap the
/// graph mutation in this and it returns nil on success, or the exception's
/// "name: reason" so the caller can log it and drop just that sound.
static inline NSString * _Nullable VNCatchNSException(void (NS_NOESCAPE ^ _Nonnull block)(void)) {
    @try {
        block();
        return nil;
    } @catch (NSException *e) {
        return [NSString stringWithFormat:@"%@: %@", e.name, e.reason ?: @"(no reason)"];
    }
}
