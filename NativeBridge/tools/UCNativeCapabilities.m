#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <sys/sysctl.h>
#import <mach/mach.h>
#import <mach/mach_vm.h>
#if __has_feature(ptrauth_calls)
#import <ptrauth.h>
#endif

// Inspection only. No capture session, camera device, controller or photo
// settings object is instantiated. No selectors are invoked on private objects.
static NSString *SystemString(const char *key) {
    char value[256] = {0}; size_t size = sizeof(value);
    return sysctlbyname(key, value, &size, NULL, 0) == 0 ? @(value) : @"unavailable";
}

static BOOL Relevant(NSString *name) {
    NSString *lower = name.lowercaseString;
    for (NSString *part in @[@"night", @"lowlight", @"low_light", @"capture", @"exposure", @"photo", @"fusion", @"bracket", @"init", @"viewdid", @"capabilit", @"duration"]) {
        if ([lower containsString:part]) return YES;
    }
    return NO;
}

static NSArray *Methods(Class cls, BOOL meta) {
    unsigned count = 0; Method *methods = class_copyMethodList(meta ? object_getClass(cls) : cls, &count);
    NSMutableArray *result = [NSMutableArray array];
    for (unsigned i = 0; i < count && result.count < 1500; ++i) {
        const char *selector = sel_getName(method_getName(methods[i]));
        if (!selector || !Relevant(@(selector))) continue;
        const char *encoding = method_getTypeEncoding(methods[i]);
        [result addObject:@{@"selector":@(selector), @"encoding":encoding ? @(encoding) : @"", @"arguments":@(method_getNumberOfArguments(methods[i]))}];
    }
    free(methods);
    return result;
}

static NSDictionary *Code(NSString *className, NSString *selector) {
    Class cls = objc_lookUpClass(className.UTF8String);
    Method method = cls ? class_getInstanceMethod(cls, sel_registerName(selector.UTF8String)) : NULL;
    if (!method) return @{@"class":className,@"selector":selector,@"present":@NO};
    IMP implementation = method_getImplementation(method);
#if __has_feature(ptrauth_calls)
    void *address = ptrauth_strip(implementation,ptrauth_key_function_pointer);
#else
    void *address = (void *)implementation;
#endif
    NSMutableData *data = [NSMutableData dataWithLength:1024]; mach_vm_size_t read = 0;
    kern_return_t status = mach_vm_read_overwrite(mach_task_self(),(mach_vm_address_t)address,1024,(mach_vm_address_t)data.mutableBytes,&read);
    data.length = status == KERN_SUCCESS ? (NSUInteger)read : 0;
    Dl_info image = {0}; dladdr(address,&image);
    return @{@"class":className,@"selector":selector,@"present":@YES,
             @"encoding":@(method_getTypeEncoding(method)),@"address":@((uintptr_t)address),
             @"image_base":@((uintptr_t)image.dli_fbase),@"bytes_base64":[data base64EncodedStringWithOptions:0],@"read_status":@(status)};
}

static NSDictionary *Inspect(NSString *name) {
    Class cls = objc_lookUpClass(name.UTF8String);
    if (!cls) return @{@"class":name, @"present":@NO};
    const char *image = class_getImageName(cls);
    NSMutableArray *properties = [NSMutableArray array];
    unsigned count = 0; objc_property_t *props = class_copyPropertyList(cls, &count);
    for (unsigned i = 0; i < count && properties.count < 200; ++i) {
        const char *property = property_getName(props[i]);
        if (!property || !Relevant(@(property))) continue;
        const char *attributes = property_getAttributes(props[i]);
        [properties addObject:@{@"name":@(property),@"attributes":attributes ? @(attributes) : @""}];
    }
    free(props);
    return @{@"class":name,@"present":@YES,@"image":image ? @(image) : @"",@"instance_methods":Methods(cls,NO),@"class_methods":Methods(cls,YES),@"properties":properties};
}

int main(void) {
    @autoreleasepool {
        NSMutableArray *loads = [NSMutableArray array];
        for (NSString *path in @[@"/System/Library/Frameworks/AVFoundation.framework/AVFoundation", @"/System/Library/PrivateFrameworks/CameraUI.framework/CameraUI"]) {
            dlerror();
            void *handle = dlopen(path.UTF8String, RTLD_LAZY | RTLD_LOCAL);
            const char *error = dlerror();
            [loads addObject:@{@"path":path,@"loaded":@(handle != NULL),@"error":error ? @(error) : @""}];
        }
        NSMutableArray *classes = [NSMutableArray array];
        for (NSString *name in @[@"AVCapturePhotoSettings",@"AVCapturePhotoInitiationSettings",@"AVCaptureMomentCaptureSettings",@"AVCaptureResolvedPhotoSettings",@"AVCapturePhotoOutput",@"AVCaptureDevice",@"CUCaptureController",@"CAMGraphConfiguration",@"CAMCaptureCapabilities",@"CAMCaptureController",@"CAMCaptureEngine",@"CAMViewfinderViewController",@"CAMCaptureRequest",@"CAMStillImageCaptureRequest",@"CAMMutableStillImageCaptureRequest",@"CAMStillImageCaptureResolvedSettings",@"CAMStillImageCaptureResponse",@"CAMLowLightSlider",@"CAMLowLightStatusIndicator",@"CAMNightModeSlider",@"CAMNightModeStatusIndicator"]) {
            [classes addObject:Inspect(name)];
        }
        NSMutableArray *code = [NSMutableArray array];
        for (NSString *selector in @[@"_handleUserChangedToNightMode:",@"_handleNightModeIndicator",@"_lowLightModeForMode:captureMode:device:isBurst:",@"_resolvedLowLightMode",@"_desiredLowLightControlMode",@"viewDidAppear:"]) {
            [code addObject:Code(@"CAMViewfinderViewController",selector)];
        }
        [code addObject:Code(@"CAMStillImageCaptureRequest",@"_configurePhotoSettings:shouldIgnoreInitiationSettingsProperties:context:")];
        NSDictionary *report = @{@"schema":@2,@"hardware":SystemString("hw.machine"),@"system_build":SystemString("kern.osversion"),@"system_version":NSProcessInfo.processInfo.operatingSystemVersionString,@"loads":loads,@"classes":classes,@"code_inspection":code,@"camera_objects_instantiated":@0,@"private_selectors_invoked":@0,@"capture_requests":@0};
        NSError *error = nil;
        NSData *json = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingSortedKeys error:&error];
        if (!json) { fprintf(stderr,"JSON error: %s\n",error.localizedDescription.UTF8String); return 1; }
        fwrite(json.bytes,1,json.length,stdout); fputc('\n',stdout);
    }
    return 0;
}
