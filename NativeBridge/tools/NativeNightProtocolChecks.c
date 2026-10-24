#include "../UCNativeNightProtocol.h"
#include <assert.h>
#include <stdio.h>
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
    puts("NATIVE NIGHT PROTOCOL CHECKS PASSED; no camera operations");
    return 0;
}
