#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudio.h>

NS_ASSUME_NONNULL_BEGIN
// All lifecycle methods run on the main thread. Only DSP state crosses into CoreAudio.
API_AVAILABLE(macos(14.2))
@interface SoftwareVolumeEngine : NSObject
- (BOOL)startDevice:(AudioDeviceID)device error:(NSError **)error;
- (void)setGain:(float)gain;
- (BOOL)isHealthy;
- (BOOL)stop;
- (BOOL)objectsGone;
@end

// Shared by the real IOProc and the headless test target; never starts audio.
BOOL SoftwareVolumeProcessBuffers(const AudioBufferList * _Nullable input,
                                 AudioBufferList * _Nullable output,
                                 BOOL inputPlanar, BOOL outputPlanar, float gain, BOOL disabled);
NS_ASSUME_NONNULL_END
