#import <Foundation/Foundation.h>
#import <notify.h>
#import <time.h>
#import "../UCNativeNightProtocol.h"
int main(int argc,char **argv) {
    @autoreleasepool {
        int intent=0,status=0,ack=0,control=0,resolved=0,confirmed=0,previous=0;
        if (notify_register_check(UCN_INTENT_NAME,&intent)!=NOTIFY_STATUS_OK || notify_register_check(UCN_STATUS_NAME,&status)!=NOTIFY_STATUS_OK || notify_register_check(UCN_ACK_NAME,&ack)!=NOTIFY_STATUS_OK || notify_register_check(UCN_CONTROL_NAME,&control)!=NOTIFY_STATUS_OK || notify_register_check(UCN_RESOLVED_NAME,&resolved)!=NOTIFY_STATUS_OK || notify_register_check(UCN_CONFIRMED_NAME,&confirmed)!=NOTIFY_STATUS_OK || notify_register_check(UCN_PREVIOUS_NAME,&previous)!=NOTIFY_STATUS_OK) return 2;
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
        NSData *data=[NSJSONSerialization dataWithJSONObject:@{@"request":@(request),@"armed":@(UCNIntentValid(request,now)),@"status":@(code),@"ack":@(acknowledgement),@"native_control":@(nativeControl),@"native_resolved":@(nativeResolved),@"confirmed_request":@(confirmedRequest),@"previous_control":@(previousControl),@"capture_requests":@0} options:NSJSONWritingSortedKeys error:NULL];
        fwrite(data.bytes,1,data.length,stdout); fputc('\n',stdout);
        notify_cancel(intent);notify_cancel(status);notify_cancel(ack);notify_cancel(control);notify_cancel(resolved);notify_cancel(confirmed);notify_cancel(previous);
    }
    return 0;
}
