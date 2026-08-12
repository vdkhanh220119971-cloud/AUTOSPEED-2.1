#import <Foundation/Foundation.h>
#import <sys/time.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/runtime.h>
#import <mach/mach_time.h>
#import <os/lock.h>
#import "fishhook.h"

// ==========================================
// SPEEDHACK ENGINE (EXPORTED C-LINKAGE)
// ==========================================

static float speed_factor = 1.0f;
static os_unfair_lock speed_lock = OS_UNFAIR_LOCK_INIT;

// Original Function Pointers
static int (*orig_gettimeofday)(struct timeval *tv, struct timezone *tz);
static CFAbsoluteTime (*orig_CFAbsoluteTimeGetCurrent)(void);
static uint64_t (*orig_mach_absolute_time)(void);

// Base Anchors
static uint64_t base_real_mach = 0;
static uint64_t base_fake_mach = 0;

static CFAbsoluteTime base_real_cf = 0;
static CFAbsoluteTime base_fake_cf = 0;

static struct timeval base_real_tv = {0, 0};
static struct timeval base_fake_tv = {0, 0};

// Helper quy đổi Mach Timebase
static inline uint64_t scale_mach_ticks(uint64_t ticks, float factor) {
    static mach_timebase_info_data_t tb_info;
    if (tb_info.denom == 0) {
        mach_timebase_info(&tb_info);
    }
    double nanos = (double)ticks * (double)tb_info.numer / (double)tb_info.denom;
    double scaled_nanos = nanos * factor;
    return (uint64_t)(scaled_nanos * (double)tb_info.denom / (double)tb_info.numer);
}

// Khai báo C-Linkage xuất symbol công khai
#ifdef __cplusplus
extern "C" {
#endif

void set_speed_factor(float factor) {
    os_unfair_lock_lock(&speed_lock);
    
    if (factor == 1.0f) {
        base_real_mach = 0;
        base_fake_mach = 0;
        base_real_cf = 0;
        base_fake_cf = 0;
        base_real_tv = (struct timeval){0, 0};
        base_fake_tv = (struct timeval){0, 0};
        speed_factor = 1.0f;
        os_unfair_lock_unlock(&speed_lock);
        return;
    }

    if (orig_mach_absolute_time) {
        uint64_t now = orig_mach_absolute_time();
        if (base_real_mach != 0) {
            uint64_t delta = now - base_real_mach;
            base_fake_mach += scale_mach_ticks(delta, speed_factor);
        } else {
            base_fake_mach = now;
        }
        base_real_mach = now;
    }
    
    if (orig_CFAbsoluteTimeGetCurrent) {
        CFAbsoluteTime now = orig_CFAbsoluteTimeGetCurrent();
        if (base_real_cf != 0) {
            base_fake_cf += (now - base_real_cf) * speed_factor;
        } else {
            base_fake_cf = now;
        }
        base_real_cf = now;
    }

    if (orig_gettimeofday) {
        struct timeval now;
        if (orig_gettimeofday(&now, NULL) == 0) {
            if (base_real_tv.tv_sec != 0) {
                double delta = (now.tv_sec - base_real_tv.tv_sec) + 
                               (now.tv_usec - base_real_tv.tv_usec) / 1000000.0;
                double fake_delta = delta * speed_factor;
                long sec_add = (long)fake_delta;
                long usec_add = (long)((fake_delta - sec_add) * 1000000.0);
                
                base_fake_tv.tv_sec += sec_add;
                base_fake_tv.tv_usec += usec_add;
                if (base_fake_tv.tv_usec >= 1000000) {
                    base_fake_tv.tv_sec += 1;
                    base_fake_tv.tv_usec -= 1000000;
                }
            } else {
                base_fake_tv = now;
            }
            base_real_tv = now;
        }
    }

    speed_factor = factor;
    os_unfair_lock_unlock(&speed_lock);
}

float get_speed_factor(void) {
    return speed_factor;
}

#ifdef __cplusplus
}
#endif

// Hook 1: gettimeofday
int my_gettimeofday(struct timeval *tv, struct timezone *tz) {
    int ret = orig_gettimeofday(tv, tz);
    if (ret != 0 || tv == NULL) return ret;

    os_unfair_lock_lock(&speed_lock);
    if (speed_factor == 1.0f || base_real_tv.tv_sec == 0) {
        os_unfair_lock_unlock(&speed_lock);
        return ret;
    }

    double delta = (tv->tv_sec - base_real_tv.tv_sec) + 
                   (tv->tv_usec - base_real_tv.tv_usec) / 1000000.0;
    if (delta > 0) {
        double fake_delta = delta * speed_factor;
        struct timeval result = base_fake_tv;
        long sec_add = (long)fake_delta;
        long usec_add = (long)((fake_delta - sec_add) * 1000000.0);
        
        result.tv_sec += sec_add;
        result.tv_usec += usec_add;
        if (result.tv_usec >= 1000000) {
            result.tv_sec += 1;
            result.tv_usec -= 1000000;
        }
        *tv = result;
    }
    os_unfair_lock_unlock(&speed_lock);

    return ret;
}

// Hook 2: CFAbsoluteTimeGetCurrent
CFAbsoluteTime my_CFAbsoluteTimeGetCurrent(void) {
    CFAbsoluteTime real_now = orig_CFAbsoluteTimeGetCurrent();
    
    os_unfair_lock_lock(&speed_lock);
    if (speed_factor == 1.0f || base_real_cf == 0) {
        os_unfair_lock_unlock(&speed_lock);
        return real_now;
    }

    double delta = real_now - base_real_cf;
    if (delta > 0) {
        real_now = base_fake_cf + (delta * speed_factor);
    }
    os_unfair_lock_unlock(&speed_lock);

    return real_now;
}

// Hook 3: mach_absolute_time
uint64_t my_mach_absolute_time(void) {
    uint64_t real_now = orig_mach_absolute_time();

    os_unfair_lock_lock(&speed_lock);
    if (speed_factor == 1.0f || base_real_mach == 0) {
        os_unfair_lock_unlock(&speed_lock);
        return real_now;
    }

    if (real_now > base_real_mach) {
        uint64_t delta = real_now - base_real_mach;
        real_now = base_fake_mach + scale_mach_ticks(delta, speed_factor);
    }
    os_unfair_lock_unlock(&speed_lock);

    return real_now;
}

// Objective-C Swizzling cho NSDate
static void swizzle_NSDate_methods(void) {
    Class nsdateClass = [NSDate class];
    
    Method origRefMethod = class_getClassMethod(nsdateClass, @selector(timeIntervalSinceReferenceDate));
    if (origRefMethod) {
        method_setImplementation(origRefMethod, (IMP)my_CFAbsoluteTimeGetCurrent);
    }
    
    Method origDateMethod = class_getClassMethod(nsdateClass, @selector(date));
    if (origDateMethod) {
        IMP newDateImp = imp_implementationWithBlock(^id(id self) {
            return [NSDate dateWithTimeIntervalSinceReferenceDate:my_CFAbsoluteTimeGetCurrent()];
        });
        method_setImplementation(origDateMethod, newDateImp);
    }
}

// Initializer
__attribute__((constructor))
static void initialize(void) {
    struct rebinding rebindings[] = {
        {"gettimeofday", (void *)my_gettimeofday, (void **)&orig_gettimeofday},
        {"CFAbsoluteTimeGetCurrent", (void *)my_CFAbsoluteTimeGetCurrent, (void **)&orig_CFAbsoluteTimeGetCurrent},
        {"mach_absolute_time", (void *)my_mach_absolute_time, (void **)&orig_mach_absolute_time}
    };
    rebind_symbols(rebindings, 3);
    
    swizzle_NSDate_methods();
}
