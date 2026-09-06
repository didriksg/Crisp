#import "SoftwareVolumeEngine.h"
#import <CoreAudio/CATapDescription.h>
#import <CoreAudio/AudioHardwareTapping.h>
#include <stdatomic.h>
#include <math.h>
#include <unistd.h>

_Static_assert(ATOMIC_INT_LOCK_FREE == 2 && ATOMIC_BOOL_LOCK_FREE == 2, "RT atomics must be lock free");
typedef struct {
    atomic_uint gainBits;
    atomic_bool disabled, invalid;
    bool inputPlanar, outputPlanar;
} VolumeState;

static void silence(AudioBufferList *output) {
    if (!output) return;
    for (UInt32 b = 0; b < output->mNumberBuffers; b++)
        if (output->mBuffers[b].mData) memset(output->mBuffers[b].mData, 0, output->mBuffers[b].mDataByteSize);
}
static UInt32 frames(const AudioBufferList *list, bool planar) {
    if (!list || list->mNumberBuffers != (planar ? 2u : 1u)) return 0;
    UInt32 bytes = list->mBuffers[0].mDataByteSize, stride = planar ? 4 : 8;
    if (!bytes || bytes % stride) return 0;
    for (UInt32 b = 0; b < list->mNumberBuffers; b++) {
        AudioBuffer buffer = list->mBuffers[b];
        if (!buffer.mData || buffer.mNumberChannels != (planar ? 1u : 2u) || buffer.mDataByteSize != bytes) return 0;
    }
    return bytes / stride;
}
BOOL SoftwareVolumeProcessBuffers(const AudioBufferList *input, AudioBufferList *output,
                                 BOOL inputPlanar, BOOL outputPlanar, float gain, BOOL disabled) {
    silence(output);
    if (disabled) return YES;
    UInt32 count = frames(input, inputPlanar);
    if (!count || frames(output, outputPlanar) != count || !isfinite(gain) || gain < 0 || gain > 1) return NO;
    for (UInt32 f = 0; f < count; f++) {
        for (UInt32 c = 0; c < 2; c++) {
            float value = ((const float *)input->mBuffers[inputPlanar ? c : 0].mData)[inputPlanar ? f : f * 2 + c];
            if (!isfinite(value)) { silence(output); return NO; }
            ((float *)output->mBuffers[outputPlanar ? c : 0].mData)[outputPlanar ? f : f * 2 + c] = value * gain;
        }
    }
    return YES;
}
static OSStatus replay(AudioDeviceID device, const AudioTimeStamp *now, const AudioBufferList *input,
                       const AudioTimeStamp *inputTime, AudioBufferList *output, const AudioTimeStamp *outputTime, void *context) {
    VolumeState *state = context;
    unsigned bits = atomic_load_explicit(&state->gainBits, memory_order_relaxed);
    float gain; memcpy(&gain, &bits, sizeof(gain));
    if (!SoftwareVolumeProcessBuffers(input, output, state->inputPlanar, state->outputPlanar, gain,
                                      atomic_load(&state->disabled) || atomic_load(&state->invalid)))
        atomic_store(&state->invalid, true);
    return noErr;
}
static OSStatus registerSilence(AudioDeviceID device, const AudioTimeStamp *now, const AudioBufferList *input,
                               const AudioTimeStamp *inputTime, AudioBufferList *output,
                               const AudioTimeStamp *outputTime, void *context) {
    silence(output); return noErr;
}
static AudioObjectPropertyAddress address(UInt32 selector, UInt32 scope) {
    return (AudioObjectPropertyAddress){selector, scope, kAudioObjectPropertyElementMain};
}
static BOOL readValue(AudioObjectID object, UInt32 selector, UInt32 scope, void *value, UInt32 size) {
    AudioObjectPropertyAddress a = address(selector, scope);
    UInt32 actual = size;
    return AudioObjectGetPropertyData(object, &a, 0, NULL, &actual, value) == noErr && actual == size;
}
static id readObject(AudioObjectID object, UInt32 selector) {
    CFTypeRef value = NULL;
    if (!readValue(object, selector, kAudioObjectPropertyScopeGlobal, &value, sizeof(value))) return nil;
    return value ? CFBridgingRelease(value) : nil;
}
static NSArray<NSNumber *> *ids(AudioObjectID object, UInt32 selector, UInt32 scope) {
    AudioObjectPropertyAddress a = address(selector, scope);
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(object, &a, 0, NULL, &size) || size % sizeof(AudioObjectID)) return nil;
    NSMutableData *data = [NSMutableData dataWithLength:size];
    if (size && AudioObjectGetPropertyData(object, &a, 0, NULL, &size, data.mutableBytes)) return nil;
    NSMutableArray *result = [NSMutableArray array];
    const AudioObjectID *values = data.bytes;
    for (NSUInteger i = 0; i < size / sizeof(AudioObjectID); i++) [result addObject:@(values[i])];
    return result;
}
static AudioDeviceID defaultOutput(void) {
    AudioDeviceID device = 0;
    readValue(kAudioObjectSystemObject, kAudioHardwarePropertyDefaultOutputDevice,
              kAudioObjectPropertyScopeGlobal, &device, sizeof(device));
    return device;
}
static BOOL validFormat(AudioStreamBasicDescription format, bool *planar) {
    *planar = (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
    UInt32 flags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | (*planar ? kAudioFormatFlagIsNonInterleaved : 0);
    // ponytail: only the verified stereo 48 kHz path; add conversion only with device evidence.
    return format.mSampleRate == 48000 && format.mFormatID == kAudioFormatLinearPCM && format.mFormatFlags == flags &&
        format.mChannelsPerFrame == 2 && format.mBitsPerChannel == 32 && format.mFramesPerPacket == 1 &&
        format.mBytesPerFrame == (*planar ? 4u : 8u) && format.mBytesPerPacket == format.mBytesPerFrame;
}
static AudioObjectID streamFormat(AudioDeviceID device, UInt32 scope, bool *planar) {
    NSArray *streams = ids(device, kAudioDevicePropertyStreams, scope);
    if (streams.count != 1) return 0;
    AudioObjectID stream = [streams[0] unsignedIntValue];
    UInt32 start = 0;
    AudioStreamBasicDescription format = {0};
    if (!readValue(stream, kAudioStreamPropertyStartingChannel, kAudioObjectPropertyScopeGlobal, &start, sizeof(start)) || start != 1 ||
        !readValue(stream, kAudioStreamPropertyVirtualFormat, kAudioObjectPropertyScopeGlobal, &format, sizeof(format)) ||
        !validFormat(format, planar)) return 0;
    AudioStreamBasicDescription physical = {0};
    if (!readValue(stream, kAudioStreamPropertyPhysicalFormat, kAudioObjectPropertyScopeGlobal, &physical, sizeof(physical)) ||
        physical.mFormatID != kAudioFormatLinearPCM || physical.mChannelsPerFrame != 2 || physical.mSampleRate != 48000) return 0;
    return stream;
}

@implementation SoftwareVolumeEngine {
    VolumeState *_state;
    AudioDeviceID _device, _aggregate;
    AudioObjectID _tap, _process, _stream;
    AudioDeviceIOProcID _registration, _replay;
    NSString *_deviceUID, *_aggregateUID;
    NSUUID *_tapUUID;
    BOOL _registrationStarted, _replayStarted, _stopped, _stopOK;
    NSMutableArray<NSDictionary *> *_listeners;
    dispatch_queue_t _listenerQueue;
    AudioObjectPropertyListenerBlock _listener;
}
- (instancetype)init {
    if ((self = [super init])) {
        _state = calloc(1, sizeof(VolumeState));
        atomic_init(&_state->disabled, true); atomic_init(&_state->invalid, false);
        atomic_init(&_state->gainBits, 0); [self setGain:0.25f];
        _listeners = [NSMutableArray array];
        _listenerQueue = dispatch_queue_create("com.crisp.software-volume.properties", DISPATCH_QUEUE_SERIAL);
        VolumeState *state = _state;
        _listener = ^(UInt32 count, const AudioObjectPropertyAddress *addresses) {
            atomic_store(&state->invalid, true);
        };
    }
    return self;
}
- (void)setGain:(float)gain {
    gain = isfinite(gain) ? fmaxf(0, fminf(1, gain)) : 0;
    unsigned bits; memcpy(&bits, &gain, sizeof(bits));
    atomic_store_explicit(&_state->gainBits, bits, memory_order_relaxed);
}
- (BOOL)listen:(AudioObjectID)object selector:(UInt32)selector scope:(UInt32)scope {
    AudioObjectPropertyAddress a = address(selector, scope);
    if (AudioObjectAddPropertyListenerBlock(object, &a, _listenerQueue, _listener)) return NO;
    [_listeners addObject:@{@"object": @(object), @"selector": @(selector), @"scope": @(scope)}];
    return YES;
}
- (BOOL)verifyTap {
    CATapDescription *d = readObject(_tap, kAudioTapPropertyDescription);
    if (![d isKindOfClass:CATapDescription.class]) return NO;
    BOOL bundlesOK = YES;
    if (@available(macOS 26.0, *)) {
        // HAL may normalize an empty bundle list to the excluded process's bundle ID.
        // Only our exact live process remains excluded, without restore-by-bundle semantics.
        bundlesOK = !d.processRestoreEnabled && (d.bundleIDs.count == 0 ||
            [d.bundleIDs isEqual:@[NSBundle.mainBundle.bundleIdentifier ?: @"com.crisp.app"]]);
    }
    return bundlesOK && [d.processes isEqual:@[@(_process)]] && d.exclusive && d.privateTap && !d.mixdown && !d.mono &&
        [d.deviceUID isEqual:_deviceUID] && [d.stream isEqual:@0] && [d.UUID isEqual:_tapUUID] &&
        d.muteBehavior == CATapMutedWhenTapped && [readObject(_tap, kAudioTapPropertyUID) isEqual:_tapUUID.UUIDString];
}
- (BOOL)verifyAggregate {
    NSDictionary *composition = readObject(_aggregate, kAudioAggregateDevicePropertyComposition);
    return [composition isKindOfClass:NSDictionary.class] && [composition[@kAudioAggregateDeviceIsPrivateKey] boolValue] &&
        [composition[@kAudioAggregateDeviceUIDKey] isEqual:_aggregateUID] &&
        [readObject(_aggregate, kAudioAggregateDevicePropertyFullSubDeviceList) isEqual:@[_deviceUID]] &&
        [ids(_aggregate, kAudioAggregateDevicePropertyActiveSubDeviceList, kAudioObjectPropertyScopeGlobal) isEqual:@[@(_device)]] &&
        [readObject(_aggregate, kAudioAggregateDevicePropertyTapList) isEqual:@[_tapUUID.UUIDString]] &&
        [readObject(_aggregate, kAudioAggregateDevicePropertyMainSubDevice) isEqual:_deviceUID];
}
- (BOOL)startDevice:(AudioDeviceID)device error:(NSError **)error {
    NSString *step = @"output format";
    OSStatus status = noErr;
    _device = device; _deviceUID = readObject(device, kAudioDevicePropertyDeviceUID);
    _aggregateUID = [@"com.crisp.software-volume." stringByAppendingString:NSUUID.UUID.UUIDString];
    _tapUUID = NSUUID.UUID;
    do {
        UInt32 transport = 0;
        NSArray *inputs = ids(device, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput);
        _stream = streamFormat(device, kAudioObjectPropertyScopeOutput, &_state->outputPlanar);
        if (!device || defaultOutput() != device || !_deviceUID || !_stream || !inputs || inputs.count ||
            !readValue(device, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal, &transport, sizeof(transport)) ||
            (transport != kAudioDeviceTransportTypeHDMI && transport != kAudioDeviceTransportTypeDisplayPort)) break;
        step = @"register Crisp audio process";
        // TranslatePID returns unknown (not an error) for an audio-inactive process. Connect
        // our own silent output client first, and keep it alive until replay is running.
        status = AudioDeviceCreateIOProcID(device, registerSilence, NULL, &_registration);
        if (status) break;
        _registrationStarted = YES;
        status = AudioDeviceStart(device, _registration); if (status) break;
        pid_t pid = getpid(), reverse = 0;
        AudioObjectPropertyAddress a = address(kAudioHardwarePropertyTranslatePIDToProcessObject, kAudioObjectPropertyScopeGlobal);
        for (int attempt = 0; attempt < 20 && !_process; attempt++) {
            UInt32 size = sizeof(_process);
            status = AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, sizeof(pid), &pid, &size, &_process);
            if (status || size != sizeof(_process)) { _process = 0; break; }
            if (!_process) usleep(10000);
        }
        if (!_process || !readValue(_process, kAudioProcessPropertyPID, kAudioObjectPropertyScopeGlobal, &reverse, sizeof(reverse)) || reverse != pid) break;
        step = @"create device tap (check System Audio Recording permission)";
        CATapDescription *description = [[CATapDescription alloc] initExcludingProcesses:@[@(_process)] andDeviceUID:_deviceUID withStream:0];
        description.UUID = _tapUUID; description.name = @"Crisp Software Volume";
        description.exclusive = YES; description.privateTap = YES; description.mixdown = NO; description.mono = NO;
        description.muteBehavior = CATapMutedWhenTapped;
        if (@available(macOS 26.0, *)) { description.processRestoreEnabled = NO; description.bundleIDs = @[]; }
        status = AudioHardwareCreateProcessTap(description, &_tap); if (status || !_tap) break;
        step = @"verify device tap scope";
        if (![self verifyTap]) break;
        AudioStreamBasicDescription format = {0};
        if (!readValue(_tap, kAudioTapPropertyFormat, kAudioObjectPropertyScopeGlobal, &format, sizeof(format)) ||
            !validFormat(format, &_state->inputPlanar)) break;
        step = @"create private output aggregate";
        NSDictionary *composition = @{
            @kAudioAggregateDeviceNameKey: @"Crisp Software Volume (Private)", @kAudioAggregateDeviceUIDKey: _aggregateUID,
            @kAudioAggregateDeviceIsPrivateKey: @YES, @kAudioAggregateDeviceMainSubDeviceKey: _deviceUID,
            @kAudioAggregateDeviceSubDeviceListKey: @[@{@kAudioSubDeviceUIDKey: _deviceUID}],
            @kAudioAggregateDeviceTapListKey: @[@{@kAudioSubTapUIDKey: _tapUUID.UUIDString}], @kAudioAggregateDeviceTapAutoStartKey: @NO};
        status = AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)composition, &_aggregate);
        if (status || !_aggregate) break;
        step = @"verify aggregate format and scope";
        bool inputPlanar, outputPlanar;
        AudioObjectID inputStream = streamFormat(_aggregate, kAudioObjectPropertyScopeInput, &inputPlanar);
        AudioObjectID outputStream = streamFormat(_aggregate, kAudioObjectPropertyScopeOutput, &outputPlanar);
        if (![self verifyAggregate] || !inputStream || !outputStream) break;
        _state->inputPlanar = inputPlanar; _state->outputPlanar = outputPlanar;
        step = @"watch output route and format";
        if (![self listen:inputStream selector:kAudioStreamPropertyVirtualFormat scope:kAudioObjectPropertyScopeGlobal] ||
            ![self listen:outputStream selector:kAudioStreamPropertyVirtualFormat scope:kAudioObjectPropertyScopeGlobal] ||
            ![self listen:_tap selector:kAudioTapPropertyDescription scope:kAudioObjectPropertyScopeGlobal] ||
            ![self listen:_tap selector:kAudioTapPropertyFormat scope:kAudioObjectPropertyScopeGlobal] ||
            ![self listen:kAudioObjectSystemObject selector:kAudioHardwarePropertyDefaultOutputDevice scope:kAudioObjectPropertyScopeGlobal] ||
            ![self listen:device selector:kAudioDevicePropertyDeviceIsAlive scope:kAudioObjectPropertyScopeGlobal] ||
            ![self listen:device selector:kAudioDevicePropertyStreams scope:kAudioObjectPropertyScopeOutput] ||
            ![self listen:_stream selector:kAudioStreamPropertyVirtualFormat scope:kAudioObjectPropertyScopeGlobal] ||
            ![self listen:_stream selector:kAudioStreamPropertyPhysicalFormat scope:kAudioObjectPropertyScopeGlobal]) break;
        step = @"start replay";
        if (![self isHealthy] || ![self verifyTap]) break;
        status = AudioDeviceCreateIOProcID(_aggregate, replay, _state, &_replay); if (status) break;
        atomic_store(&_state->disabled, false);
        _replayStarted = YES;
        status = AudioDeviceStart(_aggregate, _replay); if (status) break;
        return YES;
    } while (0);
    if (error) *error = [NSError errorWithDomain:@"com.crisp.software-volume" code:status ?: -1
        userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@: OSStatus %d", step, (int)status]}];
    return NO; // Caller always stops partial initialization before releasing this object.
}
- (BOOL)isHealthy {
    bool planar;
    pid_t pid = 0;
    return !_stopped && !atomic_load(&_state->invalid) && defaultOutput() == _device &&
        [readObject(_device, kAudioDevicePropertyDeviceUID) isEqual:_deviceUID] &&
        streamFormat(_device, kAudioObjectPropertyScopeOutput, &planar) == _stream &&
        readValue(_process, kAudioProcessPropertyPID, kAudioObjectPropertyScopeGlobal, &pid, sizeof(pid)) && pid == getpid();
}
- (BOOL)stop {
    if (_stopped) return _stopOK;
    _stopped = YES; atomic_store(&_state->disabled, true);
    BOOL ok = YES;
    for (NSDictionary *entry in _listeners) {
        AudioObjectPropertyAddress a = address([entry[@"selector"] unsignedIntValue], [entry[@"scope"] unsignedIntValue]);
        ok &= AudioObjectRemovePropertyListenerBlock([entry[@"object"] unsignedIntValue], &a, _listenerQueue, _listener) == noErr;
    }
    [_listeners removeAllObjects];
    dispatch_sync(_listenerQueue, ^{}); // Retire already queued property callbacks before freeing their context.
    if (_replayStarted) ok &= AudioDeviceStop(_aggregate, _replay) == noErr;
    if (_replay) ok &= AudioDeviceDestroyIOProcID(_aggregate, _replay) == noErr;
    if (_registrationStarted) ok &= AudioDeviceStop(_device, _registration) == noErr;
    if (_registration) ok &= AudioDeviceDestroyIOProcID(_device, _registration) == noErr;
    // If HAL cannot retire a callback/listener, keep its disabled state alive and refuse
    // another session. Never free memory CoreAudio might still access or double-destroy.
    if (ok) {
        if (_aggregate) ok &= AudioHardwareDestroyAggregateDevice(_aggregate) == noErr;
        if (_tap) ok &= AudioHardwareDestroyProcessTap(_tap) == noErr;
    }
    _stopOK = ok;
    return ok;
}
- (BOOL)objectsGone {
    if (!_stopped || !_stopOK) return NO;
    NSArray *devices = ids(kAudioObjectSystemObject, kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal);
    NSArray *taps = ids(kAudioObjectSystemObject, kAudioHardwarePropertyTapList, kAudioObjectPropertyScopeGlobal);
    if (!devices || !taps || (_aggregate && [devices containsObject:@(_aggregate)]) || (_tap && [taps containsObject:@(_tap)])) return NO;
    for (NSNumber *device in devices)
        if ([readObject(device.unsignedIntValue, kAudioDevicePropertyDeviceUID) isEqual:_aggregateUID]) return NO;
    for (NSNumber *tap in taps)
        if ([readObject(tap.unsignedIntValue, kAudioTapPropertyUID) isEqual:_tapUUID.UUIDString]) return NO;
    return YES;
}
- (void)dealloc {
    // Successful stop retires both IOProcs and listeners before the state is freed.
    // On failure intentionally retain this tiny allocation until process exit.
    if (_stopped && _stopOK) free(_state);
}
@end
