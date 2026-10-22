#include <notify.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <sys/sysctl.h>

/* Read-only SSH probe. Does not post notifications or change lock state. */
int main(void) {
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
