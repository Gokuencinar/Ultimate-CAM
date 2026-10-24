#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>

// Scoped launch diagnostics. No unlock option, capture call or private camera
// selector. Unlike uiopen, report the actual LaunchServices result and error.
int main(int argc,char **argv) {
    @autoreleasepool {
        dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices",RTLD_LAZY|RTLD_LOCAL);
        dlopen("/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices",RTLD_LAZY|RTLD_LOCAL);
        Class cls=objc_lookUpClass("LSApplicationWorkspace");
        SEL factory=sel_registerName("defaultWorkspace"),open=sel_registerName("openSensitiveURL:withOptions:error:");
        Method fm=cls ? class_getClassMethod(cls,factory) : NULL,om=cls ? class_getInstanceMethod(cls,open) : NULL;
        NSString *factoryType=fm ? @(method_getTypeEncoding(fm)) : @"";
        NSString *openType=om ? @(method_getTypeEncoding(om)) : @"";
        NSMutableDictionary *report=[@{@"workspace_class":@(cls!=Nil),@"factory_encoding":factoryType,@"open_encoding":openType,@"capture_requests":@0,@"unlock_requested":@NO,@"launch_requested":@NO} mutableCopy];
        if (argc>1 && strcmp(argv[1],"--launch")==0) {
            report[@"launch_requested"]=@YES;
            if ([factoryType isEqual:@"@16@0:8"] && [openType isEqual:@"B40@0:8@16@24^@32"]) {
                id workspace=((id(*)(id,SEL))objc_msgSend)(cls,factory);
                NSError *error=nil;
                BOOL result=((BOOL(*)(id,SEL,id,id,NSError *__autoreleasing *))objc_msgSend)(workspace,open,[NSURL URLWithString:@"camera://"],@{},&error);
                report[@"accepted"]=@(result);
                report[@"error"]=error ? @{@"domain":error.domain,@"code":@(error.code),@"description":error.localizedDescription,@"details":error.description} : @{};
                NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:2];
                while ([deadline timeIntervalSinceNow]>0) [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
            } else report[@"error"]=@"Runtime ABI mismatch; no launch method invoked";
        }
        NSData *json=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingSortedKeys error:NULL];
        fwrite(json.bytes,1,json.length,stdout);fputc('\n',stdout);
    }
    return 0;
}
