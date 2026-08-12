#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <mach/mach_time.h>
#import <time.h>
#import <os/lock.h>
#import "fishhook.h"

// ===================================================
// CẤU HÌNH BẬT / TẮT TỪNG HÀM (ĐÃ BẬT DUY NHẤT HOOK_CF_ABSOLUTE_TIME)
// ===================================================
#define HOOK_MACH_ABSOLUTE_TIME   0   // Tắt
#define HOOK_CF_ABSOLUTE_TIME     1   // BẬT (Tập trung hook CFAbsoluteTimeGetCurrent)
#define HOOK_CLOCK_GETTIME        0   // Tắt

static float speed_factor = 1.0f;
static os_unfair_lock speed_lock = OS_UNFAIR_LOCK_INIT;

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

// ---------------------------------------------------
// 1. HOOK MACH_ABSOLUTE_TIME
// ---------------------------------------------------
#if HOOK_MACH_ABSOLUTE_TIME
static uint64_t (*orig_mach_absolute_time)(void) = NULL;
static uint64_t last_real_mach = 0;
static uint64_t fake_mach = 0;

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
#endif

// ---------------------------------------------------
// 2. HOOK CFABSOLUTETIMEGETCURRENT (ĐANG BẬT)
// ---------------------------------------------------
#if HOOK_CF_ABSOLUTE_TIME
static CFAbsoluteTime (*orig_CFAbsoluteTimeGetCurrent)(void) = NULL;
static CFAbsoluteTime last_real_cf = 0;
static CFAbsoluteTime fake_cf = 0;

CFAbsoluteTime my_CFAbsoluteTimeGetCurrent(void) {
    CFAbsoluteTime real_now = orig_CFAbsoluteTimeGetCurrent();
    os_unfair_lock_lock(&speed_lock);
    if (last_real_cf == 0) {
        last_real_cf = real_now;
        fake_cf = real_now;
        os_unfair_lock_unlock(&speed_lock);
        return real_now;
    }
    if (real_now > last_real_cf) {
        double delta = real_now - last_real_cf;
        fake_cf += delta * speed_factor;
        last_real_cf = real_now;
    }
    CFAbsoluteTime result = fake_cf;
    os_unfair_lock_unlock(&speed_lock);
    return result;
}
#endif

// ---------------------------------------------------
// 3. HOOK CLOCK_GETTIME
// ---------------------------------------------------
#if HOOK_CLOCK_GETTIME
static int (*orig_clock_gettime)(clockid_t clk_id, struct timespec *tp) = NULL;
static struct timespec last_real_mono = {0, 0};
static struct timespec fake_mono = {0, 0};

int my_clock_gettime(clockid_t clk_id, struct timespec *tp) {
    int ret = orig_clock_gettime(clk_id, tp);
    if (ret != 0 || tp == NULL) return ret;

    if (clk_id == CLOCK_MONOTONIC || clk_id == CLOCK_MONOTONIC_RAW || clk_id == CLOCK_UPTIME_RAW) {
        os_unfair_lock_lock(&speed_lock);
        if (last_real_mono.tv_sec == 0) {
            last_real_mono = *tp;
            fake_mono = *tp;
            os_unfair_lock_unlock(&speed_lock);
            return ret;
        }
        double delta = (tp->tv_sec - last_real_mono.tv_sec) + 
                       (tp->tv_nsec - last_real_mono.tv_nsec) / 1e9;
        if (delta > 0) {
            double fake_delta = delta * speed_factor;
            long sec_add = (long)fake_delta;
            long nsec_add = (long)((fake_delta - sec_add) * 1e9);

            fake_mono.tv_sec += sec_add;
            fake_mono.tv_nsec += nsec_add;
            if (fake_mono.tv_nsec >= 1000000000) {
                fake_mono.tv_sec += 1;
                fake_mono.tv_nsec -= 1000000000;
            }
            last_real_mono = *tp;
        }
        *tp = fake_mono;
        os_unfair_lock_unlock(&speed_lock);
    }
    return ret;
}
#endif

// ---------------------------------------------------
// INITIALIZER
// ---------------------------------------------------
__attribute__((constructor))
static void initialize(void) {
    struct rebinding rebindings[3];
    int count = 0;

#if HOOK_MACH_ABSOLUTE_TIME
    rebindings[count++] = (struct rebinding){"mach_absolute_time", (void *)my_mach_absolute_time, (void **)&orig_mach_absolute_time};
#endif

#if HOOK_CF_ABSOLUTE_TIME
    rebindings[count++] = (struct rebinding){"CFAbsoluteTimeGetCurrent", (void *)my_CFAbsoluteTimeGetCurrent, (void **)&orig_CFAbsoluteTimeGetCurrent};
#endif

#if HOOK_CLOCK_GETTIME
    rebindings[count++] = (struct rebinding){"clock_gettime", (void *)my_clock_gettime, (void **)&orig_clock_gettime};
#endif

    if (count > 0) {
        rebind_symbols(rebindings, count);
    }
}
