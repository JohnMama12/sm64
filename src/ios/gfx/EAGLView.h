//
// EAGLView.h — GLES render surface for the iPad 1 SGX535. The game renderer
// is fixed-function GLES 1.1, so the EAGL context is always ES1.
// CADisplayLink pump at 30 Hz.
//
#import <UIKit/UIKit.h>

@interface SM64EAGLView : UIView {
    id _context;
    unsigned int _framebuffer;
    unsigned int _renderbuffer;
    unsigned int _depthRenderbuffer;
    unsigned int _gameFramebuffer;
    unsigned int _gameColorTexture;
    unsigned int _gameDepthRenderbuffer;
    int _backingWidth;
    int _backingHeight;
    int _gameWidth;
    int _gameHeight;
    int _allocatedGameWidth;
    int _allocatedGameHeight;
    CGFloat _renderScale;
    CGFloat _initialRenderScale;
    NSInteger _renderResolutionIndex;
    BOOL _linearFiltering;
    BOOL _gameFramebufferReady;
    BOOL _useGLES1;
    BOOL _framebufferReady;
    int _loggedFbW;
    int _loggedFbH;
    CADisplayLink *_displayLink;
    unsigned long _frameCount;
    BOOL _loggedFirstGameFrame;
    BOOL _gameMode;
    void (*_gameFrameFn)(void);
    NSInteger _frameInterval;
    double _lastFrameStart;
    double _fpsWindowStart;
    unsigned int _fpsWindowFrames;
    double _framesPerSecond;
    double _frameIntervalMilliseconds;
    double _frameIntervals[60];
    unsigned int _frameIntervalIndex;
    unsigned int _frameIntervalCount;
    double _cpuUsagePercent;
    double _lastCpuTime;
    double _lastCpuSampleTime;
    unsigned long long _residentMemoryBytes;
}
- (BOOL)createContext;
- (void)setupFramebuffer;
- (void)startPump;
- (void)stopPump;
- (void)renderFrame;
- (unsigned long)frameCount;
- (CGFloat)renderScale;
- (NSInteger)renderResolutionIndex;
- (NSInteger)renderResolutionCount;
- (void)getResolutionWidth:(int *)width height:(int *)height
    atIndex:(NSInteger)index;
- (BOOL)linearFiltering;
- (NSInteger)frameInterval;
- (BOOL)setRenderScale:(CGFloat)scale linearFiltering:(BOOL)linear;
- (BOOL)setRenderResolutionIndex:(NSInteger)index linearFiltering:(BOOL)linear;
- (void)setFrameInterval:(NSInteger)frameInterval;
- (double)framesPerSecond;
- (double)frameIntervalMilliseconds;
- (double)cpuUsagePercent;
- (unsigned long long)residentMemoryBytes;
- (void)refreshPerformanceMetrics;
- (void)copyFrameIntervals:(double *)values count:(NSUInteger)count;
- (void)getLogicalWidth:(int *)w height:(int *)h;
- (void)getRenderWidth:(int *)w height:(int *)h;
// Game mode: the display-link tick calls gameFrameFn (produce_one_frame)
// instead of clearing; the game stack presents via presentFramebuffer.
- (void)setGameMode:(BOOL)game frameFn:(void (*)(void))fn;
- (void)makeCurrent;
- (void)presentFramebuffer;
- (void)maybeDumpFramebuffer;
- (void)getBackingWidth:(int *)w height:(int *)h;
@end

// C bridge used by the GfxWindowManagerAPI implementation (gfx_ios_wm.m).
#ifdef __cplusplus
extern "C" {
#endif
void ios_bridge_register_view(SM64EAGLView *view);
void ios_bridge_present(void);
void ios_bridge_make_current(void);
void ios_bridge_get_dimensions(unsigned int *w, unsigned int *h);
float ios_bridge_get_render_scale(void);
float ios_bridge_get_render_scale_y(void);
void ios_bridge_set_frame_fn(void (*fn)(void));
#ifdef __cplusplus
}
#endif
