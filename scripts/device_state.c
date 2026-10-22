#include <notify.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <sys/sysctl.h>

static uint64_t diagnostic_value(const char *suffix) {
    char name[192];
    snprintf(name, sizeof(name), "com.gokuencinar.ultimatecam.diagnostic.%s", suffix);
    int token = 0;
    uint64_t value = 0;
    if (notify_register_check(name, &token) == NOTIFY_STATUS_OK) {
        notify_get_state(token, &value);
        notify_cancel(token);
    }
    return value;
}

static void diagnostic_string(const char *suffix, size_t limit) {
    char key[128];
    snprintf(key, sizeof(key), "%s.length", suffix);
    size_t length = (size_t)diagnostic_value(key);
    if (length > limit) length = limit;
    printf("diagnostic_%s=", suffix);
    for (size_t offset = 0; offset < length; offset += 8) {
        snprintf(key, sizeof(key), "%s.%zu", suffix, offset / 8);
        uint64_t word = diagnostic_value(key);
        for (size_t i = 0; i < 8 && offset + i < length; i++) {
            unsigned char byte = (unsigned char)(word >> (8 * i));
            putchar(byte >= 32 ? byte : '?');
        }
    }
    putchar('\n');
}

/* Read-only SSH probe. Does not post notifications or change lock state. */
int main(void) {
    printf("diagnostic_pid=%llu\n", (unsigned long long)diagnostic_value("pid"));
    printf("diagnostic_build=%llu\n", (unsigned long long)diagnostic_value("build"));
    printf("diagnostic_writeError=%lld\n", (long long)diagnostic_value("writeError"));
    diagnostic_string("path", 768);
    diagnostic_string("event", 96);
    diagnostic_string("errorDomain", 96);
    const char *names[] = {
        "com.apple.springboard.lockstate",
        "com.apple.springboard.lockcomplete",
        "com.apple.iokit.hid.displayStatus"
    };
    for (size_t i = 0; i < sizeof(names) / sizeof(names[0]); i++) {
        int token = 0;
        uint64_t state = 0;
        uint32_t registration = notify_register_check(names[i], &token);
        uint32_t status = registration;
        if (registration == NOTIFY_STATUS_OK) {
            status = notify_get_state(token, &state);
            notify_cancel(token);
        }
        printf("%s status=%u raw_state=%llu\n", names[i], status, (unsigned long long)state);
    }
    int query[] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
    size_t bytes = 0;
    if (sysctl(query, 4, NULL, &bytes, NULL, 0) != 0) {
        printf("process_query_error=%d\n", errno);
        return 0;
    }
    bytes += 16 * sizeof(struct kinfo_proc);
    struct kinfo_proc *processes = malloc(bytes);
    if (!processes) return 1;
    if (sysctl(query, 4, processes, &bytes, NULL, 0) != 0) {
        printf("process_query_error=%d\n", errno);
        free(processes);
        return 0;
    }
    size_t matches = 0;
    for (size_t i = 0; i < bytes / sizeof(struct kinfo_proc); i++) {
        if (strcmp(processes[i].kp_proc.p_comm, "UltimateCAM") == 0) {
            printf("ultimatecam_pid=%d\n", processes[i].kp_proc.p_pid);
            matches++;
        }
    }
    printf("ultimatecam_processes=%zu\n", matches);
    free(processes);
    return 0;
}
