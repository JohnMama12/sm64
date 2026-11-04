//
// N64PadView.m — the native iOS version of the controller prototype.
// Textures are loaded from the device- and density-specific app resources;
// input events only swap prebuilt button images, move the stick, and publish
// pad state.
//

#import "N64PadView.h"
#import "ios_touch_state.h"
#import <math.h>
#import <stdint.h>
#import <string.h>

typedef struct {
    unsigned int button;
    CGRect rect;
} PadButton;

#define MAX_BUTTONS 9

static CGFloat controllerDensity(void) {
    return [[UIScreen mainScreen] scale] >= 1.5 ? 2.0 : 1.0;
}

static UIImage *controllerImage(NSString *name) {
    CGFloat density = controllerDensity();
    NSString *device = UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad
        ? @"ipad" : @"iphone";
    NSString *relativePath = [NSString stringWithFormat:
        @"controller-assets/%lux/%@/%@", (unsigned long)density, device, name];
    NSString *path = [[[NSBundle mainBundle] bundlePath]
        stringByAppendingPathComponent:relativePath];
    UIImage *source = [UIImage imageWithContentsOfFile:path];
    if (source == nil || source.CGImage == nil) {
        NSLog(@"Missing controller texture: %@", path);
        return nil;
    }
    return [UIImage imageWithCGImage:source.CGImage
        scale:density orientation:UIImageOrientationUp];
}

@implementation N64PadView {
    PadButton _buttons[MAX_BUTTONS];
    int _buttonCount;
    BOOL _demoMode;
    NSMutableArray *_buttonViews;
    NSMutableArray *_buttonNormal;
    NSMutableArray *_buttonPressed;
    UIImageView *_stickBaseView;
    UIImageView *_knobView;
    CGSize _layoutSize;
    BOOL _layoutBuilt;
}

- (id)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.opaque = NO;
        self.multipleTouchEnabled = YES;
        self.alpha = 1.0;
        _stickTouchId = -1;
        _buttonTouches = [[NSMutableDictionary alloc] init];
        _buttonViews = [[NSMutableArray alloc] init];
        _buttonNormal = [[NSMutableArray alloc] init];
        _buttonPressed = [[NSMutableArray alloc] init];
        memset(&_state, 0, sizeof(_state));
        [self layoutPad:frame.size];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [self layoutPad:self.bounds.size];
}

- (void)layoutPad:(CGSize)size {
    if (_layoutBuilt && CGSizeEqualToSize(size, _layoutSize)) {
        return;
    }
    _layoutBuilt = YES;
    _layoutSize = size;

    for (UIImageView *view in _buttonViews) {
        [view removeFromSuperview];
    }
    [_buttonViews removeAllObjects];
    [_buttonNormal removeAllObjects];
    [_buttonPressed removeAllObjects];
    [_stickBaseView removeFromSuperview];
    [_knobView removeFromSuperview];

    CGFloat w = size.width;
    CGFloat h = size.height;
    BOOL ipad = UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad;
    CGFloat stickSize = w * (ipad ? 0.125 : 0.13333333);
    CGFloat stickLeft = w * (ipad ? 0.0595 : 0.064);
    CGFloat stickTop = h * (ipad ? 0.734 : 0.664);
    _stickCenter = CGPointMake(stickLeft + stickSize / 2.0,
                               stickTop + stickSize / 2.0);
    _stickRadius = stickSize * 0.23;

    _stickBaseView = [[UIImageView alloc] initWithImage:controllerImage(@"Knub.png")];
    _stickBaseView.frame = CGRectMake(stickLeft, stickTop, stickSize, stickSize);
    _stickBaseView.contentMode = UIViewContentModeScaleToFill;
    _stickBaseView.userInteractionEnabled = NO;
    [self addSubview:_stickBaseView];

    _knobView = [[UIImageView alloc] initWithImage:controllerImage(@"thumbstick.png")];
    _knobView.frame = _stickBaseView.frame;
    _knobView.contentMode = UIViewContentModeScaleToFill;
    _knobView.userInteractionEnabled = NO;
    [self addSubview:_knobView];

    CGFloat buttonSize = w * (ipad ? 0.0625 : 0.06666667);
    CGFloat zSize = w * (ipad ? 0.078125 : 0.08333333);
    CGFloat cSize = w * (ipad ? 0.046875 : 0.05);
    CGFloat cTop = h * (ipad ? 0.613 : 0.512);
    CGFloat cLeft = w * (ipad ? 0.84 : 0.845);
    CGFloat cOffset = cSize;
    CGFloat bottomRowTop = h * (ipad ? 0.86 : 0.806);
    CGFloat bTop = h * (ipad ? 0.73 : 0.67);
    CGFloat aTop = h * (ipad ? 0.82 : 0.76);

    _buttonCount = 0;
    [self addButton:IosPadButtonZ imageName:@"ButtonZ2.png"
        rect:CGRectMake(w * (ipad ? 0.083 : 0.089),
                        h * (ipad ? 0.59 : 0.49), zSize, zSize)];

    [self addButton:IosPadButtonCUp imageName:@"cUP.png"
        rect:CGRectMake(cLeft, cTop, cSize, cSize)];
    [self addButton:IosPadButtonCLeft imageName:@"cLeft.png"
        rect:CGRectMake(cLeft - cOffset, cTop + cOffset, cSize, cSize)];
    [self addButton:IosPadButtonCRight imageName:@"cRight.png"
        rect:CGRectMake(cLeft + cOffset, cTop + cOffset, cSize, cSize)];
    [self addButton:IosPadButtonCDown imageName:@"cDown.png"
        rect:CGRectMake(cLeft, cTop + cOffset * 2.0, cSize, cSize)];

    [self addButton:IosPadButtonB imageName:@"B.png"
        rect:CGRectMake(w * 0.69, bTop, buttonSize, buttonSize)];
    [self addButton:IosPadButtonA imageName:@"A.png"
        rect:CGRectMake(w * 0.77, aTop, buttonSize, buttonSize)];
    [self addButton:IosPadButtonStart imageName:@"START.png"
        rect:CGRectMake((w - buttonSize) / 2.0, bottomRowTop,
                        buttonSize, buttonSize)];
    // The prototype's camera control is the N64 R trigger.
    [self addButton:IosPadButtonR imageName:@"Camera.png"
        rect:CGRectMake(w * (ipad ? 0.66 : 0.655), bottomRowTop,
                        buttonSize, buttonSize)];

    [self positionKnob];
}

- (void)addButton:(unsigned int)button imageName:(NSString *)imageName
             rect:(CGRect)rect {
    if (_buttonCount >= MAX_BUTTONS) return;
    UIImage *image = controllerImage(imageName);
    UIImage *pressedImage = controllerImage(
        [NSString stringWithFormat:@"pressed_%@", imageName]);
    UIImageView *view = [[UIImageView alloc] initWithImage:image];
    view.frame = rect;
    view.contentMode = UIViewContentModeScaleToFill;
    view.userInteractionEnabled = NO;
    [self addSubview:view];

    _buttons[_buttonCount].button = button;
    _buttons[_buttonCount].rect = rect;
    [_buttonViews addObject:view];
    [_buttonNormal addObject:(image != nil ? image : (id)[NSNull null])];
    [_buttonPressed addObject:(pressedImage != nil ? pressedImage : (id)[NSNull null])];
    _buttonCount++;
}

- (void)setDemoMode:(BOOL)demo {
    _demoMode = demo;
    self.alpha = 1.0;
}

- (IosPadState)padState {
    return _state;
}

- (void)publish {
    ios_touch_set_state(_state.stickX, _state.stickY, _state.buttons);
}

- (int)buttonAtPoint:(CGPoint)point {
    int i;
    for (i = 0; i < _buttonCount; i++) {
        if (CGRectContainsPoint(_buttons[i].rect, point)) return i;
    }
    return -1;
}

- (void)setButtonVisual:(int)buttonIndex pressed:(BOOL)pressed {
    if (buttonIndex < 0 || buttonIndex >= _buttonCount) return;
    UIImageView *view = [_buttonViews objectAtIndex:(NSUInteger)buttonIndex];
    id pressedImage = [_buttonPressed objectAtIndex:(NSUInteger)buttonIndex];
    if (pressed && pressedImage != [NSNull null]) {
        view.image = (UIImage *)pressedImage;
    } else {
        id normalImage = [_buttonNormal objectAtIndex:(NSUInteger)buttonIndex];
        view.image = normalImage == [NSNull null] ? nil : (UIImage *)normalImage;
    }
}

- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event {
    for (UITouch *touch in touches) {
        CGPoint point = [touch locationInView:self];
        if (_stickTouchId == -1 &&
            CGRectContainsPoint(_stickBaseView.frame, point)) {
            _stickTouchId = (int)(intptr_t)touch;
            [self updateStick:point];
            continue;
        }

        int buttonIndex = [self buttonAtPoint:point];
        if (buttonIndex >= 0) {
            _state.buttons |= _buttons[buttonIndex].button;
            [_buttonTouches setObject:[NSNumber numberWithInt:buttonIndex]
                               forKey:[NSNumber numberWithInt:(int)(intptr_t)touch]];
            [self publish];
            [self setButtonVisual:buttonIndex pressed:YES];
        }
    }
}

- (void)touchesMoved:(NSSet *)touches withEvent:(UIEvent *)event {
    for (UITouch *touch in touches) {
        if ((int)(intptr_t)touch == _stickTouchId) {
            [self updateStick:[touch locationInView:self]];
        }
    }
}

- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event {
    [self releaseTouches:touches];
}

- (void)touchesCancelled:(NSSet *)touches withEvent:(UIEvent *)event {
    [self releaseTouches:touches];
}

- (void)releaseTouches:(NSSet *)touches {
    for (UITouch *touch in touches) {
        if ((int)(intptr_t)touch == _stickTouchId) {
            _stickTouchId = -1;
            _state.stickX = 0.0f;
            _state.stickY = 0.0f;
            [self positionKnob];
            continue;
        }

        NSNumber *key = [NSNumber numberWithInt:(int)(intptr_t)touch];
        NSNumber *buttonIndex = [_buttonTouches objectForKey:key];
        if (buttonIndex != nil) {
            int index = [buttonIndex intValue];
            _state.buttons &= ~_buttons[index].button;
            [_buttonTouches removeObjectForKey:key];
            [self setButtonVisual:index pressed:NO];
        }
    }
    [self publish];
}

- (void)updateStick:(CGPoint)point {
    CGFloat dx = (point.x - _stickCenter.x) / _stickRadius;
    CGFloat dy = (_stickCenter.y - point.y) / _stickRadius;
    CGFloat length = sqrt(dx * dx + dy * dy);
    if (length > 1.0) {
        dx /= length;
        dy /= length;
    }
    _state.stickX = dx;
    _state.stickY = dy;
    [self publish];
    [self positionKnob];
}

- (void)positionKnob {
    _knobView.center = CGPointMake(
        _stickCenter.x + _state.stickX * _stickRadius,
        _stickCenter.y - _state.stickY * _stickRadius);
}

@end
