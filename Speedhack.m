#import <Foundation/Foundation.h>
#import <sys/time.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/runtime.h>
#import <mach/mach_time.h>
#import <os/lock.h>
#import "fishhook.h"
 
// ==========================================
// SPEEDHACK ENGINE (THREAD-SAFE & MODULAR)
// ==========================================

static float speed_factor = 5.0f;
static os_unfair_lock speed_lock = OS_UNFAIR_LOCK_INIT;

FOUNDATION_EXPORT void set_speed_factor(float factor) {
    os_unfair_lock_lock(&speed_lock);
    speed_factor = factor;
    os_unfair_lock_unlock(&speed_lock);
}

FOUNDATION_EXPORT float get_speed_factor(void) {
    return speed_factor;
}

// Original Function Pointers
static int (*orig_gettimeofday)(struct timeval *tv, struct timezone *tz);
static CFAbsoluteTime (*orig_CFAbsoluteTimeGetCurrent)(void);
static uint64_t (*orig_mach_absolute_time)(void);

// Time Sync Trackers
static struct timeval last_real_tv = {0, 0};
static struct timeval fake_tv = {0, 0};

static CFAbsoluteTime last_real_cf = 0;
static CFAbsoluteTime fake_cf = 0;

static uint64_t last_real_mach = 0;
static uint64_t fake_mach = 0;

// Hook 1: gettimeofday
int my_gettimeofday(struct timeval *tv, struct timezone *tz) {
    int ret = orig_gettimeofday(tv, tz);
    if (ret != 0 || tv == NULL) return ret;

    os_unfair_lock_lock(&speed_lock);
    if (last_real_tv.tv_sec == 0) {
        last_real_tv = *tv;
        fake_tv = *tv;
    } else {
        double delta = (tv->tv_sec - last_real_tv.tv_sec) + 
                       (tv->tv_usec - last_real_tv.tv_usec) / 1000000.0;
        double fake_delta = delta * speed_factor;
        
        long sec_add = (long)fake_delta;
        long usec_add = (long)((fake_delta - sec_add) * 1000000.0);
        
        fake_tv.tv_sec += sec_add;
        fake_tv.tv_usec += usec_add;
        if (fake_tv.tv_usec >= 1000000) {
            fake_tv.tv_sec += 1;
            fake_tv.tv_usec -= 1000000;
        }
        last_real_tv = *tv;
    }
    *tv = fake_tv;
    os_unfair_lock_unlock(&speed_lock);

    return ret;
}

// Hook 2: CFAbsoluteTimeGetCurrent
CFAbsoluteTime my_CFAbsoluteTimeGetCurrent(void) {
    CFAbsoluteTime real_now = orig_CFAbsoluteTimeGetCurrent();
    
    os_unfair_lock_lock(&speed_lock);
    if (last_real_cf == 0) {
        last_real_cf = real_now;
        fake_cf = real_now;
    } else {
        double delta = real_now - last_real_cf;
        fake_cf += delta * speed_factor;
        last_real_cf = real_now;
    }
    CFAbsoluteTime result = fake_cf;
    os_unfair_lock_unlock(&speed_lock);

    return result;
}

// Hook 3: mach_absolute_time
uint64_t my_mach_absolute_time(void) {
    uint64_t real_now = orig_mach_absolute_time();

    os_unfair_lock_lock(&speed_lock);
    if (last_real_mach == 0) {
        last_real_mach = real_now;
        fake_mach = real_now;
    } else {
        uint64_t delta = real_now - last_real_mach;
        fake_mach += (uint64_t)(delta * speed_factor);
        last_real_mach = real_now;
    }
    uint64_t result = fake_mach;
    os_unfair_lock_unlock(&speed_lock);

    return result;
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
