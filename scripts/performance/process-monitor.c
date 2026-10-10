// macOS-only, external sampler. No monitor code is linked into ActionImport.
// CPU counters and wall clock share Mach absolute-time units; 100% is one core.
#include <errno.h>
#include <inttypes.h>
#include <limits.h>
#include <libproc.h>
#include <mach/mach_time.h>
#include <math.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <time.h>

static volatile sig_atomic_t interrupted = 0;
static void stop_sampling(int signal_number) { (void)signal_number; interrupted = 1; }

static bool number(const char *text, double minimum, double maximum, double *value) {
    char *end = NULL;
    errno = 0;
    *value = strtod(text, &end);
    return !errno && end != text && *end == '\0' && isfinite(*value)
        && *value >= minimum && *value <= maximum;
}

static int read_usage(int pid, struct rusage_info_v4 *usage) {
    memset(usage, 0, sizeof(*usage));
    return proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t *)usage);
}

static long double cpu_ticks(const struct rusage_info_v4 *usage) {
    return (long double)usage->ri_user_time + (long double)usage->ri_system_time;
}

static double seconds(uint64_t ticks, mach_timebase_info_data_t timebase) {
    return (double)((long double)ticks * timebase.numer / timebase.denom / 1e9L);
}

static int write_row(FILE *csv, double elapsed, bool has_cpu, double cpu,
                     const struct rusage_info_v4 *usage) {
    if (fprintf(csv, "%.6f,", elapsed) < 0) return -1;
    if (has_cpu && fprintf(csv, "%.6f", cpu) < 0) return -1;
    if (fprintf(csv, ",%" PRIu64 ",%" PRIu64 ",%" PRIu64 ",%" PRIu64 ",%" PRIu64 ",%" PRIu64 ",%" PRIu64 "\n",
        usage->ri_resident_size, usage->ri_phys_footprint,
        usage->ri_lifetime_max_phys_footprint, usage->ri_interrupt_wkups,
        usage->ri_pkg_idle_wkups, usage->ri_diskio_bytesread,
        usage->ri_diskio_byteswritten) < 0) return -1;
    return fflush(csv);
}

int main(int argc, char **argv) {
    double pid_number, duration, interval;
    if (argc != 5 || !number(argv[1], 1, INT_MAX, &pid_number)
        || floor(pid_number) != pid_number || !number(argv[2], 0.1, 3600, &duration)
        || !number(argv[3], 0.05, 10, &interval)) {
        fprintf(stderr, "Usage: process-monitor PID SECONDS INTERVAL CSV_PATH\n");
        return 2;
    }
    const int pid = (int)pid_number;
    struct rusage_info_v4 first, previous, current;
    if (read_usage(pid, &first) != 0) { perror("proc_pid_rusage"); return 1; }
    if (first.ri_proc_exit_abstime) {
        fprintf(stderr, "Process already exited before sampling; CPU interval unavailable\n");
        return 1;
    }
    mach_timebase_info_data_t timebase;
    if (mach_timebase_info(&timebase) != KERN_SUCCESS || !timebase.denom) {
        fprintf(stderr, "Cannot read Mach timebase\n"); return 1;
    }
    FILE *csv = fopen(argv[4], "wx"); // Never replace a previous result.
    if (!csv) { perror("CSV output"); return 1; }
    signal(SIGINT, stop_sampling);
    signal(SIGTERM, stop_sampling);
    if (fprintf(csv, "elapsed_s,cpu_percent,rss_bytes,footprint_bytes,lifetime_peak_bytes,interrupt_wakeups,pkg_idle_wakeups,read_bytes,write_bytes\n") < 0
        || write_row(csv, 0, false, 0, &first) != 0) {
        perror("CSV write"); fclose(csv); return 1;
    }
    uint64_t start = mach_absolute_time(), previous_time = start, last_time = start;
    previous = first;
    current = first;
    struct rusage_info_v4 last_live = first;
    uint64_t rss_min = first.ri_resident_size, rss_max = rss_min;
    uint64_t footprint_min = first.ri_phys_footprint, footprint_max = footprint_min;
    double peak_cpu = 0;
    size_t samples = 1;
    const char *reason = "duration";
    int status = 0;
    while (!interrupted) {
        double remaining = duration - seconds(mach_absolute_time() - start, timebase);
        if (remaining <= 0) break;
        double delay = fmin(interval, remaining);
        struct timespec sleep_time = {(time_t)delay, (long)((delay - floor(delay)) * 1e9)};
        while (nanosleep(&sleep_time, &sleep_time) != 0) {
            if (errno != EINTR) { perror("nanosleep"); status = 1; break; }
            if (interrupted) break;
        }
        if (status || interrupted) break;
        struct rusage_info_v4 next;
        if (read_usage(pid, &next) != 0) {
            if (errno == ESRCH) { reason = "process_exited"; break; }
            perror("proc_pid_rusage"); reason = "read_failed"; status = 1; break;
        }
        if (next.ri_proc_start_abstime != first.ri_proc_start_abstime) {
            reason = "pid_reused"; status = 1; break;
        }
        last_time = mach_absolute_time();
        uint64_t wall_ticks = last_time - previous_time;
        long double cpu_delta = cpu_ticks(&next) - cpu_ticks(&previous);
        if (cpu_delta < 0 || !wall_ticks) {
            reason = "invalid_counters"; status = 1; break;
        }
        double cpu = (double)(cpu_delta / wall_ticks * 100.0L);
        if (write_row(csv, seconds(last_time - start, timebase), true, cpu, &next) != 0) {
            perror("CSV write"); reason = "write_failed"; status = 1; break;
        }
        current = next;
        if (cpu > peak_cpu) peak_cpu = cpu;
        // macOS returns final CPU counters with zero memory after exit. Do not count
        // that as a live-memory sample or claim that it proves post-import recovery.
        if (!current.ri_proc_exit_abstime) {
            last_live = current;
            if (current.ri_resident_size < rss_min) rss_min = current.ri_resident_size;
            if (current.ri_resident_size > rss_max) rss_max = current.ri_resident_size;
            if (current.ri_phys_footprint < footprint_min) footprint_min = current.ri_phys_footprint;
            if (current.ri_phys_footprint > footprint_max) footprint_max = current.ri_phys_footprint;
        }
        samples++;
        previous = current;
        previous_time = last_time;
        if (current.ri_proc_exit_abstime) { reason = "process_exited"; break; }
    }
    if (interrupted) reason = "interrupted";
    if (fclose(csv) != 0) { perror("CSV close"); reason = "write_failed"; status = 1; }
    double elapsed = seconds(last_time - start, timebase);
    long double wall_ticks = last_time - start;
    double average_cpu = wall_ticks > 0 ? (double)((cpu_ticks(&current) - cpu_ticks(&first)) / wall_ticks * 100.0L) : 0;
    double cpu_seconds = (double)((cpu_ticks(&current) - cpu_ticks(&first)) * timebase.numer / timebase.denom / 1e9L);
    if (printf("{\"pid\":%d,\"samples\":%zu,\"sample_interval_s\":%.3f,\"observed_s\":%.6f,\"stop_reason\":\"%s\",\"cpu_avg_percent\":%.6f,\"cpu_peak_interval_percent\":%.6f,\"cpu_observed_s\":%.6f,\"rss_min_bytes\":%" PRIu64 ",\"rss_peak_bytes\":%" PRIu64 ",\"rss_last_bytes\":%" PRIu64 ",\"footprint_min_bytes\":%" PRIu64 ",\"footprint_peak_sampled_bytes\":%" PRIu64 ",\"footprint_last_bytes\":%" PRIu64 ",\"lifetime_peak_footprint_bytes\":%" PRIu64 ",\"interrupt_wakeups_per_s\":%.6f,\"pkg_idle_wakeups_per_s\":%.6f,\"timebase_numer\":%u,\"timebase_denom\":%u}\n",
        pid, samples, interval, elapsed, reason, average_cpu, peak_cpu, cpu_seconds,
        rss_min, rss_max, last_live.ri_resident_size, footprint_min, footprint_max,
        last_live.ri_phys_footprint, current.ri_lifetime_max_phys_footprint,
        elapsed > 0 ? (current.ri_interrupt_wkups - first.ri_interrupt_wkups) / elapsed : 0,
        elapsed > 0 ? (current.ri_pkg_idle_wkups - first.ri_pkg_idle_wkups) / elapsed : 0,
        timebase.numer, timebase.denom) < 0 || fflush(stdout) != 0) {
        perror("JSON write"); return 1;
    }
    return status;
}
