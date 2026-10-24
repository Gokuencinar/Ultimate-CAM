#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <sys/sysctl.h>

// Inspection only. No capture session, camera device, controller or photo
// settings object is instantiated. No selectors are invoked on private objects.
static NSString *SystemString(const char *key) {
    char value[256] = {0}; size_t size = sizeof(value);
    return sysctlbyname(key, value, &size, NULL, 0) == 0 ? @(value) : @"unavailable";
}

static BOOL Relevant(NSString *name) {
    NSString *lower = name.lowercaseString;
    for (NSString *part in @[@"night", @"lowlight", @"low_light", @"capture", @"exposure", @"photo", @"fusion", @"bracket"]) {
        if ([lower containsString:part]) return YES;
    }
    return NO;
}

static NSArray *Methods(Class cls, BOOL meta) {
    unsigned count = 0; Method *methods = class_copyMethodList(meta ? object_getClass(cls) : cls, &count);
    NSMutableArray *result = [NSMutableArray array];
    for (unsigned i = 0; i < count && result.count < 250; ++i) {
        const char *selector = sel_getName(method_getName(methods[i]));
        if (!selector || !Relevant(@(selector))) continue;
        const char *encoding = method_getTypeEncoding(methods[i]);
        [result addObject:@{@"selector":@(selector), @"encoding":encoding ? @(encoding) : @"", @"arguments":@(method_getNumberOfArguments(methods[i]))}];
    }
    free(methods);
    return result;
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
        for (NSString *name in @[@"AVCapturePhotoSettings",@"AVCaptureResolvedPhotoSettings",@"AVCapturePhotoOutput",@"AVCaptureDevice",@"CAMCaptureCapabilities",@"CAMCaptureController",@"CAMCaptureEngine",@"CAMViewfinderViewController",@"CAMCaptureRequest",@"CAMStillImageCaptureRequest",@"CAMMutableStillImageCaptureRequest",@"CAMStillImageCaptureResolvedSettings",@"CAMStillImageCaptureResponse",@"CAMLowLightSlider",@"CAMLowLightStatusIndicator",@"CAMNightModeSlider",@"CAMNightModeStatusIndicator"]) {
            [classes addObject:Inspect(name)];
        }
        NSDictionary *report = @{@"schema":@1,@"hardware":SystemString("hw.machine"),@"system_build":SystemString("kern.osversion"),@"system_version":NSProcessInfo.processInfo.operatingSystemVersionString,@"loads":loads,@"classes":classes,@"camera_objects_instantiated":@0,@"private_selectors_invoked":@0,@"capture_requests":@0};
        NSError *error = nil;
        NSData *json = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingSortedKeys error:&error];
        if (!json) { fprintf(stderr,"JSON error: %s\n",error.localizedDescription.UTF8String); return 1; }
        fwrite(json.bytes,1,json.length,stdout); fputc('\n',stdout);
    }
    return 0;
}
