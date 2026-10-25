#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <notify.h>
#import <sys/sysctl.h>
#import <time.h>
#import "UCNativeNightProtocol.h"

typedef void (*HookMessage)(Class,SEL,IMP,IMP *);
typedef void (*ViewAppeared)(id,SEL,BOOL);
typedef void (*UserChanged)(id,SEL,NSUInteger);
typedef long long (*ResolveMode)(id,SEL,long long,long long,long long,BOOL);
static ViewAppeared originalAppeared;
static UserChanged originalChanged;
static ResolveMode originalResolve;
static int intentToken, statusToken, ackToken, controlToken, resolvedToken, confirmedToken, previousToken;
static __weak id currentViewfinder;
static uint64_t appliedRequest;
static NSUInteger previousControl;
static BOOL applying;

static long long Snapshot(id viewfinder) {
    long long resolved=((long long(*)(id,SEL))objc_msgSend)(viewfinder,sel_registerName("_resolvedLowLightMode"));
    NSUInteger control=((NSUInteger(*)(id,SEL))objc_msgSend)(viewfinder,sel_registerName("_desiredLowLightControlMode"));
    notify_set_state(controlToken,control); notify_set_state(resolvedToken,(uint64_t)resolved);
    return resolved;
}

static uint64_t Intent(void) { uint64_t value=0; notify_get_state(intentToken,&value); return value; }
static void Status(uint64_t request, enum UCNStatus status) {
    notify_set_state(ackToken,request); notify_set_state(statusToken,status);
}
static BOOL TargetMatches(void) {
    char model[64]={0},build[64]={0}; size_t m=sizeof(model),b=sizeof(build);
    return sysctlbyname("hw.machine",model,&m,NULL,0)==0 && sysctlbyname("kern.osversion",build,&b,NULL,0)==0 &&
        strcmp(model,"iPhone12,3")==0 && strcmp(build,"22H31")==0;
}
static BOOL Signature(Class cls, const char *name, const char *encoding) {
    Method method=class_getInstanceMethod(cls,sel_registerName(name));
    return method && strcmp(method_getTypeEncoding(method),encoding)==0;
}
static void Disarm(BOOL restore) {
    uint64_t request=appliedRequest;
    notify_set_state(intentToken,0);
    id viewfinder=currentViewfinder;
    if (restore && request && viewfinder && originalChanged) {
        applying=YES;
        @try { originalChanged(viewfinder,sel_registerName("_handleUserChangedToNightMode:"),previousControl); Snapshot(viewfinder); }
        @catch (NSException *exception) { NSLog(@"UltimateCAM NativeNight restore: %@",exception.name); }
        applying=NO;
    }
    appliedRequest=0; Status(request,UCNStatusIdle);
}
static void ApplyIntent(void) {
    NSCAssert(NSThread.isMainThread,@"Native Camera UI must stay on its main thread");
    uint64_t request=Intent();
    if (!UCNIntentValid(request,(uint64_t)time(NULL))) { if (appliedRequest) Disarm(YES); return; }
    id viewfinder=currentViewfinder;
    if (!viewfinder || appliedRequest==request) return;
    @try {
        if (!appliedRequest) {
            previousControl=((NSUInteger(*)(id,SEL))objc_msgSend)(viewfinder,sel_registerName("_desiredLowLightControlMode"));
            notify_set_state(previousToken,previousControl);
        }
        appliedRequest=request; applying=YES;
        // Native control value 2 selects the second (maximum) duration. ABI and
        // this duration selection are recorded from CameraUI on build 22H31.
        originalChanged(viewfinder,sel_registerName("_handleUserChangedToNightMode:"),2);
        applying=NO;
        long long resolved=Snapshot(viewfinder);
        if (resolved==2) notify_set_state(confirmedToken,request);
        Status(request,resolved==2 ? UCNStatusControlApplied : UCNStatusConflict);
        uint64_t remaining=(request>>16)-(uint64_t)time(NULL);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(MIN(remaining,(uint64_t)UCN_MAX_TTL)*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
            if (appliedRequest==request && !UCNIntentValid(Intent(),(uint64_t)time(NULL))) Disarm(YES);
        });
    } @catch (NSException *exception) {
        applying=NO; NSLog(@"UltimateCAM NativeNight apply: %@",exception.name); Disarm(YES);
        Status(request,UCNStatusConflict);
    }
}
static void Appeared(id self,SEL command,BOOL animated) {
    originalAppeared(self,command,animated);
    currentViewfinder=self; ApplyIntent();
}
static void Changed(id self,SEL command,NSUInteger value) {
    // A manual choice in Camera always takes precedence over our pending intent.
    if (!applying && appliedRequest) Disarm(NO);
    originalChanged(self,command,value);
}
static long long Resolved(id self,SEL command,long long mode,long long captureMode,long long device,BOOL burst) {
    uint64_t request=Intent(); BOOL armed=UCNIntentValid(request,(uint64_t)time(NULL));
    // Run Apple's original capability, device, burst and conflict checks with
    // the requested native mode. Never fake support or overwrite a duration.
    long long value=originalResolve(self,command,armed ? 2 : mode,captureMode,device,burst);
    if (armed) Status(request,value==2 ? UCNStatusControlApplied : UCNStatusConflict);
    return value;
}
static void IntentChanged(CFNotificationCenterRef center,void *observer,CFStringRef name,const void *object,CFDictionaryRef info) {
    (void)center;(void)observer;(void)name;(void)object;(void)info;
    dispatch_async(dispatch_get_main_queue(),^{ ApplyIntent(); });
}

__attribute__((constructor)) static void Install(void) {
    @autoreleasepool {
        if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.camera"]) return;
        if (notify_register_check(UCN_INTENT_NAME,&intentToken)!=NOTIFY_STATUS_OK ||
            notify_register_check(UCN_STATUS_NAME,&statusToken)!=NOTIFY_STATUS_OK ||
            notify_register_check(UCN_ACK_NAME,&ackToken)!=NOTIFY_STATUS_OK ||
            notify_register_check(UCN_CONTROL_NAME,&controlToken)!=NOTIFY_STATUS_OK ||
            notify_register_check(UCN_RESOLVED_NAME,&resolvedToken)!=NOTIFY_STATUS_OK ||
            notify_register_check(UCN_CONFIRMED_NAME,&confirmedToken)!=NOTIFY_STATUS_OK ||
            notify_register_check(UCN_PREVIOUS_NAME,&previousToken)!=NOTIFY_STATUS_OK) return;
        if (!TargetMatches()) { Status(0,UCNStatusUnsupported); return; }
        Class cls=objc_lookUpClass("CAMViewfinderViewController");
        if (!cls || !Signature(cls,"viewDidAppear:","v20@0:8B16") ||
            !Signature(cls,"_handleUserChangedToNightMode:","v24@0:8Q16") ||
            !Signature(cls,"_lowLightModeForMode:captureMode:device:isBurst:","q44@0:8q16q24q32B40") ||
            !Signature(cls,"_desiredLowLightControlMode","Q16@0:8") ||
            !Signature(cls,"_resolvedLowLightMode","q16@0:8")) { Status(0,UCNStatusABIRejected); return; }
        HookMessage hook=(HookMessage)dlsym(RTLD_DEFAULT,"MSHookMessageEx");
        if (!hook) {
            const char *path="/var/jb/usr/lib/libsubstrate.dylib";
#if UCN_ROOTHIDE
            // RootHide creates this backlink beside the loaded Mach-O. Never
            // search for or cache a randomized bootstrap name from another boot.
            Dl_info image={0};
            if (!dladdr(&intentToken,&image) || !image.dli_fname) { Status(0,UCNStatusABIRejected); return; }
            NSString *backendPath=[[@(image.dli_fname) stringByDeletingLastPathComponent]
                stringByAppendingPathComponent:@".jbroot/usr/lib/libsubstrate.dylib"];
            path=backendPath.fileSystemRepresentation;
#endif
            void *backend=dlopen(path,RTLD_NOW|RTLD_LOCAL);
            if (backend) hook=(HookMessage)dlsym(backend,"MSHookMessageEx");
        }
        if (!hook) { Status(0,UCNStatusABIRejected); return; }
        hook(cls,sel_registerName("viewDidAppear:"),(IMP)Appeared,(IMP *)&originalAppeared);
        hook(cls,sel_registerName("_handleUserChangedToNightMode:"),(IMP)Changed,(IMP *)&originalChanged);
        hook(cls,sel_registerName("_lowLightModeForMode:captureMode:device:isBurst:"),(IMP)Resolved,(IMP *)&originalResolve);
        if (!originalAppeared || !originalChanged || !originalResolve) { Status(0,UCNStatusABIRejected); return; }
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),NULL,IntentChanged,CFSTR(UCN_CHANGED_NAME),NULL,CFNotificationSuspensionBehaviorDeliverImmediately);
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationWillResignActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *notification) {
            (void)notification; if (appliedRequest) Disarm(YES);
        }];
        Status(0,UCNStatusReady);
    }
}
