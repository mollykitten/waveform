#include <TargetConditionals.h>
#if TARGET_OS_OSX
#import <FlutterMacOS/FlutterMacOS.h>
#import <AVFoundation/AVFoundation.h>

/// Per-plugin output routing. Never changes the system default output device.
@interface WaveformAudioOutput : NSObject<FlutterStreamHandler>
- (instancetype)initWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar;
- (void)playerCreated:(AVQueuePlayer *)player owner:(NSObject *)owner;
- (void)activatePlayer:(AVQueuePlayer *)player owner:(NSObject *)owner;
- (void)disposePlayer:(AVQueuePlayer *)player owner:(NSObject *)owner;
- (void)shutdown;
@end
#endif
