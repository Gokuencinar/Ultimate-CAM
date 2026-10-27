#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
NS_ASSUME_NONNULL_BEGIN
/// Internal iPhone12,3 / 22H31 DigitalFlash route. All calls are signature-checked
/// and exception-contained. A configured request is not proof of ISP execution.
@interface UCNativePhotoNight : NSObject
+ (nullable NSString *)configureOutput:(AVCapturePhotoOutput *)output NS_SWIFT_NAME(configure(output:));
+ (nullable NSString *)setPreviewMode:(NSInteger)mode device:(AVCaptureDevice *)device NS_SWIFT_NAME(setPreview(mode:device:));
+ (nullable NSNumber *)toneMapping:(AVCaptureDevice *)device NS_SWIFT_NAME(toneMapping(device:));
+ (nullable NSString *)restoreToneMapping:(BOOL)enabled device:(AVCaptureDevice *)device NS_SWIFT_NAME(restoreToneMapping(enabled:device:));
+ (nullable NSNumber *)previewMode:(AVCaptureDevice *)device NS_SWIFT_NAME(previewMode(device:));
+ (nullable NSString *)applySettings:(AVCapturePhotoSettings *)settings output:(AVCapturePhotoOutput *)output mode:(NSInteger)mode NS_SWIFT_NAME(apply(settings:output:mode:));
+ (NSDictionary<NSString *,NSNumber *> *)resolvedInfo:(AVCaptureResolvedPhotoSettings *)settings NS_SWIFT_NAME(resolvedInfo(settings:));
@end
NS_ASSUME_NONNULL_END
