#import <Foundation/Foundation.h>
#import <sys/time.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/runtime.h>
#import <mach/mach_time.h>
#import <os/lock.h>
#import "fishhook.h"

// ==========================================
// SPEEDHACK ENGINE (EVENT-BOUNDARY RESET)
// ==========================================

static float speed_factor = 1.0f;
static os_unfair_lock speed_lock = OS_UNFAIR_LOCK_INIT;

// Original Function Pointers
static int (*orig_gettimeofday)(struct timeval *tv, struct timezone *tz);
static CFAbsoluteTime (*orig_CFAbsoluteTimeGetCurrent)(void);
static uint64_t (*orig_mach_absolute_time)(void);

// Frame Trackers
static uint64_t last_real_mach = 0;
static uint64_t current_fake_mach = 0;

static CFAbsoluteTime last_real_cf = 0;
static CFAbsoluteTime current_fake_cf = 0;

static struct timeval last_real_tv = {0, 0};
static struct timeval current_fake_tv = {0, 0};

FOUNDATION_EXPORT void set_speed_factor(float factor) {
    os_unfair_lock_lock(&speed_lock);
    
    speed_factor = factor;
    
    // Reset toàn bộ trackers khi đổi tốc độ
    last_real_mach = 0;
    current_fake_mach = 0;
    last_real_cf = 0;
    current_fake_cf = 0;
    last_real_tv = (struct timeval){0, 0};
    current_fake_tv = (struct timeval){0, 0};
    
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

    if (last_real_tv.tv_sec == 0) {
        last_real_tv = *tv;
        current_fake_tv = *tv;
    } else {
        double delta = (tv->tv_sec - last_real_tv.tv_sec) + 
                       (tv->tv_usec - last_real_tv.tv_usec) / 1000000.0;
        
        // Ngưỡng phát hiện ngắt sự kiện / thoát app: delta > 0.3s hoặc delta < 0
        if (delta > 0.3 || delta < 0) {
            last_real_tv = *tv;
            current_fake_tv = *tv;
        } else if (delta > 0) {
            double fake_delta = delta * speed_factor;
            long sec_add = (long)fake_delta;
            long usec_add = (long)((fake_delta - sec_add) * 1000000.0);
            
            current_fake_tv.tv_sec += sec_add;
            current_fake_tv.tv_usec += usec_add;
            if (current_fake_tv.tv_usec >= 1000000) {
                current_fake_tv.tv_sec += 1;
                current_fake_tv.tv_usec -= 1000000;
            }
            last_real_tv = *tv;
        }
    }
    *tv = current_fake_tv;
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

    if (last_real_cf == 0) {
        last_real_cf = real_now;
        current_fake_cf = real_now;
    } else {
        double delta = real_now - last_real_cf;
        
        // Ngưỡng phát hiện ngắt sự kiện: delta > 0.3s hoặc delta < 0
        if (delta > 0.3 || delta < 0) {
            last_real_cf = real_now;
            current_fake_cf = real_now;
        } else if (delta > 0) {
            current_fake_cf += delta * speed_factor;
            last_real_cf = real_now;
        }
    }
    CFAbsoluteTime result = current_fake_cf;
    os_unfair_lock_unlock(&speed_lock);

    return result;
}

// Hook 3: mach_absolute_time
uint64_t my_mach_absolute_time(void) {
    uint64_t real_now = orig_mach_absolute_time();

    os_unfair_lock_lock(&speed_lock);
    if (speed_factor == 1.0f) {
        os_unfair_lock_unlock(&speed_lock);
        return real_now;
    }

    if (last_real_mach == 0) {
        last_real_mach = real_now;
        current_fake_mach = real_now;
    } else {
        if (real_now > last_real_mach) {
            uint64_t delta = real_now - last_real_mach;
            
            mach_timebase_info_data_t info;
            mach_timebase_info(&info);
            double delta_sec = (double)delta * info.numer / info.denom / 1e9;

            // Ngưỡng phát hiện ngắt sự kiện: delta > 0.3s
            if (delta_sec > 0.3) {
                last_real_mach = real_now;
                current_fake_mach = real_now;
            } else {
                current_fake_mach += (uint64_t)(delta * speed_factor);
                last_real_mach = real_now;
            }
        }
    }
    uint64_t result = current_fake_mach;
    os_unfair_lock_unlock(&speed_lock);

    return result;
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
