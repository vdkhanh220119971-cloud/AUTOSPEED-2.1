#import <Foundation/Foundation.h>
#import <sys/time.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/runtime.h>
#import <mach/mach_time.h>
#import <os/lock.h>
#import "fishhook.h"

// ==========================================
// SPEEDHACK ENGINE (NON-ACCUMULATING ABSOLUTE LINEAR ANCHOR)
// ==========================================

static float speed_factor = 1.0f;
static os_unfair_lock speed_lock = OS_UNFAIR_LOCK_INIT;

// Original Function Pointers
static int (*orig_gettimeofday)(struct timeval *tv, struct timezone *tz);
static CFAbsoluteTime (*orig_CFAbsoluteTimeGetCurrent)(void);
static uint64_t (*orig_mach_absolute_time)(void);

// Absolute Base Anchors (Mốc gốc tuyệt đối)
static uint64_t mach_base_real = 0;
static uint64_t mach_base_fake = 0;

static CFAbsoluteTime cf_base_real = 0;
static CFAbsoluteTime cf_base_fake = 0;

static struct timeval tv_base_real = {0, 0};
static struct timeval tv_base_fake = {0, 0};

FOUNDATION_EXPORT void set_speed_factor(float factor) {
    os_unfair_lock_lock(&speed_lock);
    
    // Nếu chọn 1.0x -> Reset sạch toàn bộ mốc để trả về tốc độ gốc 100% của iOS
    if (factor == 1.0f) {
        mach_base_real = 0;
        mach_base_fake = 0;
        cf_base_real = 0;
        cf_base_fake = 0;
        tv_base_real = (struct timeval){0, 0};
        tv_base_fake = (struct timeval){0, 0};
        speed_factor = 1.0f;
        os_unfair_lock_unlock(&speed_lock);
        return;
    }

    // Khi chọn 1.05x hoặc 1.10x: Tính mốc fake hiện tại một lần duy nhất rồi CHỐT CỐ ĐỊNH, KHÔNG CỘNG DỒN TÍCH LŨY
    if (orig_mach_absolute_time) {
        uint64_t real_now = orig_mach_absolute_time();
        if (mach_base_real == 0) {
            mach_base_fake = real_now;
        } else {
            mach_base_fake += (uint64_t)((real_now - mach_base_real) * speed_factor);
        }
        mach_base_real = real_now;
    }
    
    if (orig_CFAbsoluteTimeGetCurrent) {
        CFAbsoluteTime real_now = orig_CFAbsoluteTimeGetCurrent();
        if (cf_base_real == 0) {
            cf_base_fake = real_now;
        } else {
            cf_base_fake += (real_now - cf_base_real) * speed_factor;
        }
        cf_base_real = real_now;
    }

    if (orig_gettimeofday) {
        struct timeval real_now;
        if (orig_gettimeofday(&real_now, NULL) == 0) {
            if (tv_base_real.tv_sec == 0) {
                tv_base_fake = real_now;
            } else {
                double delta = (real_now.tv_sec - tv_base_real.tv_sec) + 
                               (real_now.tv_usec - tv_base_real.tv_usec) / 1000000.0;
                double fake_delta = delta * speed_factor;
                long sec_add = (long)fake_delta;
                long usec_add = (long)((fake_delta - sec_add) * 1000000.0);
                
                tv_base_fake.tv_sec += sec_add;
                tv_base_fake.tv_usec += usec_add;
                if (tv_base_fake.tv_usec >= 1000000) {
                    tv_base_fake.tv_sec += 1;
                    tv_base_fake.tv_usec -= 1000000;
                }
            }
            tv_base_real = real_now;
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
    if (speed_factor == 1.0f || tv_base_real.tv_sec == 0) {
        os_unfair_lock_unlock(&speed_lock);
        return ret;
    }

    double delta = (tv->tv_sec - tv_base_real.tv_sec) + 
                   (tv->tv_usec - tv_base_real.tv_usec) / 1000000.0;
    if (delta > 0) {
        double fake_delta = delta * speed_factor;
        struct timeval result = tv_base_fake;
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
    if (speed_factor == 1.0f || cf_base_real == 0) {
        os_unfair_lock_unlock(&speed_lock);
        return real_now;
    }

    double delta = real_now - cf_base_real;
    if (delta > 0) {
        real_now = cf_base_fake + (delta * speed_factor);
    }
    os_unfair_lock_unlock(&speed_lock);

    return real_now;
}

// Hook 3: mach_absolute_time
uint64_t my_mach_absolute_time(void) {
    uint64_t real_now = orig_mach_absolute_time();

    os_unfair_lock_lock(&speed_lock);
    if (speed_factor == 1.0f || mach_base_real == 0) {
        os_unfair_lock_unlock(&speed_lock);
        return real_now;
    }

    if (real_now > mach_base_real) {
        uint64_t delta = real_now - mach_base_real;
        real_now = mach_base_fake + (uint64_t)(delta * speed_factor);
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
