#import "include/VTGWebPEncoder.h"

// Swift Package Manager resolves libwebp through the package dependency, which
// exposes <webp/encode.h>. CocoaPods installs the `libwebp` pod, which exposes
// the same header via a quoted or `libwebp/`-prefixed path depending on how the
// pod is integrated. If none of them resolve, the encoder degrades to a stub.
#if __has_include(<webp/encode.h>)
#import <webp/encode.h>
#define VTG_WEBP_AVAILABLE 1
#elif __has_include("webp/encode.h")
#import "webp/encode.h"
#define VTG_WEBP_AVAILABLE 1
#elif __has_include(<libwebp/encode.h>)
#import <libwebp/encode.h>
#define VTG_WEBP_AVAILABLE 1
#else
#define VTG_WEBP_AVAILABLE 0
#endif

@implementation VTGWebPEncoder

+ (BOOL)isAvailable {
    return VTG_WEBP_AVAILABLE ? YES : NO;
}

+ (nullable NSData *)encodedDataFromImage:(CGImageRef)image quality:(int)quality {
#if VTG_WEBP_AVAILABLE
    if (image == NULL) { return nil; }

    const int width  = (int)CGImageGetWidth(image);
    const int height = (int)CGImageGetHeight(image);
    if (width <= 0 || height <= 0) { return nil; }

    const int stride = width * 4;
    uint8_t *rawData = (uint8_t *)calloc((size_t)stride * (size_t)height, sizeof(uint8_t));
    if (rawData == NULL) { return nil; }

    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(rawData, width, height, 8, stride, colorSpace,
                                             (CGBitmapInfo)kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(colorSpace);
    if (ctx == NULL) {
        free(rawData);
        return nil;
    }

    CGContextDrawImage(ctx, CGRectMake(0, 0, width, height), image);
    CGContextRelease(ctx);

    uint8_t *output = NULL;
    size_t retSize = (quality >= 100)
        ? WebPEncodeLosslessRGBA(rawData, width, height, stride, &output)
        : WebPEncodeRGBA(rawData, width, height, stride, (float)quality, &output);

    free(rawData);

    if (retSize == 0 || output == NULL) { return nil; }

    NSData *data = [NSData dataWithBytes:(const void *)output length:retSize];
    WebPFree(output);   // free the libwebp-allocated buffer
    return data;
#else
    (void)image;
    (void)quality;
    return nil;
#endif
}

@end
