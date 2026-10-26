#ifndef ULTIMATE_CAM_NATIVE_NIGHT_PROTOCOL_H
#define ULTIMATE_CAM_NATIVE_NIGHT_PROTOCOL_H
#include <stdbool.h>
#include <stdint.h>
#include <string.h>

#define UCN_INTENT_NAME "com.gokuencinar.ultimatecam.native-night.intent"
#define UCN_STATUS_NAME "com.gokuencinar.ultimatecam.native-night.status"
#define UCN_ACK_NAME "com.gokuencinar.ultimatecam.native-night.ack"
#define UCN_CHANGED_NAME "com.gokuencinar.ultimatecam.native-night.changed"
#define UCN_CONTROL_NAME "com.gokuencinar.ultimatecam.native-night.control"
#define UCN_RESOLVED_NAME "com.gokuencinar.ultimatecam.native-night.resolved"
#define UCN_CONFIRMED_NAME "com.gokuencinar.ultimatecam.native-night.confirmed"
#define UCN_PREVIOUS_NAME "com.gokuencinar.ultimatecam.native-night.previous"
#define UCN_MAX_TTL 180

// These are our protocol values, not Apple's private low-light enum values.
enum UCNIntent { UCNIntentNone = 0, UCNIntentMaximum = 1 };
enum UCNStatus { UCNStatusUnloaded = 0, UCNStatusReady = 1, UCNStatusUnsupported = 2,
    UCNStatusABIRejected = 3, UCNStatusControlApplied = 4, UCNStatusRequestConfigured = 5,
    UCNStatusIdle = 6, UCNStatusConflict = 7, UCNStatusBuildRejected = 8 };

#define UCN_TESTED_MODEL "iPhone12,3"
#define UCN_TESTED_BUILD "22H31"
static inline enum UCNStatus UCNTargetPolicy(const char *model,const char *build,bool abiMatches) {
    if (!model || !build || strcmp(model,UCN_TESTED_MODEL)!=0) return UCNStatusUnsupported;
    // An identical ABI does not prove unchanged enum semantics or ISP behavior.
    if (strcmp(build,UCN_TESTED_BUILD)!=0) return UCNStatusBuildRejected;
    return abiMatches ? UCNStatusReady:UCNStatusABIRejected;
}
static inline const char *UCNStatusName(uint64_t status) {
    switch (status) {
        case UCNStatusUnloaded:return "unloaded";
        case UCNStatusReady:return "ready";
        case UCNStatusUnsupported:return "unsupported-model-or-unreadable-target";
        case UCNStatusABIRejected:return "abi-or-hook-backend-rejected";
        case UCNStatusControlApplied:return "control-applied";
        case UCNStatusRequestConfigured:return "request-configured";
        case UCNStatusIdle:return "idle";
        case UCNStatusConflict:return "native-conflict";
        case UCNStatusBuildRejected:return "unreviewed-ios-build";
        default:return "unknown-status";
    }
}

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
