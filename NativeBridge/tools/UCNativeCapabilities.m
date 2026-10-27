#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <sys/sysctl.h>
#import <mach/mach.h>
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
    for (NSString *part in @[@"tonemap", @"digitalflash", @"night", @"lowlight", @"low_light", @"capture", @"exposure", @"photo", @"fusion", @"bracket", @"init", @"viewdid", @"capabilit", @"duration"]) {
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
    if (!method && cls) method=class_getClassMethod(cls,sel_registerName(selector.UTF8String));
    if (!method) return @{@"class":className,@"selector":selector,@"present":@NO};
    IMP implementation = method_getImplementation(method);
#if __has_feature(ptrauth_calls)
    void *address = ptrauth_strip(implementation,ptrauth_key_function_pointer);
#else
    void *address = (void *)implementation;
#endif
    NSMutableData *data = [NSMutableData dataWithLength:4096]; vm_size_t read = 0;
    kern_return_t status = vm_read_overwrite(mach_task_self(),(vm_address_t)address,4096,(vm_address_t)data.mutableBytes,&read);
    data.length = status == KERN_SUCCESS ? (NSUInteger)read : 0;
    Dl_info image = {0}; dladdr(address,&image);
    NSMutableArray *calls = [NSMutableArray array];
    const uint32_t *words = data.bytes;
    for (NSUInteger i = 0; i < data.length/4; ++i) {
        uint32_t instruction = words[i];
        if ((instruction & 0xfc000000u) != 0x94000000u) continue;
        int64_t displacement = (int64_t)(int32_t)(instruction << 6) >> 4;
        uintptr_t target = (uintptr_t)address + i*4 + displacement;
        uint32_t stub[8] = {0}; vm_size_t stubRead = 0;
        if (vm_read_overwrite(mach_task_self(),target,sizeof(stub),(vm_address_t)stub,&stubRead) != KERN_SUCCESS) continue;
        NSString *selectorName = @"";
        for (unsigned j = 0; j+1 < stubRead/4; ++j) {
            if ((stub[j] & 0x9f00001fu) != 0x90000001u) continue;
            uint32_t load = stub[j+1];
            if ((load & 0xffc003ffu) != 0xf9400021u) continue;
            int64_t pages = (((stub[j] >> 5) & 0x7ffff) << 2) | ((stub[j] >> 29) & 3);
            if (pages & (1 << 20)) pages -= 1 << 21;
            uintptr_t slot = ((target+j*4) & ~(uintptr_t)0xfff) + pages*4096 + ((load >> 10) & 0xfff)*8;
            uintptr_t stringAddress = 0; vm_size_t readPointer = 0;
            if (vm_read_overwrite(mach_task_self(),slot,sizeof(stringAddress),(vm_address_t)&stringAddress,&readPointer) != KERN_SUCCESS) continue;
            char text[256] = {0}; vm_size_t textRead = 0;
            if (vm_read_overwrite(mach_task_self(),stringAddress,sizeof(text)-1,(vm_address_t)text,&textRead) != KERN_SUCCESS) continue;
            selectorName = [NSString stringWithUTF8String:text] ?: @"";
            break;
        }
        Dl_info targetInfo = {0}; dladdr((void *)target,&targetInfo);
        [calls addObject:@{@"offset":@(i*4),@"target":@(target),@"symbol":targetInfo.dli_sname ? @(targetInfo.dli_sname) : @"",@"selector":selectorName}];
    }
    return @{@"class":className,@"selector":selector,@"present":@YES,@"calls":calls,
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
        // Locate the conversion owner from its observed selector, not a guessed class name.
        unsigned classCount=0;Class *loaded=objc_copyClassList(&classCount);
        for (unsigned i=0;i<classCount;++i) {
            NSString *name=@(class_getName(loaded[i]));
            Method own=NULL;
            if ([name hasPrefix:@"AVCapture"] && loaded[i]!=objc_lookUpClass("AVCaptureDevice")) {
                Method method=class_getInstanceMethod(loaded[i],sel_registerName("setDigitalFlashMode:"));
                Method parent=class_getInstanceMethod(class_getSuperclass(loaded[i]),sel_registerName("setDigitalFlashMode:"));
                if (method && (!parent || method_getImplementation(method)!=method_getImplementation(parent))) own=method;
            }
            if (own || ([name hasPrefix:@"CAM"] && class_getClassMethod(loaded[i],sel_registerName("captureDigitalFlashModeForLowLightMode:"))))
                [classes addObject:Inspect(name)];
        }
        free(loaded);
        NSMutableArray *code = [NSMutableArray array];
        for (NSString *selector in @[@"_handleUserChangedToNightMode:",@"_handleNightModeIndicator",@"_isExpectedLowLightDurationCancelable",@"_lowLightModeForMode:captureMode:device:isBurst:",@"_resolvedLowLightMode",@"_desiredLowLightControlMode",@"viewDidAppear:"]) {
            [code addObject:Code(@"CAMViewfinderViewController",selector)];
        }
        [code addObject:Code(@"CAMStillImageCaptureRequest",@"_configurePhotoSettings:shouldIgnoreInitiationSettingsProperties:context:")];
        for (NSArray *pair in @[@[@"AVCapturePhotoSettings",@"setDigitalFlashMode:"],
            @[@"AVCapturePhotoSettings",@"digitalFlashMode"],
            @[@"CAMCaptureConversions",@"captureDigitalFlashModeForLowLightMode:"],
            @[@"AVCapturePhotoOutput",@"setDigitalFlashCaptureEnabled:"],
            @[@"AVCapturePhotoOutput",@"supportedDigitalFlashModes"],
            @[@"AVCaptureDevice",@"setDigitalFlashMode:"],
            @[@"AVCaptureFigVideoDevice",@"setDigitalFlashMode:"],
            @[@"AVCapturePhotoOutput",@"_updateSupportedDigitalFlashModesForSourceDevice:"],@[@"CUCaptureController",@"changeToLowLightMode:"],
            @[@"AVCapturePhotoOutput",@"_figCaptureIrisStillImageSettingsForAVCapturePhotoSettings:captureRequestIdentifier:delegate:connections:"]])
            [code addObject:Code(pair[0],pair[1])];
        NSDictionary *report = @{@"schema":@2,@"hardware":SystemString("hw.machine"),@"system_build":SystemString("kern.osversion"),@"system_version":NSProcessInfo.processInfo.operatingSystemVersionString,@"loads":loads,@"classes":classes,@"code_inspection":code,@"camera_objects_instantiated":@0,@"private_selectors_invoked":@0,@"capture_requests":@0};
        NSError *error = nil;
        NSData *json = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingSortedKeys error:&error];
        if (!json) { fprintf(stderr,"JSON error: %s\n",error.localizedDescription.UTF8String); return 1; }
        fwrite(json.bytes,1,json.length,stdout); fputc('\n',stdout);
    }
    return 0;
}
