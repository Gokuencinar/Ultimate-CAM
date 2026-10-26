#ifndef UC_NOTIFY_TOKENS_H
#define UC_NOTIFY_TOKENS_H
#include "UCNativeNightProtocol.h"
#include <stddef.h>

#define UCN_TOKEN_COUNT 7
#define UCN_TOKEN_INITIALIZER {{-1,-1,-1,-1,-1,-1,-1}}
typedef struct { int values[UCN_TOKEN_COUNT]; } UCNNotifyTokens;
typedef uint32_t (*UCNRegisterFunction)(const char *,int *);
typedef uint32_t (*UCNCancelFunction)(int);
static const char *const UCNTokenNames[UCN_TOKEN_COUNT]={UCN_INTENT_NAME,UCN_STATUS_NAME,UCN_ACK_NAME,
    UCN_CONTROL_NAME,UCN_RESOLVED_NAME,UCN_CONFIRMED_NAME,UCN_PREVIOUS_NAME};
static inline void UCNCancelTokens(UCNNotifyTokens *tokens,UCNCancelFunction cancel) {
    for (size_t i=UCN_TOKEN_COUNT;i>0;--i) {
        int *token=&tokens->values[i-1];
        if (*token>=0) { cancel(*token);*token=-1; }
    }
}
static inline uint32_t UCNRegisterTokens(UCNNotifyTokens *tokens,UCNRegisterFunction registration,
                                       UCNCancelFunction cancel,size_t *failedIndex) {
    for (size_t i=0;i<UCN_TOKEN_COUNT;++i) {
        int candidate=-1;
        uint32_t code=registration(UCNTokenNames[i],&candidate);
        if (code!=0) {
            if (failedIndex) *failedIndex=i;
            UCNCancelTokens(tokens,cancel);
            return code;
        }
        tokens->values[i]=candidate;
    }
    return 0;
}
#endif
