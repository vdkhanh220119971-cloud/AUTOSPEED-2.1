#import <UIKit/UIKit.h>

// Hàm kết nối với Speedhack.m
extern void set_speed_factor(float factor);
extern float get_speed_factor(void);

@interface SpeedhackMenu : UIView

@property (nonatomic, strong) UIButton *mainButton;
@property (nonatomic, strong) NSMutableArray<UIButton *> *optionButtons;
@property (nonatomic, assign) BOOL isExpanded;
@property (nonatomic, strong) NSTimer *fadeTimer;

@end

@implementation SpeedhackMenu

+ (void)load {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIWindow *keyWindow = nil;
        for (UIWindow *window in [UIApplication sharedApplication].windows) {
            if (window.isKeyWindow) {
                keyWindow = window;
                break;
            }
        }
        if (!keyWindow && [UIApplication sharedApplication].windows.count > 0) {
            keyWindow = [UIApplication sharedApplication].windows.firstObject;
        }

        if (keyWindow) {
            SpeedhackMenu *menu = [[SpeedhackMenu alloc] initWithFrame:CGRectMake(50, 150, 50, 50)];
            [keyWindow addSubview:menu];
        }
    });
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _isExpanded = NO;
        _optionButtons = [NSMutableArray array];

        // 1. Nút chính (Bánh xe center)
        _mainButton = [UIButton buttonWithType:UIButtonTypeCustom];
        _mainButton.frame = CGRectMake(0, 0, 50, 50);
        _mainButton.backgroundColor = [UIColor colorWithRed:0.1 green:0.6 blue:1.0 alpha:0.9];
        _mainButton.layer.cornerRadius = 25.0;
        _mainButton.layer.borderWidth = 2.0;
        _mainButton.layer.borderColor = [UIColor whiteColor].CGColor;
        [_mainButton setTitle:@"⚡️" forState:UIControlStateNormal];
        _mainButton.titleLabel.font = [UIFont systemFontOfSize:22];
        
        [_mainButton addTarget:self action:@selector(toggleMenu) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:_mainButton];

        // Gesture kéo thả
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
        [self addGestureRecognizer:pan];

        // 2. Các tùy chọn tốc độ dạng bánh xe
        NSArray *speeds = @[@"1x", @"2x", @"5x", @"10x", @"20x"];
        for (NSString *speedStr in speeds) {
            UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
            btn.frame = CGRectMake(5, 5, 40, 40);
            btn.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.95];
            btn.layer.cornerRadius = 20.0;
            btn.layer.borderWidth = 1.5;
            btn.layer.borderColor = [UIColor colorWithRed:0.1 green:0.6 blue:1.0 alpha:1.0].CGColor;
            [btn setTitle:speedStr forState:UIControlStateNormal];
            [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
            btn.titleLabel.font = [UIFont boldSystemFontOfSize:13];
            btn.alpha = 0.0;
            btn.transform = CGAffineTransformMakeScale(0.1, 0.1);
            
            [btn addTarget:self action:@selector(speedOptionSelected:) forControlEvents:UIControlEventTouchUpInside];
            
            [self insertSubview:btn belowSubview:_mainButton];
            [_optionButtons addObject:btn];
        }

        // Mặc định mờ khi vừa load
        self.alpha = 0.25;
    }
    return self;
}

// Bật / Tắt hiệu ứng xòe bánh xe
- (void)toggleMenu {
    [self resetFadeTimer];
    self.alpha = 1.0; // Hiện rõ ngay khi chạm
    
    _isExpanded = !_isExpanded;
    
    float radius = 75.0; // Bán kính xòe bánh xe
    NSUInteger count = _optionButtons.count;
    float stepAngle = (2.0 * M_PI) / count;

    [UIView animateWithDuration:0.35 delay:0 usingSpringWithDamping:0.7 initialSpringVelocity:0.5 options:UIViewAnimationOptionCurveEaseInOut animations:^{
        for (NSUInteger i = 0; i < count; i++) {
            UIButton *btn = self.optionButtons[i];
            if (self.isExpanded) {
                float angle = i * stepAngle - (M_PI_2);
                float x = cosf(angle) * radius;
                float y = sinf(angle) * radius;
                
                btn.transform = CGAffineTransformMakeTranslation(x, y);
                btn.alpha = 1.0;
            } else {
                btn.transform = CGAffineTransformIdentity;
                btn.alpha = 0.0;
            }
        }
    } completion:nil];
}

// Xử lý khi bấm nút chọn tốc độ
- (void)speedOptionSelected:(UIButton *)sender {
    NSString *title = [sender titleForState:UIControlStateNormal];
    float speed = [title floatValue];
    if (speed > 0) {
        set_speed_factor(speed);
        [_mainButton setTitle:[NSString stringWithFormat:@"%.0fx", speed] forState:UIControlStateNormal];
    }
    
    [self toggleMenu]; // Thu gọn menu sau khi chọn
}

// Kéo thả vị trí Menu
- (void)handlePan:(UIPanGestureRecognizer *)pan {
    [self resetFadeTimer];
    self.alpha = 1.0;
    
    CGPoint translation = [pan translationInView:self.superview];
    self.center = CGPointMake(self.center.x + translation.x, self.center.y + translation.y);
    [pan setTranslation:CGPointZero inView:self.superview];

    if (pan.state == UIGestureRecognizerStateEnded) {
        [self startFadeTimer];
    }
}

// Quản lý làm mờ tự động
- (void)resetFadeTimer {
    [_fadeTimer invalidate];
    _fadeTimer = [NSTimer scheduledTimerWithTimeInterval:3.0 target:self selector:@selector(dimMenu) userInfo:nil repeats:NO];
}

- (void)startFadeTimer {
    [self resetFadeTimer];
}

- (void)dimMenu {
    if (!_isExpanded) {
        [UIView animateWithDuration:0.5 animations:^{
            self.alpha = 0.20; // Mờ còn 20%
        }];
    }
}

@end
