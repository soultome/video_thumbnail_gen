//
//  VTGWebPEncoder.h
//  video_thumbnail_gen
//
//  Thin Objective-C bridge over libwebp, kept separate from the Swift plugin
//  because libwebp is a C library that a pure-Swift target cannot link.
//
//  libwebp is only pulled in by the CocoaPods integration. Under Swift Package
//  Manager it is absent, `available` reports NO, and the Swift layer falls back
//  to JPEG — the same behaviour the plugin has always had under SPM.
//

#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface VTGWebPEncoder : NSObject

/// YES when the plugin was built against libwebp (the CocoaPods integration).
@property (class, nonatomic, readonly, getter=isAvailable) BOOL available;

/// Encodes `image` as WebP. `quality` is 0–100; 100 selects lossless encoding.
/// Returns nil when libwebp is unavailable or encoding fails.
+ (nullable NSData *)encodedDataFromImage:(CGImageRef)image
                                  quality:(int)quality
    NS_SWIFT_NAME(encodedData(from:quality:));

@end

NS_ASSUME_NONNULL_END
