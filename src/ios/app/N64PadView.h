//
// N64PadView.h — textured, device-aware on-screen controller.
// Pre-rasterized UIImageViews keep drawing off the touch path. The camera
// control publishes the N64 R-trigger bit.
//
#import <UIKit/UIKit.h>
#import "ios_touch_state.h"

typedef struct {
    float stickX;   // -1..1
    float stickY;   // -1..1 (up positive)
    unsigned int buttons;
} IosPadState;

@interface N64PadView : UIView {
    IosPadState _state;
    CGPoint _stickCenter;
    CGFloat _stickRadius;
    int _stickTouchId;
    NSMutableDictionary *_buttonTouches;
}
- (IosPadState)padState;
- (void)publish;
// Keep the same full-opacity textures before and during gameplay.
- (void)setDemoMode:(BOOL)demo;
@end