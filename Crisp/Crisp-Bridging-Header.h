//
//  Crisp-Bridging-Header.h
//  Crisp
//
//  Private API declarations for CGVirtualDisplay and IOAVService.
//  Property names verified against Chromium's virtual_display_mac_util.mm.
//

#ifndef Crisp_Bridging_Header_h
#define Crisp_Bridging_Header_h

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

// MARK: - CGVirtualDisplay Private API (macOS 14+)

@interface CGVirtualDisplayDescriptor : NSObject
@property (nonatomic) CGSize   sizeInMillimeters;   // physical size (width, height) in mm
@property (nonatomic) uint32_t maxPixelsWide;       // max pixel width
@property (nonatomic) uint32_t maxPixelsHigh;       // max pixel height
@property (nonatomic) NSPoint  whitePoint;
@property (nonatomic) NSPoint  redPrimary;
@property (nonatomic) NSPoint  greenPrimary;
@property (nonatomic) NSPoint  bluePrimary;
@property (nonatomic) dispatch_queue_t queue;
@property (nonatomic, copy) NSString *name;
@property (nonatomic) uint32_t vendorID;
@property (nonatomic) uint32_t productID;
@property (nonatomic) uint32_t serialNum;
@end

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(NSUInteger)width
                       height:(NSUInteger)height
                  refreshRate:(double)refreshRate;
@property (nonatomic, readonly) NSUInteger width;
@property (nonatomic, readonly) NSUInteger height;
@property (nonatomic, readonly) double     refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property (nonatomic) BOOL hiDPI;
@property (nonatomic, copy) NSArray *modes;
@end

@interface CGVirtualDisplay : NSObject
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@property (nonatomic, readonly) CGDirectDisplayID displayID;
@end

// MARK: - CGSDisplayMode (advanced resolution switching)

typedef struct {
    uint32_t modeID;
    uint32_t width;
    uint32_t height;
    uint32_t depth;
    double   refreshRate;
    uint32_t flags;        // bit 0x20000 = HiDPI
} CGSDisplayMode;

typedef int CGSConnectionID_t;
// Applies a mode by its raw modeNumber. arg1 is a CONFIG TOKEN from CGBeginDisplayConfiguration,
// NOT the connection id: the call reads it as a CGSConfigData*, so passing the connection id
// segfaults in checkCapacity() on macOS 26. Sequence: CGBeginDisplayConfiguration -> this ->
// CGCompleteDisplayConfiguration. Verified against BetterDisplay's behaviour on Tahoe.
extern CGError CGSConfigureDisplayMode(CGDisplayConfigRef config, CGDirectDisplayID display, int32_t modeNumber);
extern CGSConnectionID_t CGSMainConnectionID(void);

// Full CGS mode description for enumeration. CGDisplayCopyAllDisplayModes hides the GPU-scaled
// HiDPI variants of any resolution that collides with a real EDID timing (e.g. 1920x1080 HiDPI,
// whose 3840x2160 backing the panel exposes as a real 4K@50 timing); the private CGS list still
// carries them at full refresh. Layout reverse-engineered; offsets verified at runtime. `density`
// is the backing scale (2.0 == HiDPI); `flags` bit 0x40000000 marks modes macOS deems unusable
// (matches isUsableForDesktopGUI == false). modeNumber == ioDisplayModeID (pass to CGSConfigureDisplayMode).
typedef struct {
    uint32_t modeNumber;   // 0
    uint32_t flags;        // 4
    uint32_t width;        // 8   logical
    uint32_t height;       // 12  logical
    uint32_t depth;        // 16
    uint32_t dc2[42];      // 20
    uint16_t dc3;          // 188
    uint16_t freq;         // 190 refresh in Hz
    uint32_t dc4[4];       // 192
    float    density;      // 208 backing scale
} CGSDisplayModeDescription;   // 212 bytes

extern CGError CGSGetNumberOfDisplayModes(CGDirectDisplayID display, int *nModes);
extern CGError CGSGetDisplayModeDescriptionOfLength(CGDirectDisplayID display, int idx,
                                                    CGSDisplayModeDescription *mode, int length);

// MARK: - SkyLight Private API (physical display disconnect/reconnect, Apple Silicon)

// Enable/disable an individual display inside a CGBeginDisplayConfiguration transaction.
// On Apple Silicon (macOS 13+) disabling performs a true hardware disconnect (identical to
// clamshell): the display is removed from CGGetOnlineDisplayList / CGGetActiveDisplayList.
extern CGError SLSConfigureDisplayEnabled(CGDisplayConfigRef config,
                                          CGDirectDisplayID display,
                                          bool enabled);

// Enumerates ALL displays including ones disabled via SLSConfigureDisplayEnabled. Required to
// recover a disabled display's ID for reconnect, since CGGetOnlineDisplayList omits it.
extern CGError SLSGetDisplayList(uint32_t maxDisplays,
                                 CGDirectDisplayID *displays,
                                 uint32_t *displayCount);

// MARK: - IOAVService Private API (Apple Silicon DDC)

typedef void * IOAVServiceRef;
extern IOAVServiceRef IOAVServiceCreate(CFAllocatorRef allocator);
extern IOAVServiceRef IOAVServiceCreateWithService(CFAllocatorRef allocator, io_service_t service);
extern IOReturn IOAVServiceReadI2C(IOAVServiceRef service,
                                   uint32_t chipAddress,
                                   uint32_t offset,
                                   void *outputBuffer,
                                   uint32_t outputBufferSize);
extern IOReturn IOAVServiceWriteI2C(IOAVServiceRef service,
                                    uint32_t chipAddress,
                                    uint32_t dataAddress,
                                    void *inputBuffer,
                                    uint32_t inputBufferSize);

#import "Audio/SoftwareVolumeEngine.h"

#endif /* Crisp_Bridging_Header_h */
