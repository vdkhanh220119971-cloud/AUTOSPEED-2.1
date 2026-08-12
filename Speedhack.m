#import <Foundation/Foundation.h>
#import <sys/time.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/runtime.h>
#import <mach/mach_time.h>
#import <os/lock.h>
#import "fishhook.h"

// ==========================================
// SPEEDHACK ENGINE (DIRECT BYPASS & ZERO-DRIFT ANCHOR)
// ==========================================

static float speed_factor = 1.0f;
static os_unfair_lock speed_lock = OS_UNFAIR_LOCK_INIT;

// Original Function Pointers
static int (*orig_gettimeofday)(struct timeval *tv, struct timezone *tz);
static CFAbsoluteTime (*orig_CFAbsoluteTimeGetCurrent)(void);
static uint64_t (*orig_mach_absolute_time)(void);

// Anchor Points (Gốc thời gian)
static uint64_t anchor_real_mach = 0;
static uint64_t anchor_fake_mach = 0;

static CFAbsoluteTime anchor_real_cf = 0;
static CFAbsoluteTime anchor_fake_cf = 0;

static struct timeval anchor_real_tv = {0, 0};
static struct timeval anchor_fake_tv = {0, 0};

FOUNDATION_EXPORT void set_speed_factor(float factor) {
    os_unfair_lock_lock(&speed_lock);
    
    // Chốt mốc mach_absolute_time tại thời điểm đổi tốc độ
    if (orig_mach_absolute_time) {
        uint64_t real_now = orig_mach_absolute_time();
        if (anchor_real_mach == 0) {
            anchor_fake_mach = real_now;
        } else {
            anchor_fake_mach += (uint64_t)((real_now - anchor_real_mach) * speed_factor);
        }
        anchor_real_mach = real_now;
    }
    
    // Chốt mốc CFAbsoluteTimeGetCurrent
    if (orig_CFAbsoluteTimeGetCurrent) {
        CFAbsoluteTime real_now = orig_CFAbsoluteTimeGetCurrent();
        if (anchor_real_cf == 0) {
            anchor_fake_cf = real_now;
        } else {
            anchor_fake_cf += (real_now - anchor_real_cf) * speed_factor;
        }
        anchor_real_cf = real_now;
    }

    // Chốt mốc gettimeofday
    if (orig_gettimeofday) {
        struct timeval real_now;
        if (orig_gettimeofday(&real_now, NULL) == 0) {
            if (anchor_real_tv.tv_sec == 0) {
                anchor_fake_tv = real_now;
            } else {
                double delta = (real_now.tv_sec - anchor_real_tv.tv_sec) + 
                               (real_now.tv_usec - anchor_real_tv.tv_usec) / 1000000.0;
                double fake_delta = delta * speed_factor;
                long sec_add = (long)fake_delta;
                long usec_add = (long)((fake_delta - sec_add) * 1000000.0);
                
                anchor_fake_tv.tv_sec += sec_add;
                anchor_fake_tv.tv_usec += usec_add;
                if (anchor_fake_tv.tv_usec >= 1000000) {
                    anchor_fake_tv.tv_sec += 1;
                    anchor_fake_tv.tv_usec -= 1000000;
                }
            }
            anchor_real_tv = real_now;
        }
    }

    speed_factor = factor;
    os_unfair_lock_unlock(&speed_lock);
}

FOUNDATION_EXPORT float get_speed_factor(void) {
    return speed_factor;
}

// Hook 1: gettimeofday
int my_gettimeofday(struct timeval *tv, struct timezone *tz) {
    int ret = orig_gettimeofday(tv, tz);
    if (ret != 0 || tv == NULL) return ret;

    os_unfair_lock_lock(&speed_lock);
    // Bypass hoàn toàn khi 1.0x
    if (speed_factor == 1.0f) {
        os_unfair_lock_unlock(&speed_lock);
        return ret;
    }

    if (anchor_real_tv.tv_sec == 0) {
        anchor_real_tv = *tv;
        anchor_fake_tv = *tv;
    } else {
        double delta = (tv->tv_sec - anchor_real_tv.tv_sec) + 
                       (tv->tv_usec - anchor_real_tv.tv_usec) / 1000000.0;
        if (delta > 0) {
            double fake_delta = delta * speed_factor;
            struct timeval result = anchor_fake_tv;
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
    }
    os_unfair_lock_unlock(&speed_lock);

    return ret;
}

// Hook 2: CFAbsoluteTimeGetCurrent
CFAbsoluteTime my_CFAbsoluteTimeGetCurrent(void) {
    CFAbsoluteTime real_now = orig_CFAbsoluteTimeGetCurrent();
    
    os_unfair_lock_lock(&speed_lock);
    // Bypass hoàn toàn khi 1.0x
    if (speed_factor == 1.0f) {
        os_unfair_lock_unlock(&speed_lock);
        return real_now;
    }

    if (anchor_real_cf == 0) {
        anchor_real_cf = real_now;
        anchor_fake_cf = real_now;
    } else {
        double delta = real_now - anchor_real_cf;
        if (delta > 0) {
            real_now = anchor_fake_cf + (delta * speed_factor);
        }
    }
    os_unfair_lock_unlock(&speed_lock);

    return real_now;
}

// Hook 3: mach_absolute_time
uint64_t my_mach_absolute_time(void) {
    uint64_t real_now = orig_mach_absolute_time();

    os_unfair_lock_lock(&speed_lock);
    // Bypass hoàn toàn khi 1.0x
    if (speed_factor == 1.0f) {
        os_unfair_lock_unlock(&speed_lock);
        return real_now;
    }

    if (anchor_real_mach == 0) {
        anchor_real_mach = real_now;
        anchor_fake_mach = real_now;
    } else {
        if (real_now > anchor_real_mach) {
            uint64_t delta = real_now - anchor_real_mach;
            real_now = anchor_fake_mach + (uint64_t)(delta * speed_factor);
        }
    }
    os_unfair_lock_unlock(&speed_lock);

    return real_now;
}

// Objective-C Swizzling for NSDate
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
