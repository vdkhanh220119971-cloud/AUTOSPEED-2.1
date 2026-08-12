#import <UIKit/UIKit.h>
#import <CoreGraphics/CoreGraphics.h>

#ifdef __cplusplus
extern "C" {
#endif

extern void set_speed_factor(float factor);
extern float get_speed_factor(void);

#ifdef __cplusplus
}
#endif

@interface SpeedhackMenu : UIView

@property (nonatomic, strong) UIButton *mainButton;
@property (nonatomic, strong) UIView *presetPanel;
@property (nonatomic, strong) UIButton *btn100;
@property (nonatomic, strong) UIButton *btn105;
@property (nonatomic, strong) UIButton *btn110;
@property (nonatomic, assign) BOOL isExpanded;
@property (nonatomic, strong) NSTimer *fadeTimer;
@property (nonatomic, assign) float currentSpeed;

@end

@implementation SpeedhackMenu

+ (void)load {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIWindow *keyWindow = [self getKeyWindow];
        if (keyWindow) {
            SpeedhackMenu *menu = [[SpeedhackMenu alloc] initWithFrame:CGRectMake(20, 150, 50, 50)];
            [keyWindow addSubview:menu];
        }
    });
}

// Sửa cảnh báo Deprecated 'keyWindow' chuẩn iOS 13+
+ (UIWindow *)getKeyWindow {
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (scene.activationState == UISceneActivationStateForegroundActive && [scene isKindOfClass:[UIWindowScene class]]) {
                UIWindowScene *windowScene = (UIWindowScene *)scene;
                for (UIWindow *window in windowScene.windows) {
                    if (window.isKeyWindow) return window;
                }
            }
        }
    }
    return nil;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _isExpanded = NO;
        _currentSpeed = get_speed_factor();
        if (fabsf(_currentSpeed - 1.05f) > 0.001f && fabsf(_currentSpeed - 1.10f) > 0.001f) {
            _currentSpeed = 1.00f;
        }

        // 1. Nút chính
        _mainButton = [UIButton buttonWithType:UIButtonTypeCustom];
        _mainButton.frame = CGRectMake(0, 0, 50, 50);
        _mainButton.backgroundColor = [UIColor colorWithRed:0.1 green:0.55 blue:1.0 alpha:0.9];
        _mainButton.layer.cornerRadius = 25.0;
        _mainButton.layer.borderWidth = 2.0;
        _mainButton.layer.borderColor = [UIColor whiteColor].CGColor;
        _mainButton.layer.shadowColor = [UIColor blackColor].CGColor;
        _mainButton.layer.shadowOffset = CGSizeMake(0, 2);
        _mainButton.layer.shadowOpacity = 0.3;
        _mainButton.layer.shadowRadius = 4.0;
        
        [self updateMainButtonTitle];
        _mainButton.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightBold];
        [_mainButton addTarget:self action:@selector(toggleMenu) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:_mainButton];

        // Gesture kéo thả
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
        [self addGestureRecognizer:pan];

        // 2. Bảng Nút Chọn Tốc Độ (Preset Panel)
        _presetPanel = [[UIView alloc] initWithFrame:CGRectMake(55, 2.5, 165, 45)];
        _presetPanel.backgroundColor = [UIColor colorWithRed:0.12 green:0.12 blue:0.14 alpha:0.95];
        _presetPanel.layer.cornerRadius = 12.0;
        _presetPanel.layer.borderWidth = 1.5;
        _presetPanel.layer.borderColor = [UIColor colorWithRed:0.1 green:0.55 blue:1.0 alpha:1.0].CGColor;
        _presetPanel.alpha = 0.0;
        _presetPanel.hidden = YES;

        // Nút 1x
        _btn100 = [self createSpeedButtonWithTitle:@"1x" tag:100 frame:CGRectMake(8, 7.5, 45, 30)];
        [_presetPanel addSubview:_btn100];

        // Nút 1.05x
        _btn105 = [self createSpeedButtonWithTitle:@"1.05x" tag:105 frame:CGRectMake(60, 7.5, 45, 30)];
        [_presetPanel addSubview:_btn105];

        // Nút 1.1x
        _btn110 = [self createSpeedButtonWithTitle:@"1.1x" tag:110 frame:CGRectMake(112, 7.5, 45, 30)];
        [_presetPanel addSubview:_btn110];

        [self updateButtonStates];
        [self addSubview:_presetPanel];

        self.alpha = 0.10;
    }
    return self;
}

- (UIButton *)createSpeedButtonWithTitle:(NSString *)title tag:(NSInteger)tag frame:(CGRect)frame {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
    btn.frame = frame;
    btn.tag = tag;
    [btn setTitle:title forState:UIControlStateNormal];
    btn.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightBold];
    btn.layer.cornerRadius = 8.0;
    [btn addTarget:self action:@selector(speedButtonTapped:) forControlEvents:UIControlEventTouchUpInside];
    return btn;
}

- (void)updateMainButtonTitle {
    if (_currentSpeed == 1.00f) {
        [_mainButton setTitle:@"⚡️1x" forState:UIControlStateNormal];
    } else {
        [_mainButton setTitle:[NSString stringWithFormat:@"%.2fx", _currentSpeed] forState:UIControlStateNormal];
    }
}

- (void)updateButtonStates {
    NSArray *buttons = @[_btn100, _btn105, _btn110];
    for (UIButton *btn in buttons) {
        float speed = 1.00f;
        if (btn.tag == 105) speed = 1.05f;
        if (btn.tag == 110) speed = 1.10f;

        if (fabsf(_currentSpeed - speed) < 0.001f) {
            btn.backgroundColor = [UIColor colorWithRed:0.1 green:0.55 blue:1.0 alpha:1.0];
            [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        } else {
            btn.backgroundColor = [UIColor colorWithRed:0.22 green:0.22 blue:0.25 alpha:1.0];
            [btn setTitleColor:[UIColor lightGrayColor] forState:UIControlStateNormal];
        }
    }
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (self.hidden || self.alpha < 0.01) return nil;

    CGPoint mainPoint = [self convertPoint:point toView:self.mainButton];
    if ([self.mainButton pointInside:mainPoint withEvent:event]) {
        return self.mainButton;
    }

    if (self.isExpanded) {
        CGPoint panelPoint = [self convertPoint:point toView:self.presetPanel];
        if ([self.presetPanel pointInside:panelPoint withEvent:event]) {
            return [self.presetPanel hitTest:panelPoint withEvent:event];
        }
    }
    return nil;
}

- (void)triggerHaptic {
    if (@available(iOS 10.0, *)) {
        UIImpactFeedbackGenerator *generator = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
        [generator prepare];
        [generator impactOccurred];
    }
}

- (void)speedButtonTapped:(UIButton *)sender {
    [self triggerHaptic];
    [self resetFadeTimer];
    self.alpha = 1.0;

    if (sender.tag == 100) _currentSpeed = 1.00f;
    else if (sender.tag == 105) _currentSpeed = 1.05f;
    else if (sender.tag == 110) _currentSpeed = 1.10f;

    [[NSNotificationCenter defaultCenter] postNotificationName:UIApplicationDidReceiveMemoryWarningNotification object:nil];

    [self updateButtonStates];
    [self updateMainButtonTitle];
}

- (void)toggleMenu {
    [self triggerHaptic];
    [self resetFadeTimer];
    self.alpha = 1.0;
    
    _isExpanded = !_isExpanded;
    
    if (_isExpanded) {
        _presetPanel.hidden = NO;
    }

    [UIView animateWithDuration:0.3 delay:0 usingSpringWithDamping:0.8 initialSpringVelocity:0.5 options:UIViewAnimationOptionAllowUserInteraction animations:^{
        if (self.isExpanded) {
            self.presetPanel.alpha = 1.0;
            self.presetPanel.transform = CGAffineTransformIdentity;
        } else {
            self.presetPanel.alpha = 0.0;
            self.presetPanel.transform = CGAffineTransformMakeScale(0.8, 0.8);
        }
    } completion:^(BOOL finished) {
        if (!self.isExpanded) {
            self.presetPanel.hidden = YES;
        }
    }];
}

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    [self resetFadeTimer];
    self.alpha = 1.0;
    
    CGPoint translation = [pan translationInView:self.superview];
    self.center = CGPointMake(self.center.x + translation.x, self.center.y + translation.y);
    [pan setTranslation:CGPointZero inView:self.superview];

    if (pan.state == UIGestureRecognizerStateEnded || pan.state == UIGestureRecognizerStateCancelled) {
        UIEdgeInsets insets = UIEdgeInsetsZero;
        if (@available(iOS 11.0, *)) {
            insets = self.superview.safeAreaInsets;
        }
        
        CGFloat screenWidth = self.superview.bounds.size.width;
        CGFloat screenHeight = self.superview.bounds.size.height;
        CGFloat halfWidth = self.bounds.size.width / 2.0;
        
        CGFloat targetX = (self.center.x < screenWidth / 2.0) ? (insets.left + halfWidth + 10) : (screenWidth - insets.right - halfWidth - 10);
        CGFloat targetY = MIN(MAX(self.center.y, insets.top + halfWidth + 10), screenHeight - insets.bottom - halfWidth - 10);
        
        if (targetX > screenWidth / 2.0) {
            self.presetPanel.frame = CGRectMake(-170, 2.5, 165, 45);
        } else {
            self.presetPanel.frame = CGRectMake(55, 2.5, 165, 45);
        }
        
        [UIView animateWithDuration:0.3 delay:0 usingSpringWithDamping:0.8 initialSpringVelocity:0.5 options:UIViewAnimationOptionAllowUserInteraction animations:^{
            self.center = CGPointMake(targetX, targetY);
        } completion:nil];

        [self startFadeTimer];
    }
}

- (void)resetFadeTimer {
    [_fadeTimer invalidate];
    _fadeTimer = [NSTimer scheduledTimerWithTimeInterval:3.0 target:self selector:@selector(dimMenu) userInfo:nil repeats:NO];
}

- (void)startFadeTimer {
    [self resetFadeTimer];
}

- (void)dimMenu {
    set_speed_factor(self.currentSpeed);

    if (self.isExpanded) {
        [self toggleMenu];
    }
    
    [UIView animateWithDuration:0.5 animations:^{
        self.alpha = 0.10;
    }];
}

@end
