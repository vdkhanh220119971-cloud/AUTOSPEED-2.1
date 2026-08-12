#import <Foundation/Foundation.h>
#import <mach/mach_time.h>
#import <time.h>
#import <os/lock.h>
#import "fishhook.h"

// ==========================================
// SPEEDHACK ENGINE (MONOTONIC FRAME SCALING)
// ==========================================

static float speed_factor = 1.0f;
static os_unfair_lock speed_lock = OS_UNFAIR_LOCK_INIT;

// Original Function Pointers
static uint64_t (*orig_mach_absolute_time)(void);
static int (*orig_clock_gettime)(clockid_t clk_id, struct timespec *tp);

// Incremental Trackers cho Frame Loop
static uint64_t last_real_mach = 0;
static uint64_t fake_mach = 0;

static struct timespec last_real_ts = {0, 0};
static struct timespec fake_ts = {0, 0};

#ifdef __cplusplus
extern "C" {
#endif

void set_speed_factor(float factor) {
    os_unfair_lock_lock(&speed_lock);
    speed_factor = factor;
    os_unfair_lock_unlock(&speed_lock);
}

float get_speed_factor(void) {
    os_unfair_lock_lock(&speed_lock);
    float factor = speed_factor;
    os_unfair_lock_unlock(&speed_lock);
    return factor;
}

#ifdef __cplusplus
}
#endif

// Hook 1: mach_absolute_time (Quản lý render frame và animation)
uint64_t my_mach_absolute_time(void) {
    uint64_t real_now = orig_mach_absolute_time();

    os_unfair_lock_lock(&speed_lock);
    if (last_real_mach == 0) {
        last_real_mach = real_now;
        fake_mach = real_now;
        os_unfair_lock_unlock(&speed_lock);
        return real_now;
    }

    if (real_now > last_real_mach) {
        uint64_t delta = real_now - last_real_mach;
        fake_mach += (uint64_t)(delta * speed_factor);
        last_real_mach = real_now;
    }
    uint64_t result = fake_mach;
    os_unfair_lock_unlock(&speed_lock);

    return result;
}

// Hook 2: clock_gettime (Chỉ can thiệp clock đơn điệu MONOTONIC)
int my_clock_gettime(clockid_t clk_id, struct timespec *tp) {
    int ret = orig_clock_gettime(clk_id, tp);
    if (ret != 0 || tp == NULL) return ret;

    // Chỉ can thiệp bộ đếm thời gian trôi (MONOTONIC), KHÔNG đụng vào đồng hồ thực (REALTIME)
    if (clk_id == CLOCK_MONOTONIC || clk_id == CLOCK_MONOTONIC_RAW || clk_id == CLOCK_UPTIME_RAW) {
        os_unfair_lock_lock(&speed_lock);
        if (last_real_ts.tv_sec == 0) {
            last_real_ts = *tp;
            fake_ts = *tp;
            os_unfair_lock_unlock(&speed_lock);
            return ret;
        }

        double delta = (tp->tv_sec - last_real_ts.tv_sec) + 
                       (tp->tv_nsec - last_real_ts.tv_nsec) / 1e9;
        if (delta > 0) {
            double fake_delta = delta * speed_factor;
            long sec_add = (long)fake_delta;
            long nsec_add = (long)((fake_delta - sec_add) * 1e9);

            fake_ts.tv_sec += sec_add;
            fake_ts.tv_nsec += nsec_add;
            if (fake_ts.tv_nsec >= 1000000000) {
                fake_ts.tv_sec += 1;
                fake_ts.tv_nsec -= 1000000000;
            }
            last_real_ts = *tp;
        }
        *tp = fake_ts;
        os_unfair_lock_unlock(&speed_lock);
    }

    return ret;
}

__attribute__((constructor))
static void initialize(void) {
    struct rebinding rebindings[] = {
        {"mach_absolute_time", (void *)my_mach_absolute_time, (void **)&orig_mach_absolute_time},
        {"clock_gettime", (void *)my_clock_gettime, (void **)&orig_clock_gettime}
    };
    rebind_symbols(rebindings, 2);
}
