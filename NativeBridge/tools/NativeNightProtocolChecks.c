#include "../UCNativeNightProtocol.h"
#include "../UCNotifyTokens.h"
#include <assert.h>
#include <stdio.h>
static int failAt,registered,cancelled;
static uint32_t fakeRegister(const char *name,int *token) {
    assert(strcmp(name,UCNTokenNames[registered])==0);
    if (registered==failAt) { *token=9999;return 123; }
    *token=registered++;return 0; // Token zero is valid and must be cancelled.
}
static uint32_t fakeCancel(int token) {
    assert(token>=0 && token<registered);++cancelled;return 0;
}
int main(void) {
    const uint64_t now = 1792850000;
    uint64_t request = UCNMakeIntent(now,120,34);
    assert(request && UCNIntentValid(request,now));
    assert(UCNIntentValid(request,now+119));
    assert(!UCNIntentValid(request,now+120));
    assert(!UCNIntentValid(request,now-61));
    assert(!UCNIntentValid(request ^ 0x20,now));
    assert(!UCNIntentValid(request ^ 0x01,now));
    assert(!UCNIntentValid(0,now));
    assert(!UCNMakeIntent(now,181,1));
    assert(!UCNMakeIntent(UINT64_MAX,120,1));
    assert(UCNMakeIntent(now,120,34) != UCNMakeIntent(now,120,35));
    for (failAt=0;failAt<=UCN_TOKEN_COUNT;++failAt) {
        UCNNotifyTokens tokens=UCN_TOKEN_INITIALIZER;size_t failed=999;
        registered=cancelled=0;
        uint32_t status=UCNRegisterTokens(&tokens,fakeRegister,fakeCancel,&failed);
        assert(registered==failAt);
        if (failAt<UCN_TOKEN_COUNT) {
            assert(status==123 && failed==(size_t)failAt && cancelled==failAt);
            for (size_t i=0;i<UCN_TOKEN_COUNT;++i) assert(tokens.values[i]==-1);
        } else { assert(status==0);UCNCancelTokens(&tokens,fakeCancel);assert(cancelled==UCN_TOKEN_COUNT); }
        UCNCancelTokens(&tokens,fakeCancel);assert(cancelled==registered);
    }
    assert(UCNTargetPolicy("iPhone12,3","22H31",true)==UCNStatusReady);
    assert(UCNTargetPolicy("iPhone12,3","22H31",false)==UCNStatusABIRejected);
    assert(UCNTargetPolicy("iPhone12,3","22H32",true)==UCNStatusBuildRejected);
    assert(UCNTargetPolicy("iPhone12,3","22H32",false)==UCNStatusBuildRejected);
    assert(UCNTargetPolicy("iPhone12,1","22H31",true)==UCNStatusUnsupported);
    puts("NATIVE NIGHT PROTOCOL CHECKS PASSED; no camera operations");
    return 0;
}
