#import "UCNativePhotoNight.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <sys/sysctl.h>
#import <TargetConditionals.h>

static BOOL ABI(id object,const char *selector,const char *type) {
    Method method=class_getInstanceMethod(object_getClass(object),sel_registerName(selector));
    const char *actual=method ? method_getTypeEncoding(method):NULL;
    return actual && strcmp(actual,type)==0;
}
static NSString *TargetIssue(void) {
#if TARGET_OS_SIMULATOR
    return @"Noche de iOS necesita un iPhone compatible.";
#else
    char model[64]={0},build[64]={0};size_t m=sizeof(model),b=sizeof(build);
    if (sysctlbyname("hw.machine",model,&m,NULL,0) || sysctlbyname("kern.osversion",build,&b,NULL,0) ||
        strcmp(model,"iPhone12,3") || strcmp(build,"22H31"))
        return @"Noche de iOS no está habilitada para este dispositivo o versión.";
    return nil;
#endif
}
static NSArray<NSNumber *> *Modes(AVCapturePhotoOutput *output) {
    if (!ABI(output,"supportedDigitalFlashModes","@16@0:8")) return @[];
    id value=((id(*)(id,SEL))objc_msgSend)(output,sel_registerName("supportedDigitalFlashModes"));
    if (![value isKindOfClass:NSArray.class]) return @[];
    for (id item in value) if (![item isKindOfClass:NSNumber.class]) return @[];
    return value;
}
@implementation UCNativePhotoNight
+ (NSString *)availabilityIssue:(AVCapturePhotoOutput *)output {
    NSString *issue=TargetIssue();if (issue) return issue;
    @try {
        if (!ABI(output,"setDigitalFlashCaptureEnabled:","v20@0:8B16") ||
            !ABI(output,"isDigitalFlashCaptureEnabled","B16@0:8")) return @"La salida de cámara no admite Noche de iOS.";
        NSArray *modes=Modes(output);
        if (![modes containsObject:@1] && ![modes containsObject:@2]) return @"Noche de iOS no está disponible en esta lente o formato.";
        return nil;
    } @catch (NSException *e) { (void)e;return @"No se pudieron leer las capacidades nocturnas de iOS."; }
}
+ (NSNumber *)outputEnabled:(AVCapturePhotoOutput *)output {
    if (TargetIssue() || !ABI(output,"isDigitalFlashCaptureEnabled","B16@0:8")) return nil;
    @try { return @(((BOOL(*)(id,SEL))objc_msgSend)(output,sel_registerName("isDigitalFlashCaptureEnabled"))); }
    @catch (NSException *e) { (void)e;return nil; }
}
+ (NSString *)restoreOutput:(AVCapturePhotoOutput *)output enabled:(BOOL)enabled {
    if (TargetIssue() || !ABI(output,"setDigitalFlashCaptureEnabled:","v20@0:8B16")) return @"No se pudo restaurar la salida fotográfica.";
    @try {
        ((void(*)(id,SEL,BOOL))objc_msgSend)(output,sel_registerName("setDigitalFlashCaptureEnabled:"),enabled);
        return [self outputEnabled:output].boolValue==enabled ? nil:@"iOS no confirmó la salida fotográfica.";
    } @catch (NSException *e) { NSLog(@"UltimateCAM native Night output %@: %@",e.name,e.reason);return @"iOS rechazó la configuración nocturna de esta sesión."; }
}
+ (NSString *)configureOutput:(AVCapturePhotoOutput *)output {
    NSString *issue=[self availabilityIssue:output];if (issue) return issue;
    return [self restoreOutput:output enabled:YES];
}
+ (NSNumber *)toneMapping:(AVCaptureDevice *)device {
    if (TargetIssue() || !ABI(device,"isGlobalToneMappingEnabled","B16@0:8")) return nil;
    @try { return @(((BOOL(*)(id,SEL))objc_msgSend)(device,sel_registerName("isGlobalToneMappingEnabled"))); }
    @catch (NSException *e) { (void)e;return nil; }
}
+ (NSString *)restoreToneMapping:(BOOL)enabled device:(AVCaptureDevice *)device {
    if (TargetIssue() || !ABI(device,"setGlobalToneMappingEnabled:","v20@0:8B16")) return @"No se pudo restaurar el tono del visor.";
    if ([self toneMapping:device].boolValue==enabled) return nil;
    NSError *error=nil;
    if (![device lockForConfiguration:&error]) return @"No se pudo restaurar el tono del visor.";
    @try {
        ((void(*)(id,SEL,BOOL))objc_msgSend)(device,sel_registerName("setGlobalToneMappingEnabled:"),enabled);
        return [self toneMapping:device].boolValue==enabled ? nil:@"iOS no confirmó la restauración del tono.";
    } @catch (NSException *e) {
        NSLog(@"UltimateCAM native Night restore tone %@: %@",e.name,e.reason);
        return @"iOS rechazó la restauración del tono del visor.";
    } @finally { [device unlockForConfiguration]; }
}
+ (NSNumber *)previewMode:(AVCaptureDevice *)device {
    if (TargetIssue() || !ABI(device,"digitalFlashMode","q16@0:8")) return nil;
    @try { return @(((NSInteger(*)(id,SEL))objc_msgSend)(device,sel_registerName("digitalFlashMode"))); }
    @catch (NSException *e) { (void)e;return nil; }
}
+ (NSString *)setPreviewMode:(NSInteger)mode device:(AVCaptureDevice *)device {
    NSString *issue=TargetIssue();if (issue) return issue;
    if (mode<0 || mode>2 || !ABI(device,"setDigitalFlashMode:","v24@0:8q16") ||
        !ABI(device,"digitalFlashMode","q16@0:8")) return @"El control nocturno no es compatible con esta lente.";
    NSError *error=nil;
    if (![device lockForConfiguration:&error]) return @"No se pudo preparar la cámara para Noche de iOS.";
    @try {
        ((void(*)(id,SEL,NSInteger))objc_msgSend)(device,sel_registerName("setDigitalFlashMode:"),mode);
        NSInteger actual=((NSInteger(*)(id,SEL))objc_msgSend)(device,sel_registerName("digitalFlashMode"));
        return actual==mode ? nil:@"iOS no confirmó el modo nocturno solicitado.";
    } @catch (NSException *e) {
        NSLog(@"UltimateCAM native Night preview %@: %@",e.name,e.reason);
        return @"iOS rechazó el modo nocturno de esta lente.";
    } @finally { [device unlockForConfiguration]; }
}
+ (NSString *)applySettings:(AVCapturePhotoSettings *)settings output:(AVCapturePhotoOutput *)output mode:(NSInteger)mode {
    NSString *issue=TargetIssue();if (issue) return issue;
    @try {
        if (mode<1 || mode>2 || ![Modes(output) containsObject:@(mode)] ||
            !ABI(output,"isDigitalFlashCaptureEnabled","B16@0:8") ||
            !((BOOL(*)(id,SEL))objc_msgSend)(output,sel_registerName("isDigitalFlashCaptureEnabled"))) return @"Noche de iOS no está preparada en esta sesión.";
        if (!ABI(settings,"setDigitalFlashMode:","v24@0:8q16") || !ABI(settings,"digitalFlashMode","q16@0:8")) return @"La solicitud nocturna no es compatible con este iOS.";
        // CameraUI's captureDigitalFlashModeForLowLightMode: maps 1->1, 2->2
        // on 22H31. Never invent capabilities or force an unsupported format.
        ((void(*)(id,SEL,NSInteger))objc_msgSend)(settings,sel_registerName("setDigitalFlashMode:"),mode);
        NSInteger actual=((NSInteger(*)(id,SEL))objc_msgSend)(settings,sel_registerName("digitalFlashMode"));
        return actual==mode ? nil:@"No se pudo configurar la solicitud nocturna.";
    } @catch (NSException *e) {
        NSLog(@"UltimateCAM native Night settings %@: %@",e.name,e.reason);
        return @"iOS rechazó la solicitud nocturna. No se ha repetido la captura.";
    }
}
+ (NSDictionary *)resolvedInfo:(AVCaptureResolvedPhotoSettings *)settings {
    if (TargetIssue() || !ABI(settings,"digitalFlashUserInterfaceHints","Q16@0:8")) return @{};
    @try {
        NSUInteger hints=((NSUInteger(*)(id,SEL))objc_msgSend)(settings,sel_registerName("digitalFlashUserInterfaceHints"));
        return @{@"digitalFlashHints":@(hints)};
    } @catch (NSException *e) { (void)e;return @{}; }
}
@end
