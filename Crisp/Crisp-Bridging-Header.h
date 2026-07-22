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
extern CGError CGSConfigureDisplayMode(CGSConnectionID_t connection, CGDirectDisplayID display, uint32_t modeID);
extern CGSConnectionID_t CGSMainConnectionID(void);

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

#endif /* Crisp_Bridging_Header_h */
