#import <Foundation/Foundation.h>
#import <sys/time.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/runtime.h>
#import <mach/mach_time.h>
#import <os/lock.h>
#import "fishhook.h"

// ==========================================
// SPEEDHACK ENGINE (PRECISION MACH TIMEBASE CONVERSION)
// ==========================================

static float speed_factor = 1.0f;
static os_unfair_lock speed_lock = OS_UNFAIR_LOCK_INIT;

// Original Function Pointers
static int (*orig_gettimeofday)(struct timeval *tv, struct timezone *tz);
static CFAbsoluteTime (*orig_CFAbsoluteTimeGetCurrent)(void);
static uint64_t (*orig_mach_absolute_time)(void);

// Base Anchors
static uint64_t mach_real_anchor = 0;
static uint64_t mach_fake_anchor = 0;

static CFAbsoluteTime cf_real_anchor = 0;
static CFAbsoluteTime cf_fake_anchor = 0;

static struct timeval tv_real_anchor = {0, 0};
static struct timeval tv_fake_anchor = {0, 0};

// Helper quy đổi Mach Timebase
static inline uint64_t scale_mach_delta(uint64_t delta, float factor) {
    static mach_timebase_info_data_t timebase_info;
    if (timebase_info.denom == 0) {
        mach_timebase_info(&timebase_info);
    }
    // Quy đổi Mach Tick -> Nanoseconds -> Apply Factor -> Quy đổi ngược về Mach Tick
    double nanos = (double)delta * (double)timebase_info.numer / (double)timebase_info.denom;
    double scaled_nanos = nanos * factor;
    uint64_t scaled_ticks = (uint64_t)(scaled_nanos * (double)timebase_info.denom / (double)timebase_info.numer);
    return scaled_ticks;
}

FOUNDATION_EXPORT void set_speed_factor(float factor) {
    os_unfair_lock_lock(&speed_lock);
    
    // 1. Chốt mốc mach_absolute_time hiện tại trước khi đổi tốc độ
    if (orig_mach_absolute_time && mach_real_anchor != 0) {
        uint64_t now = orig_mach_absolute_time();
        if (now > mach_real_anchor) {
            mach_fake_anchor += scale_mach_delta(now - mach_real_anchor, speed_factor);
            mach_real_anchor = now;
        }
    }
    
    // 2. Chốt mốc CFAbsoluteTimeGetCurrent hiện tại
    if (orig_CFAbsoluteTimeGetCurrent && cf_real_anchor != 0) {
        CFAbsoluteTime now = orig_CFAbsoluteTimeGetCurrent();
        if (now > cf_real_anchor) {
            cf_fake_anchor += (now - cf_real_anchor) * speed_factor;
            cf_real_anchor = now;
        }
    }

    // 3. Chốt mốc gettimeofday hiện tại
    if (orig_gettimeofday && tv_real_anchor.tv_sec != 0) {
        struct timeval now;
        if (orig_gettimeofday(&now, NULL) == 0) {
            double delta = (now.tv_sec - tv_real_anchor.tv_sec) + 
                           (now.tv_usec - tv_real_anchor.tv_usec) / 1000000.0;
            if (delta > 0) {
                double fake_delta = delta * speed_factor;
                long sec_add = (long)fake_delta;
                long usec_add = (long)((fake_delta - sec_add) * 1000000.0);
                
                tv_fake_anchor.tv_sec += sec_add;
                tv_fake_anchor.tv_usec += usec_add;
                if (tv_fake_anchor.tv_usec >= 1000000) {
                    tv_fake_anchor.tv_sec += 1;
                    tv_fake_anchor.tv_usec -= 1000000;
                }
                tv_real_anchor = now;
            }
        }
    }

    // 4. Nếu chọn 1.0x -> Reset mốc để Direct Bypass hoạt động chuẩn 100%
    if (factor == 1.0f) {
        mach_real_anchor = 0;
        mach_fake_anchor = 0;
        cf_real_anchor = 0;
        cf_fake_anchor = 0;
        tv_real_anchor = (struct timeval){0, 0};
        tv_fake_anchor = (struct timeval){0, 0};
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
    if (speed_factor == 1.0f) {
        os_unfair_lock_unlock(&speed_lock);
        return ret;
    }

    if (tv_real_anchor.tv_sec == 0) {
        tv_real_anchor = *tv;
        tv_fake_anchor = *tv;
    } else {
        double delta = (tv->tv_sec - tv_real_anchor.tv_sec) + 
                       (tv->tv_usec - tv_real_anchor.tv_usec) / 1000000.0;
        if (delta > 0) {
            double fake_delta = delta * speed_factor;
            struct timeval result = tv_fake_anchor;
            long sec_add = (long)fake_delta;
            long usec_add = (long)((fake_delta - sec_add) * 1000000.0);
            
            result.tv_sec += sec_add;
            result.tv_usec += usec_add;
            if (result.tv_usec >= 1000000) {
                result.tv_sec += 1;
                result.tv_usec -= 1000000;
            }
            *tv = result;
        } else {
            *tv = tv_fake_anchor;
        }
    }
    os_unfair_lock_unlock(&speed_lock);

    return ret;
}

// Hook 2: CFAbsoluteTimeGetCurrent
CFAbsoluteTime my_CFAbsoluteTimeGetCurrent(void) {
    CFAbsoluteTime real_now = orig_CFAbsoluteTimeGetCurrent();
    
    os_unfair_lock_lock(&speed_lock);
    if (speed_factor == 1.0f) {
        os_unfair_lock_unlock(&speed_lock);
        return real_now;
    }

    if (cf_real_anchor == 0) {
        cf_real_anchor = real_now;
        cf_fake_anchor = real_now;
    } else {
        double delta = real_now - cf_real_anchor;
        if (delta > 0) {
            real_now = cf_fake_anchor + (delta * speed_factor);
        } else {
            real_now = cf_fake_anchor;
        }
    }
    os_unfair_lock_unlock(&speed_lock);

    return real_now;
}

// Hook 3: mach_absolute_time (Đã sửa quy đổi chính xác theo Timebase Info)
uint64_t my_mach_absolute_time(void) {
    uint64_t real_now = orig_mach_absolute_time();

    os_unfair_lock_lock(&speed_lock);
    if (speed_factor == 1.0f) {
        os_unfair_lock_unlock(&speed_lock);
        return real_now;
    }

    if (mach_real_anchor == 0) {
        mach_real_anchor = real_now;
        mach_fake_anchor = real_now;
    } else {
        if (real_now > mach_real_anchor) {
            uint64_t delta = real_now - mach_real_anchor;
            real_now = mach_fake_anchor + scale_mach_delta(delta, speed_factor);
        } else {
            real_now = mach_fake_anchor;
        }
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
