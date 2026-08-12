#import <Foundation/Foundation.h>
#import <mach/mach_time.h>
#import <os/lock.h>
#import "fishhook.h"

// ==========================================
// SPEEDHACK ENGINE (MINIMAL MACH-ONLY ENGINE)
// ==========================================

static float speed_factor = 1.0f;
static os_unfair_lock speed_lock = OS_UNFAIR_LOCK_INIT;

static uint64_t (*orig_mach_absolute_time)(void) = NULL;

static uint64_t last_real_mach = 0;
static uint64_t fake_mach = 0;

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

// Hook duy nhất: mach_absolute_time (Quản lý khung hình & animation)
uint64_t my_mach_absolute_time(void) {
    uint64_t real_now = orig_mach_absolute_time();

    os_unfair_lock_lock(&speed_lock);
    
    // Khởi tạo frame đầu tiên
    if (last_real_mach == 0) {
        last_real_mach = real_now;
        fake_mach = real_now;
        os_unfair_lock_unlock(&speed_lock);
        return real_now;
    }

    // Tăng tốc từng vi phân khung hình (frame delta)
    if (real_now > last_real_mach) {
        uint64_t delta = real_now - last_real_mach;
        fake_mach += (uint64_t)(delta * speed_factor);
        last_real_mach = real_now;
    }

    uint64_t result = fake_mach;
    os_unfair_lock_unlock(&speed_lock);

    return result;
}

__attribute__((constructor))
static void initialize(void) {
    struct rebinding rebindings[] = {
        {"mach_absolute_time", (void *)my_mach_absolute_time, (void **)&orig_mach_absolute_time}
    };
    rebind_symbols(rebindings, 1);
}
