#import <UIKit/UIKit.h>
#import <CoreGraphics/CoreGraphics.h>

FOUNDATION_EXPORT void set_speed_factor(float factor);
FOUNDATION_EXPORT float get_speed_factor(void);

@interface SpeedhackMenu : UIView

@property (nonatomic, strong) UIButton *mainButton;
@property (nonatomic, strong) UIView *sliderPanel;
@property (nonatomic, strong) UISlider *speedSlider;
@property (nonatomic, strong) UILabel *speedLabel;
@property (nonatomic, assign) BOOL isExpanded;
@property (nonatomic, strong) NSTimer *fadeTimer;

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
    return [UIApplication sharedApplication].keyWindow;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _isExpanded = NO;

        float currentSpeed = get_speed_factor();
        if (currentSpeed < 1.0f) currentSpeed = 1.0f;
        if (currentSpeed > 1.15f) currentSpeed = 1.15f;

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
        
        if (currentSpeed == 1.0f) {
            [_mainButton setTitle:@"⚡️" forState:UIControlStateNormal];
        } else {
            [_mainButton setTitle:[NSString stringWithFormat:@"%.2fx", currentSpeed] forState:UIControlStateNormal];
        }
        _mainButton.titleLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightBold];
        [_mainButton addTarget:self action:@selector(toggleMenu) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:_mainButton];

        // Gesture kéo thả
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
        [self addGestureRecognizer:pan];

        // 2. Bảng Slider
        _sliderPanel = [[UIView alloc] initWithFrame:CGRectMake(55, 2.5, 170, 45)];
        _sliderPanel.backgroundColor = [UIColor colorWithRed:0.12 green:0.12 blue:0.14 alpha:0.95];
        _sliderPanel.layer.cornerRadius = 12.0;
        _sliderPanel.layer.borderWidth = 1.5;
        _sliderPanel.layer.borderColor = [UIColor colorWithRed:0.1 green:0.55 blue:1.0 alpha:1.0].CGColor;
        _sliderPanel.alpha = 0.0;
        _sliderPanel.hidden = YES;

        // UISlider (Min 1.00, Max 1.15, bước 0.01)
        _speedSlider = [[UISlider alloc] initWithFrame:CGRectMake(10, 8, 105, 30)];
        _speedSlider.minimumValue = 1.0f;
        _speedSlider.maximumValue = 1.15f;
        _speedSlider.value = currentSpeed;
        _speedSlider.minimumTrackTintColor = [UIColor colorWithRed:0.1 green:0.55 blue:1.0 alpha:1.0];
        _speedSlider.maximumTrackTintColor = [UIColor darkGrayColor];
        [_speedSlider addTarget:self action:@selector(sliderValueChanged:) forControlEvents:UIControlEventValueChanged];
        [_speedSlider addTarget:self action:@selector(triggerHaptic) forControlEvents:UIControlEventTouchDown];
        [_sliderPanel addSubview:_speedSlider];

        // Label hiển thị
        _speedLabel = [[UILabel alloc] initWithFrame:CGRectMake(120, 8, 42, 30)];
        _speedLabel.text = [NSString stringWithFormat:@"%.2fx", currentSpeed];
        _speedLabel.textColor = [UIColor whiteColor];
        _speedLabel.font = [UIFont boldSystemFontOfSize:12];
        _speedLabel.textAlignment = NSTextAlignmentCenter;
        [_sliderPanel addSubview:_speedLabel];

        [self addSubview:_sliderPanel];

        self.alpha = 0.10;
    }
    return self;
}

// Pass-through HitTest
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (self.hidden || self.alpha < 0.01) return nil;

    CGPoint mainPoint = [self convertPoint:point toView:self.mainButton];
    if ([self.mainButton pointInside:mainPoint withEvent:event]) {
        return self.mainButton;
    }

    if (self.isExpanded) {
        CGPoint panelPoint = [self convertPoint:point toView:self.sliderPanel];
        if ([self.sliderPanel pointInside:panelPoint withEvent:event]) {
            return [self.sliderPanel hitTest:panelPoint withEvent:event];
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

// Bật / Tắt Bảng Slider
- (void)toggleMenu {
    [self triggerHaptic];
    [self resetFadeTimer];
    self.alpha = 1.0;
    
    _isExpanded = !_isExpanded;
    
    if (_isExpanded) {
        _sliderPanel.hidden = NO;
    }

    [UIView animateWithDuration:0.3 delay:0 usingSpringWithDamping:0.8 initialSpringVelocity:0.5 options:UIViewAnimationOptionAllowUserInteraction animations:^{
        if (self.isExpanded) {
            self.sliderPanel.alpha = 1.0;
            self.sliderPanel.transform = CGAffineTransformIdentity;
        } else {
            self.sliderPanel.alpha = 0.0;
            self.sliderPanel.transform = CGAffineTransformMakeScale(0.8, 0.8);
        }
    } completion:^(BOOL finished) {
        if (!self.isExpanded) {
            self.sliderPanel.hidden = YES;
        }
    }];
}

// Kéo Slider (Bước nhảy 0.01 - Từng 1%)
- (void)sliderValueChanged:(UISlider *)sender {
    [self resetFadeTimer];
    self.alpha = 1.0;
    
    float step = 0.01f;
    float newStep = roundf(sender.value / step) * step;
    if (newStep < 1.0f) newStep = 1.0f;
    if (newStep > 1.15f) newStep = 1.15f;
    
    [sender setValue:newStep animated:NO];
    self.speedLabel.text = [NSString stringWithFormat:@"%.2fx", newStep];
    
    if (newStep == 1.0f) {
        [_mainButton setTitle:@"⚡️" forState:UIControlStateNormal];
    } else {
        [_mainButton setTitle:[NSString stringWithFormat:@"%.2fx", newStep] forState:UIControlStateNormal];
    }
    
    set_speed_factor(newStep);
}

// Kéo thả & Snap lề màn hình
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
            self.sliderPanel.frame = CGRectMake(-175, 2.5, 170, 45);
        } else {
            self.sliderPanel.frame = CGRectMake(55, 2.5, 170, 45);
        }
        
        [UIView animateWithDuration:0.3 delay:0 usingSpringWithDamping:0.8 initialSpringVelocity:0.5 options:UIViewAnimationOptionAllowUserInteraction animations:^{
            self.center = CGPointMake(targetX, targetY);
        } completion:nil];

        [self startFadeTimer];
    }
}

// Tự động làm mờ xuống 10%
- (void)resetFadeTimer {
    [_fadeTimer invalidate];
    _fadeTimer = [NSTimer scheduledTimerWithTimeInterval:3.0 target:self selector:@selector(dimMenu) userInfo:nil repeats:NO];
}

- (void)startFadeTimer {
    [self resetFadeTimer];
}

- (void)dimMenu {
    if (self.isExpanded) {
        [self toggleMenu];
    }
    [UIView animateWithDuration:0.5 animations:^{
        self.alpha = 0.10;
    }];
}

@end
