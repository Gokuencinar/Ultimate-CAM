#ifndef ULTIMATE_CAM_NATIVE_NIGHT_PROTOCOL_H
#define ULTIMATE_CAM_NATIVE_NIGHT_PROTOCOL_H
#include <stdbool.h>
#include <stdint.h>

#define UCN_INTENT_NAME "com.gokuencinar.ultimatecam.native-night.intent"
#define UCN_STATUS_NAME "com.gokuencinar.ultimatecam.native-night.status"
#define UCN_ACK_NAME "com.gokuencinar.ultimatecam.native-night.ack"
#define UCN_CHANGED_NAME "com.gokuencinar.ultimatecam.native-night.changed"
#define UCN_MAX_TTL 180

// These are our protocol values, not Apple's private low-light enum values.
enum UCNIntent { UCNIntentNone = 0, UCNIntentMaximum = 1 };
enum UCNStatus { UCNStatusUnloaded = 0, UCNStatusReady = 1, UCNStatusUnsupported = 2,
    UCNStatusABIRejected = 3, UCNStatusControlApplied = 4, UCNStatusRequestConfigured = 5,
    UCNStatusIdle = 6, UCNStatusConflict = 7 };

static inline uint64_t UCNMakeIntent(uint64_t now, unsigned ttl, uint8_t nonce) {
    if (!now || !ttl || ttl > UCN_MAX_TTL || now > ((UINT64_MAX >> 16) - ttl)) return 0;
    return ((now + ttl) << 16) | ((uint64_t)nonce << 8) | 0x10 | UCNIntentMaximum;
}
static inline bool UCNIntentValid(uint64_t request, uint64_t now) {
    if ((request & 0xff) != (0x10 | UCNIntentMaximum) || !now) return false;
    const uint64_t deadline = request >> 16;
    return deadline > now && deadline - now <= UCN_MAX_TTL;
}
#endif
