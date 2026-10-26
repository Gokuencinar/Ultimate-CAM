#import <Foundation/Foundation.h>
#import <notify.h>
#import <sys/sysctl.h>
#import <time.h>
#import "../UCNativeNightProtocol.h"
#import "../UCNotifyTokens.h"
int main(int argc,char **argv) {
    @autoreleasepool {
        UCNNotifyTokens tokens=UCN_TOKEN_INITIALIZER;size_t failed=0;
        uint32_t registration=UCNRegisterTokens(&tokens,notify_register_check,notify_cancel,&failed);
        if (registration!=NOTIFY_STATUS_OK) { fprintf(stderr,"notify registration failed: %s code=%u\n",UCNTokenNames[failed],registration);return 2; }
        @try {
        int intent=tokens.values[0],status=tokens.values[1],ack=tokens.values[2],control=tokens.values[3],resolved=tokens.values[4],confirmed=tokens.values[5],previous=tokens.values[6];
        uint64_t now=(uint64_t)time(NULL);
        NSString *action=argc>1 ? @(argv[1]) : @"status";
        if ([action isEqualToString:@"arm-max"]) {
            uint64_t request=UCNMakeIntent(now,120,(uint8_t)arc4random_uniform(256));
            if (notify_set_state(intent,request)!=NOTIFY_STATUS_OK || notify_post(UCN_CHANGED_NAME)!=NOTIFY_STATUS_OK) return 3;
        } else if ([action isEqualToString:@"disarm"]) {
            if (notify_set_state(intent,0)!=NOTIFY_STATUS_OK || notify_post(UCN_CHANGED_NAME)!=NOTIFY_STATUS_OK) return 3;
        } else if (![action isEqualToString:@"status"]) { fprintf(stderr,"Use status, arm-max or disarm. This tool never launches Camera or captures photos.\n"); return 1; }
        uint64_t request=0,code=0,acknowledgement=0,nativeControl=0,nativeResolved=0,confirmedRequest=0,previousControl=0;
        notify_get_state(intent,&request); notify_get_state(status,&code); notify_get_state(ack,&acknowledgement);
        notify_get_state(control,&nativeControl);notify_get_state(resolved,&nativeResolved);
        notify_get_state(confirmed,&confirmedRequest);notify_get_state(previous,&previousControl);
        char model[64]={0},build[64]={0};size_t modelSize=sizeof(model),buildSize=sizeof(build);
        (void)sysctlbyname("hw.machine",model,&modelSize,NULL,0);(void)sysctlbyname("kern.osversion",build,&buildSize,NULL,0);
        model[sizeof(model)-1]=0;build[sizeof(build)-1]=0;
        NSData *data=[NSJSONSerialization dataWithJSONObject:@{@"request":@(request),@"armed":@(UCNIntentValid(request,now)),@"status":@(code),@"status_reason":@(UCNStatusName(code)),@"target_model":@(model),@"target_build":@(build),@"expected_build":@(UCN_TESTED_BUILD),@"ack":@(acknowledgement),@"native_control":@(nativeControl),@"native_resolved":@(nativeResolved),@"confirmed_request":@(confirmedRequest),@"previous_control":@(previousControl),@"capture_requests":@0} options:NSJSONWritingSortedKeys error:NULL];
        fwrite(data.bytes,1,data.length,stdout); fputc('\n',stdout);
        } @finally { UCNCancelTokens(&tokens,notify_cancel); }
    }
    return 0;
}
