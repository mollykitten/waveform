#include <TargetConditionals.h>
#if TARGET_OS_OSX
#import "./include/just_audio/WaveformAudioOutput.h"
#import <AVKit/AVKit.h>
#import <CoreAudio/CoreAudio.h>

static NSString *const WFRequestedOutputKey = @"waveform.requestedAudioOutputUid";
static void *WFOutputObservation = &WFOutputObservation;

@interface WaveformAudioOutput () <AVRoutePickerViewDelegate>
@end

@implementation WaveformAudioOutput {
    FlutterMethodChannel *_methods;
    FlutterEventChannel *_events;
    FlutterEventSink _eventSink;
    NSHashTable<AVQueuePlayer *> *_players;
    __weak NSObject *_activeOwner;
    __weak AVQueuePlayer *_activePlayer;
    __weak NSView *_anchorView;
    NSString *_requestedUid;
    NSArray<NSDictionary *> *_devices;
    NSMutableSet<NSNumber *> *_observedDevices;
    AudioObjectPropertyListenerBlock _hardwareListener;
    BOOL _refreshing;
    BOOL _preservePlayer;
    BOOL _hardwareAvailable;
    BOOL _disposed;
    NSPopover *_popover;
    AVRoutePickerView *_picker API_AVAILABLE(macos(10.15));
}

- (instancetype)initWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
    self = [super init];
    if (!self) return nil;
    _players = [NSHashTable weakObjectsHashTable];
    _anchorView = registrar.view;
    _devices = @[];
    _observedDevices = [NSMutableSet set];
    _requestedUid = [[NSUserDefaults standardUserDefaults] stringForKey:WFRequestedOutputKey];
    _methods = [FlutterMethodChannel methodChannelWithName:@"waveform/audio_output"
                                         binaryMessenger:registrar.messenger];
    _events = [FlutterEventChannel eventChannelWithName:@"waveform/audio_output_events"
                                      binaryMessenger:registrar.messenger];
    [_events setStreamHandler:self];
    __weak typeof(self) weakSelf = self;
    [_methods setMethodCallHandler:^(FlutterMethodCall *call, FlutterResult result) {
        [weakSelf handleMethodCall:call result:result];
    }];
    _hardwareListener = ^(UInt32 count, const AudioObjectPropertyAddress *addresses) {
        [weakSelf refresh];
    };
    AudioObjectPropertyAddress hardware = {kAudioHardwarePropertyDevices,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    AudioObjectAddPropertyListenerBlock(kAudioObjectSystemObject, &hardware,
                                       dispatch_get_main_queue(), _hardwareListener);
    AudioObjectPropertyAddress defaultOutput = {kAudioHardwarePropertyDefaultOutputDevice,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    AudioObjectAddPropertyListenerBlock(kAudioObjectSystemObject, &defaultOutput,
                                       dispatch_get_main_queue(), _hardwareListener);
    [self refresh];
    return self;
}

- (NSString *)stringProperty:(AudioObjectPropertySelector)selector
                     device:(AudioDeviceID)device {
    AudioObjectPropertyAddress address = {selector, kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain};
    CFStringRef value = NULL;
    UInt32 size = sizeof(value);
    if (AudioObjectGetPropertyData(device, &address, 0, NULL, &size, &value) != noErr) return nil;
    return CFBridgingRelease(value);
}

- (BOOL)hasOutput:(AudioDeviceID)device {
    AudioObjectPropertyAddress aliveAddress = {kAudioDevicePropertyDeviceIsAlive,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    UInt32 alive = 0, aliveSize = sizeof(alive);
    if (AudioObjectGetPropertyData(device, &aliveAddress, 0, NULL, &aliveSize, &alive) != noErr ||
        !alive) return NO;
    AudioObjectPropertyAddress address = {kAudioDevicePropertyStreamConfiguration,
        kAudioDevicePropertyScopeOutput, kAudioObjectPropertyElementMain};
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(device, &address, 0, NULL, &size) != noErr ||
        size < sizeof(AudioBufferList)) return NO;
    AudioBufferList *buffers = malloc(size);
    if (!buffers) return NO;
    BOOL output = NO;
    if (AudioObjectGetPropertyData(device, &address, 0, NULL, &size, buffers) == noErr) {
        for (UInt32 i = 0; i < buffers->mNumberBuffers; i++) {
            output |= buffers->mBuffers[i].mNumberChannels > 0;
        }
    }
    free(buffers);
    return output;
}

- (NSString *)transport:(AudioDeviceID)device {
    AudioObjectPropertyAddress address = {kAudioDevicePropertyTransportType,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    UInt32 transport = 0, size = sizeof(transport);
    if (AudioObjectGetPropertyData(device, &address, 0, NULL, &size, &transport) != noErr) return @"unknown";
    switch (transport) {
        case kAudioDeviceTransportTypeBuiltIn: return @"built_in";
        case kAudioDeviceTransportTypeBluetooth:
        case kAudioDeviceTransportTypeBluetoothLE: return @"bluetooth";
        case kAudioDeviceTransportTypeUSB: return @"usb";
        case kAudioDeviceTransportTypeAirPlay: return @"airplay";
        case kAudioDeviceTransportTypeHDMI:
        case kAudioDeviceTransportTypeDisplayPort: return @"display";
        case kAudioDeviceTransportTypeVirtual: return @"virtual";
        case kAudioDeviceTransportTypeAggregate: return @"aggregate";
        default: return @"other";
    }
}

- (void)observeDevice:(AudioDeviceID)device add:(BOOL)add {
    AudioObjectPropertyAddress addresses[] = {
        {kAudioDevicePropertyStreamConfiguration, kAudioDevicePropertyScopeOutput, kAudioObjectPropertyElementMain},
        {kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain},
        {kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain}
    };
    for (NSUInteger i = 0; i < sizeof(addresses) / sizeof(addresses[0]); i++) {
        if (add) AudioObjectAddPropertyListenerBlock(device, &addresses[i], dispatch_get_main_queue(), _hardwareListener);
        else AudioObjectRemovePropertyListenerBlock(device, &addresses[i], dispatch_get_main_queue(), _hardwareListener);
    }
}

- (void)refresh {
    if (_refreshing || _disposed) return;
    _refreshing = YES;
    AudioObjectPropertyAddress address = {kAudioHardwarePropertyDevices,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    UInt32 size = 0;
    NSMutableArray *devices = [NSMutableArray array];
    NSMutableSet *ids = [NSMutableSet set];
    OSStatus status = AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &address, 0, NULL, &size);
    AudioDeviceID *hardware = size > 0 ? malloc(size) : NULL;
    if (status == noErr && size > 0 && !hardware) status = memFullErr;
    if (status == noErr && size > 0) {
        status = AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, NULL, &size, hardware);
        if (status == noErr) {
            for (NSUInteger i = 0; i < size / sizeof(AudioDeviceID); i++) {
                AudioDeviceID device = hardware[i];
                [ids addObject:@(device)];
                if (![self hasOutput:device]) continue;
                NSString *uid = [self stringProperty:kAudioDevicePropertyDeviceUID device:device];
                if (!uid.length) continue;
                NSString *name = [self stringProperty:kAudioObjectPropertyName device:device];
                if (!name.length) name = @"Audio output";
                [devices addObject:@{@"uid": uid, @"name": name, @"transport": [self transport:device]}];
            }
        }
    }
    free(hardware);
    _hardwareAvailable = status == noErr;
    // A failed scan is not evidence of disconnection. Retain the last inventory.
    if (_hardwareAvailable) {
        for (NSNumber *device in _observedDevices) {
            if (![ids containsObject:device]) [self observeDevice:device.unsignedIntValue add:NO];
        }
        for (NSNumber *device in ids) {
            if (![_observedDevices containsObject:device]) [self observeDevice:device.unsignedIntValue add:YES];
        }
        _observedDevices = ids;
        _devices = [devices sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            return [a[@"name"] localizedCaseInsensitiveCompare:b[@"name"]];
        }];
        if (!_preservePlayer) {
            for (AVQueuePlayer *player in _players) [self applyToPlayer:player];
        }
    }
    _refreshing = NO;
    [self publish];
}

- (NSDictionary *)deviceWithUid:(NSString *)uid {
    if (!uid) return nil;
    for (NSDictionary *device in _devices) {
        if ([device[@"uid"] isEqual:uid]) return device;
    }
    return nil;
}

- (NSString *)defaultOutputUid {
    AudioObjectPropertyAddress address = {kAudioHardwarePropertyDefaultOutputDevice,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    AudioDeviceID device = kAudioObjectUnknown;
    UInt32 size = sizeof(device);
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, NULL, &size, &device) != noErr) return nil;
    return [self stringProperty:kAudioDevicePropertyDeviceUID device:device];
}

- (void)applyToPlayer:(AVQueuePlayer *)player {
    NSString *uid = [self deviceWithUid:_requestedUid] ? _requestedUid : nil;
    if (![player.audioOutputDeviceUniqueID isEqual:uid] &&
        (player.audioOutputDeviceUniqueID != nil || uid != nil)) {
        player.audioOutputDeviceUniqueID = uid;
    }
}

- (NSDictionary *)state {
    NSString *effective = _activePlayer.audioOutputDeviceUniqueID;
    if (![self deviceWithUid:effective]) effective = nil;
    BOOL external = _activePlayer.isExternalPlaybackActive;
    if (external && ![[self deviceWithUid:effective][@"transport"] isEqual:@"airplay"]) {
        effective = nil;
    }
    if (!_preservePlayer && !external && !effective) {
        effective = [self defaultOutputUid];
        if (![self deviceWithUid:effective]) effective = nil;
    }
    BOOL airPlay = external ||
        [[self deviceWithUid:effective][@"transport"] isEqual:@"airplay"];
    NSString *message = nil;
    if (!_hardwareAvailable) message = @"audio_output_unavailable";
    else if (_preservePlayer) message = @"airplay_route_unverified";
    else if (_requestedUid && ![self deviceWithUid:_requestedUid]) message = @"device_unavailable";
    else if (!_devices.count) message = @"no_output_device";
    return @{@"supported": @YES, @"devices": _devices,
             @"requestedUid": _requestedUid ?: (id)NSNull.null,
             @"effectiveUid": effective ?: (id)NSNull.null,
             @"airPlayActive": @(airPlay), @"preservePlayer": @(_preservePlayer || airPlay),
             @"message": message ?: (id)NSNull.null};
}

- (void)publish {
    if (!_disposed && _eventSink) _eventSink([self state]);
}

- (void)playerCreated:(AVQueuePlayer *)player owner:(NSObject *)owner {
    if (_disposed) return;
    [_players addObject:player];
    [self applyToPlayer:player];
    if (_activeOwner == owner) [self activatePlayer:player owner:owner];
}

- (void)activatePlayer:(AVQueuePlayer *)player owner:(NSObject *)owner {
    if (_disposed) return;
    if (_activePlayer != player) {
        if (_activePlayer) {
            [_activePlayer removeObserver:self forKeyPath:@"externalPlaybackActive" context:WFOutputObservation];
            [_activePlayer removeObserver:self forKeyPath:@"audioOutputDeviceUniqueID" context:WFOutputObservation];
        }
        _activePlayer = player;
        if (player) {
            [player addObserver:self forKeyPath:@"externalPlaybackActive" options:0 context:WFOutputObservation];
            [player addObserver:self forKeyPath:@"audioOutputDeviceUniqueID" options:0 context:WFOutputObservation];
        }
    }
    _activeOwner = owner;
    if (@available(macOS 10.15, *)) _picker.player = player;
    [self publish];
}

- (void)disposePlayer:(AVQueuePlayer *)player owner:(NSObject *)owner {
    if (_disposed) return;
    if (_activeOwner == owner) {
        [_popover close];
        [self activatePlayer:nil owner:nil];
    }
    if (player) [_players removeObject:player];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object
                       change:(NSDictionary *)change context:(void *)context {
    if (context != WFOutputObservation) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf publish]; });
}

- (void)handleMethodCall:(FlutterMethodCall *)call result:(FlutterResult)result {
    if ([call.method isEqualToString:@"getState"]) {
        [self refresh];
        result([self state]);
    } else if ([call.method isEqualToString:@"setDevice"]) {
        id uid = [call.arguments isKindOfClass:NSDictionary.class] ? call.arguments[@"uid"] : nil;
        if (uid && uid != NSNull.null && ![uid isKindOfClass:NSString.class]) {
            result([FlutterError errorWithCode:@"invalid_uid" message:@"uid must be a string or null" details:nil]);
            return;
        }
        _requestedUid = uid == NSNull.null || ![uid length] ? nil : [uid copy];
        _preservePlayer = NO;
        [_popover close];
        for (AVQueuePlayer *player in _players) player.allowsExternalPlayback = NO;
        if (_requestedUid) [[NSUserDefaults standardUserDefaults] setObject:_requestedUid forKey:WFRequestedOutputKey];
        else [[NSUserDefaults standardUserDefaults] removeObjectForKey:WFRequestedOutputKey];
        [self refresh];
        result([self state]);
    } else if ([call.method isEqualToString:@"showAirPlay"]) {
        [self showAirPlay:call.arguments result:result];
    } else result(FlutterMethodNotImplemented);
}

- (void)showAirPlay:(id)arguments result:(FlutterResult)result {
    if (@available(macOS 10.15, *)) {
        if (!_activePlayer || ![self canPresentAirPlay]) {
            result([FlutterError errorWithCode:@"no_active_player" message:@"Load a track before choosing AirPlay" details:nil]);
            return;
        }
        // The SDK reports externalPlaybackActive for video, not all audio routes.
        // Preserve this exact player until an explicit local output choice.
        // Opening or dismissing the picker is not a route selection. Keep the
        // last local choice and its persistence even while using a receiver.
        _activePlayer.allowsExternalPlayback = YES;
        _preservePlayer = YES;
        [self presentAirPlay:arguments];
        [self publish];
        result([self state]);
    } else {
        result([FlutterError errorWithCode:@"unsupported" message:@"AirPlay requires macOS 10.15 or newer" details:nil]);
    }
}

// The presentation boundary lets the native probe exercise the real routing
// state and delegate callbacks without creating an app or a window.
- (BOOL)canPresentAirPlay {
    return _anchorView.window != nil;
}

- (void)presentAirPlay:(id)arguments API_AVAILABLE(macos(10.15)) {
    NSView *anchor = _anchorView;
    [_popover close];
    NSViewController *controller = [[NSViewController alloc] init];
    controller.view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 240, 76)];
    NSTextField *label = [NSTextField labelWithString:@"AirPlay"];
    label.frame = NSMakeRect(14, 44, 212, 18);
    [controller.view addSubview:label];
    _picker = [[AVRoutePickerView alloc] initWithFrame:NSMakeRect(100, 6, 40, 32)];
    _picker.player = _activePlayer;
    _picker.delegate = self;
    _picker.routePickerButtonBordered = YES;
    [controller.view addSubview:_picker];
    _popover = [[NSPopover alloc] init];
    _popover.contentViewController = controller;
    _popover.behavior = NSPopoverBehaviorSemitransient;
    NSRect rect = NSMakeRect(NSMidX(anchor.bounds), NSMinY(anchor.bounds) + 70, 1, 1);
    if ([arguments isKindOfClass:NSDictionary.class] &&
        [arguments[@"x"] isKindOfClass:NSNumber.class] &&
        [arguments[@"y"] isKindOfClass:NSNumber.class]) {
        CGFloat x = [arguments[@"x"] doubleValue];
        CGFloat y = [arguments[@"y"] doubleValue];
        if (isfinite(x) && isfinite(y)) {
            rect.origin = NSMakePoint(x, anchor.isFlipped ? y : NSHeight(anchor.bounds) - y);
        }
    }
    [_popover showRelativeToRect:rect ofView:anchor preferredEdge:NSRectEdgeMaxY];
}

- (void)routePickerViewWillBeginPresentingRoutes:(AVRoutePickerView *)routePickerView API_AVAILABLE(macos(10.15)) {
    [self publish];
}

- (void)routePickerViewDidEndPresentingRoutes:(AVRoutePickerView *)routePickerView API_AVAILABLE(macos(10.15)) {
    // Presentation completion does not report whether an audio route changed.
    [self publish];
}

- (FlutterError *)onListenWithArguments:(id)arguments eventSink:(FlutterEventSink)events {
    _eventSink = events;
    [self refresh];
    return nil;
}

- (FlutterError *)onCancelWithArguments:(id)arguments {
    _eventSink = nil;
    return nil;
}

- (void)shutdown {
    if (_disposed) return;
    _disposed = YES;
    _eventSink = nil;
    [_methods setMethodCallHandler:nil];
    [_events setStreamHandler:nil];
    [_popover close];
    if (_activePlayer) {
        [_activePlayer removeObserver:self forKeyPath:@"externalPlaybackActive" context:WFOutputObservation];
        [_activePlayer removeObserver:self forKeyPath:@"audioOutputDeviceUniqueID" context:WFOutputObservation];
    }
    _activePlayer = nil;
    _activeOwner = nil;
    if (@available(macOS 10.15, *)) _picker.player = nil;
    [_players removeAllObjects];
    AudioObjectPropertyAddress addresses[] = {
        {kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain},
        {kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain}
    };
    for (NSUInteger i = 0; i < sizeof(addresses) / sizeof(addresses[0]); i++) {
        AudioObjectRemovePropertyListenerBlock(kAudioObjectSystemObject, &addresses[i], dispatch_get_main_queue(), _hardwareListener);
    }
    for (NSNumber *device in _observedDevices) [self observeDevice:device.unsignedIntValue add:NO];
    [_observedDevices removeAllObjects];
}

- (void)dealloc {
    [self shutdown];
}
@end
#endif
