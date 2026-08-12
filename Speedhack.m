#import <Foundation/Foundation.h>
#import <sys/time.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/runtime.h>
#import <mach/mach_time.h>
#import <os/lock.h>
#import "fishhook.h"

// ==========================================
// SPEEDHACK ENGINE (HARD-RESET RE-ANCHORING)
// ==========================================

static float speed_factor = 1.0f;
static os_unfair_lock speed_lock = OS_UNFAIR_LOCK_INIT;

// Original Function Pointers
static int (*orig_gettimeofday)(struct timeval *tv, struct timezone *tz);
static CFAbsoluteTime (*orig_CFAbsoluteTimeGetCurrent)(void);
static uint64_t (*orig_mach_absolute_time)(void);

// Anchor Points (Mốc thời gian gốc)
static uint64_t anchor_real_mach = 0;
static uint64_t anchor_fake_mach = 0;

static CFAbsoluteTime anchor_real_cf = 0;
static CFAbsoluteTime anchor_fake_cf = 0;

static struct timeval anchor_real_tv = {0, 0};
static struct timeval anchor_fake_tv = {0, 0};

FOUNDATION_EXPORT void set_speed_factor(float factor) {
    os_unfair_lock_lock(&speed_lock);
    
    // Đặt tốc độ mới
    speed_factor = factor;
    
    // HARD RESET: Xóa toàn bộ mốc tích lũy cũ để tránh dữ liệu cũ đè lên dữ liệu mới
    if (factor == 1.0f) {
        // Về 1x: Xóa trắng toàn bộ mốc gốc -> Direct Bypass hoạt động chuẩn 100%
        anchor_real_mach = 0;
        anchor_fake_mach = 0;
        anchor_real_cf = 0;
        anchor_fake_cf = 0;
        anchor_real_tv = (struct timeval){0, 0};
        anchor_fake_tv = (struct timeval){0, 0};
    } else {
        // Khi chọn 1.01x hoặc 1.02x: Lấy thời gian thực HIỆN TẠI làm mốc xuất phát mới hoàn toàn
        if (orig_mach_absolute_time) {
            uint64_t real_now = orig_mach_absolute_time();
            anchor_real_mach = real_now;
            anchor_fake_mach = real_now;
        }
        if (orig_CFAbsoluteTimeGetCurrent) {
            CFAbsoluteTime real_now = orig_CFAbsoluteTimeGetCurrent();
            anchor_real_cf = real_now;
            anchor_fake_cf = real_now;
        }
        if (orig_gettimeofday) {
            struct timeval real_now;
            if (orig_gettimeofday(&real_now, NULL) == 0) {
                anchor_real_tv = real_now;
                anchor_fake_tv = real_now;
            }
        }
    }
    
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
    if (speed_factor == 1.0f || anchor_real_tv.tv_sec == 0) {
        os_unfair_lock_unlock(&speed_lock);
        return ret;
    }

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
    os_unfair_lock_unlock(&speed_lock);

    return ret;
}

// Hook 2: CFAbsoluteTimeGetCurrent
CFAbsoluteTime my_CFAbsoluteTimeGetCurrent(void) {
    CFAbsoluteTime real_now = orig_CFAbsoluteTimeGetCurrent();
    
    os_unfair_lock_lock(&speed_lock);
    if (speed_factor == 1.0f || anchor_real_cf == 0) {
        os_unfair_lock_unlock(&speed_lock);
        return real_now;
    }

    double delta = real_now - anchor_real_cf;
    if (delta > 0) {
        real_now = anchor_fake_cf + (delta * speed_factor);
    }
    os_unfair_lock_unlock(&speed_lock);

    return real_now;
}

// Hook 3: mach_absolute_time
uint64_t my_mach_absolute_time(void) {
    uint64_t real_now = orig_mach_absolute_time();

    os_unfair_lock_lock(&speed_lock);
    if (speed_factor == 1.0f || anchor_real_mach == 0) {
        os_unfair_lock_unlock(&speed_lock);
        return real_now;
    }

    if (real_now > anchor_real_mach) {
        uint64_t delta = real_now - anchor_real_mach;
        real_now = anchor_fake_mach + (uint64_t)(delta * speed_factor);
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
