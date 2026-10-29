// Standalone macOS probe; does not launch Flutter or play audio.
#import <Cocoa/Cocoa.h>
#import <AVKit/AVKit.h>
#import "../just_audio/Sources/just_audio/include/just_audio/WaveformAudioOutput.h"

@interface WaveformAudioOutput (Probe)
- (NSDictionary *)state;
- (void)applyToPlayer:(AVQueuePlayer *)player;
- (void)handleMethodCall:(FlutterMethodCall *)call result:(FlutterResult)result;
- (BOOL)canPresentAirPlay;
- (void)presentAirPlay:(id)arguments API_AVAILABLE(macos(10.15));
- (void)routePickerViewWillBeginPresentingRoutes:(AVRoutePickerView *)picker API_AVAILABLE(macos(10.15));
- (void)routePickerViewDidEndPresentingRoutes:(AVRoutePickerView *)picker API_AVAILABLE(macos(10.15));
@end

@interface HeadlessOutput : WaveformAudioOutput
@property(nonatomic) BOOL presented;
@end
@implementation HeadlessOutput
- (BOOL)canPresentAirPlay { return YES; }
- (void)presentAirPlay:(id)arguments { self.presented = YES; }
@end

@interface ProbeMessenger : NSObject<FlutterBinaryMessenger>
@end
@implementation ProbeMessenger
- (void)sendOnChannel:(NSString *)channel message:(NSData *)message {}
- (void)sendOnChannel:(NSString *)channel message:(NSData *)message
          binaryReply:(FlutterBinaryReply)reply { if (reply) reply(nil); }
- (FlutterBinaryMessengerConnection)setMessageHandlerOnChannel:(NSString *)channel
                                         binaryMessageHandler:(FlutterBinaryMessageHandler)handler { return 1; }
- (void)cleanUpConnection:(FlutterBinaryMessengerConnection)connection {}
@end

@interface ProbeRegistrar : NSObject
@property(nonatomic, strong) ProbeMessenger *messenger;
@end
@implementation ProbeRegistrar
- (NSView *)view { return nil; }
@end

static id Call(WaveformAudioOutput *output, NSString *method, id arguments) {
    __block id value = nil;
    [output handleMethodCall:[FlutterMethodCall methodCallWithMethodName:method arguments:arguments]
                      result:^(id result) { value = result; }];
    NSCAssert(value != nil, @"method must return synchronously");
    return value;
}

static void DrainMainDispatch(void) {
    __block BOOL drained = NO;
    dispatch_async(dispatch_get_main_queue(), ^{ drained = YES; });
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:1];
    while (!drained && deadline.timeIntervalSinceNow > 0) {
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.01, true);
    }
    NSCAssert(drained, @"native KVO publication queue drained");
}

int main(void) {
    @autoreleasepool {
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"waveform.requestedAudioOutputUid"];
        ProbeRegistrar *registrar = [[ProbeRegistrar alloc] init];
        registrar.messenger = [[ProbeMessenger alloc] init];
        HeadlessOutput *output = [[HeadlessOutput alloc]
            initWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar];
        NSDictionary *initial = Call(output, @"getState", nil);
        __block NSDictionary *lastEvent = nil;
        [output onListenWithArguments:nil eventSink:^(id event) { lastEvent = event; }];
        NSCAssert([initial[@"supported"] boolValue], @"macOS supported");
        NSArray *inventory = initial[@"devices"];
        for (NSDictionary *device in inventory) {
            NSCAssert([device[@"uid"] length] > 0, @"stable UID");
            NSCAssert([device[@"name"] length] > 0, @"display label");
        }
        NSObject *ownerA = [[NSObject alloc] init];
        NSObject *ownerB = [[NSObject alloc] init];
        AVQueuePlayer *a = [[AVQueuePlayer alloc] initWithItems:@[]];
        AVQueuePlayer *b = [[AVQueuePlayer alloc] initWithItems:@[]];
        [output playerCreated:a owner:ownerA];
        [output playerCreated:b owner:ownerB];
        [output activatePlayer:a owner:ownerA];
        NSDictionary *missing = Call(output, @"setDevice", @{@"uid": @"waveform-probe-missing-device"});
        NSCAssert([missing[@"requestedUid"] isEqual:@"waveform-probe-missing-device"], @"retain requested UID");
        NSCAssert([missing[@"message"] isEqual:@"device_unavailable"], @"honest fallback reason");
        NSCAssert([lastEvent isEqual:missing], @"selection publishes the same snapshot");
        NSCAssert(a.audioOutputDeviceUniqueID == nil && b.audioOutputDeviceUniqueID == nil,
                  @"missing requested device follows system output on every player");
        if (inventory.count) {
            NSDictionary *local = inventory[0];
            for (NSDictionary *device in inventory) {
                if (![device[@"transport"] isEqual:@"airplay"]) {
                    local = device;
                    break;
                }
            }
            NSString *uid = local[@"uid"];
            Call(output, @"setDevice", @{@"uid": uid});
            NSCAssert([a.audioOutputDeviceUniqueID isEqual:uid] &&
                      [b.audioOutputDeviceUniqueID isEqual:uid], @"both players route");
            NSObject *ownerC = [[NSObject alloc] init];
            AVQueuePlayer *c = [[AVQueuePlayer alloc] initWithItems:@[]];
            [output playerCreated:c owner:ownerC];
            NSCAssert([c.audioOutputDeviceUniqueID isEqual:uid], @"lazy creation inherits routing");
            if (@available(macOS 10.15, *)) {
                NSDictionary *shown = Call(output, @"showAirPlay", nil);
                NSCAssert(output.presented, @"headless seam skipped rendering only");
                NSCAssert([shown[@"requestedUid"] isEqual:uid], @"opening AirPlay preserves local requested UID");
                NSCAssert([a.audioOutputDeviceUniqueID isEqual:uid] &&
                          [b.audioOutputDeviceUniqueID isEqual:uid] &&
                          [c.audioOutputDeviceUniqueID isEqual:uid], @"opening AirPlay preserves actual local player outputs");
                NSCAssert([[[NSUserDefaults standardUserDefaults] stringForKey:@"waveform.requestedAudioOutputUid"] isEqual:uid], @"opening AirPlay preserves native preference");
                [output routePickerViewWillBeginPresentingRoutes:nil];
                [output routePickerViewDidEndPresentingRoutes:nil];
                NSCAssert([[output state][@"requestedUid"] isEqual:uid] &&
                          [a.audioOutputDeviceUniqueID isEqual:uid], @"dismissal without route change preserves local selection");
                NSCAssert([[output state][@"preservePlayer"] boolValue], @"dismissal retains conservative player latch");
                NSCAssert([[[NSUserDefaults standardUserDefaults] stringForKey:@"waveform.requestedAudioOutputUid"] isEqual:uid], @"dismissal preserves native preference");
                if (![local[@"transport"] isEqual:@"airplay"]) {
                    NSCAssert(![[output state][@"airPlayActive"] boolValue], @"open and dismiss are not evidence of a receiver");
                    NSCAssert([[output state][@"effectiveUid"] isEqual:uid], @"unchanged local output remains effective after dismissal");
                }
                for (NSDictionary *device in inventory) {
                    NSString *changedUid = device[@"uid"];
                    if ([changedUid isEqual:uid]) continue;
                    // A real AVPlayer property change after picker dismissal
                    // must still reach the native KVO event path.
                    a.audioOutputDeviceUniqueID = changedUid;
                    DrainMainDispatch();
                    NSCAssert([lastEvent[@"effectiveUid"] isEqual:changedUid], @"late native output change publishes actual effective UID");
                    NSCAssert([lastEvent[@"requestedUid"] isEqual:uid] &&
                              [[[NSUserDefaults standardUserDefaults] stringForKey:@"waveform.requestedAudioOutputUid"] isEqual:uid], @"late native route change retains last local preference");
                    NSCAssert([lastEvent[@"airPlayActive"] boolValue] == [device[@"transport"] isEqual:@"airplay"], @"only observed native transport marks AirPlay active");
                    a.audioOutputDeviceUniqueID = uid;
                    DrainMainDispatch();
                    break;
                }
                ProbeRegistrar *restartRegistrar = [[ProbeRegistrar alloc] init];
                restartRegistrar.messenger = [[ProbeMessenger alloc] init];
                WaveformAudioOutput *restarted = [[WaveformAudioOutput alloc]
                    initWithRegistrar:(NSObject<FlutterPluginRegistrar> *)restartRegistrar];
                AVQueuePlayer *restored = [[AVQueuePlayer alloc] initWithItems:@[]];
                NSObject *restoredOwner = [[NSObject alloc] init];
                [restarted playerCreated:restored owner:restoredOwner];
                NSCAssert([[restarted state][@"requestedUid"] isEqual:uid] &&
                          [restored.audioOutputDeviceUniqueID isEqual:uid], @"new coordinator restores prior local choice after dismissal");
                [restarted disposePlayer:restored owner:restoredOwner];
                [restarted shutdown];
                Call(output, @"setDevice", @{@"uid": uid});
            }
            // Simulate the inventory snapshot produced by a disconnect callback.
            [output setValue:@[] forKey:@"devices"];
            [output applyToPlayer:a];
            [output applyToPlayer:b];
            NSCAssert(a.audioOutputDeviceUniqueID == nil && b.audioOutputDeviceUniqueID == nil,
                      @"disconnect falls back without retaining a dead device");
            NSCAssert([[output state][@"requestedUid"] isEqual:uid], @"disconnect retains preference");
            [output setValue:inventory forKey:@"devices"];
            [output applyToPlayer:a];
            NSCAssert([a.audioOutputDeviceUniqueID isEqual:uid], @"reconnect restores preference");
            [output disposePlayer:c owner:ownerC];
        }
        Call(output, @"setDevice", @{@"uid": NSNull.null});
        NSCAssert(a.audioOutputDeviceUniqueID == nil && b.audioOutputDeviceUniqueID == nil,
                  @"system default represented by nil on all players");
        [output setValue:@YES forKey:@"preservePlayer"];
        NSDictionary *uncertain = [output state];
        NSCAssert([uncertain[@"preservePlayer"] boolValue], @"uncertain receiver keeps native player");
        NSCAssert(uncertain[@"effectiveUid"] == NSNull.null, @"unknown audio route is not fabricated");
        Call(output, @"setDevice", @{@"uid": NSNull.null});
        NSCAssert(![[output state][@"preservePlayer"] boolValue] ||
                  [[output state][@"airPlayActive"] boolValue], @"explicit output clears uncertainty latch");
        id invalid = Call(output, @"setDevice", @{@"uid": @42});
        NSCAssert([invalid isKindOfClass:FlutterError.class], @"invalid selection rejected");
        [output disposePlayer:a owner:ownerA];
        NSCAssert([output valueForKey:@"activePlayer"] == nil, @"disposal clears active binding");
        [output disposePlayer:b owner:ownerB];
        id unavailable = Call(output, @"showAirPlay", nil);
        NSCAssert([unavailable isKindOfClass:FlutterError.class], @"picker needs loaded active player and window");
        [output shutdown];
        [output shutdown];
        NSLog(@"PASS: live output inventory (%lu outputs), selection, lazy creation, AirPlay open/dismiss preserves real local players and native preference, coordinator restart restoration, disconnect/reconnect policy, fallback, route uncertainty, disposal", (unsigned long)inventory.count);
    }
    return 0;
}
