//
// EAGLView.m — CAEAGLLayer + EAGLContext. The game renderer is
// fixed-function GLES 1.1 (SGX535); ES2 contexts reject those calls, so the
// context is always ES1. Framebuffer/renderbuffer setup has to wait until
// the layer is on screen (the drawable doesn't exist before that), so it is
// attempted from createContext and retried from layoutSubviews.
// Pre-ROM renders a clear color; in game mode the display-link tick calls
// into produce_one_frame (Fast3D executor → gfx_ios_gles1.c).
//
#import "EAGLView.h"
#import <QuartzCore/QuartzCore.h>
#import <OpenGLES/EAGL.h>
#import <OpenGLES/ES1/gl.h>
#import <OpenGLES/ES1/glext.h>
#import <OpenGLES/ES2/gl.h>
#import <OpenGLES/ES2/glext.h>
#import <limits.h>
#import <math.h>
#import <stdlib.h>
#import <stdio.h>
#import <mach/mach.h>
#import <mach/task_info.h>
#import <sys/resource.h>

extern void ios_gfx_renderer_restore_state(void);

static double usageTimevalSeconds(struct timeval value) {
    return (double)value.tv_sec + (double)value.tv_usec / 1000000.0;
}

@implementation SM64EAGLView

+ (Class)layerClass {
    return [CAEAGLLayer class];
}

- (id)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _renderScale = 1.0;
        _initialRenderScale = 1.0;
        _renderResolutionIndex = -1;
        _frameInterval = 2;
        _fpsWindowStart = CACurrentMediaTime();
    }
    return self;
}

- (BOOL)createContext {
    // The game renderer (gfx_ios_gles1.c) is fixed-function GLES 1.1, the
    // only rendering path this port has. The SGX535 also supports ES2, but
    // an ES2 context rejects every fixed-function call, so always use ES1
    // (the pre-ROM demo render path below works on the same context type).
    EAGLContext *ctx = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES1];
    _useGLES1 = YES;
    if (ctx == nil) {
        [self writeHeartbeatLine:@"eagl: ES1 context creation FAILED\n"];
        return NO;
    }
    _context = ctx;

    CAEAGLLayer *layer = (CAEAGLLayer *)self.layer;
    self.contentScaleFactor = [[UIScreen mainScreen] scale];
    layer.contentsScale = self.contentScaleFactor;
    layer.opaque = YES;
    layer.drawableProperties = [NSDictionary dictionaryWithObjectsAndKeys:
        [NSNumber numberWithBool:NO], kEAGLDrawablePropertyRetainedBacking,
        kEAGLColorFormatRGB565, kEAGLDrawablePropertyColorFormat, nil];

    // May fail here if the view is not on screen yet; layoutSubviews retries.
    [self setupFramebuffer];
    return YES;
}

- (BOOL)setupGameFramebuffer {
    if (!_framebufferReady || _backingWidth <= 0 || _backingHeight <= 0) {
        return NO;
    }

    if (_renderResolutionIndex < 0) {
        CGFloat deviceScale = MAX(1.0, self.contentScaleFactor);
        int initialWidth = MAX(1, (int)round(
            (double)_backingWidth * _initialRenderScale / deviceScale));
        int initialHeight = MAX(1, (int)round(
            (double)_backingHeight * _initialRenderScale / deviceScale));
        NSInteger nearestIndex = 0;
        unsigned long long nearestDistance = ULLONG_MAX;
        NSInteger count = [self renderResolutionCount];
        for (NSInteger i = 0; i < count; i++) {
            int candidateWidth = 0;
            int candidateHeight = 0;
            [self getResolutionWidth:&candidateWidth height:&candidateHeight
                atIndex:i];
            long long dx = (long long)candidateWidth - initialWidth;
            long long dy = (long long)candidateHeight - initialHeight;
            unsigned long long distance = (unsigned long long)(dx * dx + dy * dy);
            if (distance < nearestDistance) {
                nearestDistance = distance;
                nearestIndex = i;
            }
        }
        _renderResolutionIndex = nearestIndex;
    }
    _renderResolutionIndex = MIN(_renderResolutionIndex,
        [self renderResolutionCount] - 1);

    int width = 0;
    int height = 0;
    [self getResolutionWidth:&width height:&height
        atIndex:_renderResolutionIndex];
    _renderScale = _backingWidth > 0
        ? (CGFloat)width / (CGFloat)_backingWidth : 1.0;
    _gameWidth = width;
    _gameHeight = height;
    if (width == _backingWidth && height == _backingHeight) {
        _gameFramebufferReady = NO;
        if (_gameFramebuffer != 0) {
            glDeleteFramebuffersOES(1, &_gameFramebuffer);
            _gameFramebuffer = 0;
        }
        if (_gameColorTexture != 0) {
            glDeleteTextures(1, &_gameColorTexture);
            _gameColorTexture = 0;
        }
        if (_gameDepthRenderbuffer != 0) {
            glDeleteRenderbuffersOES(1, &_gameDepthRenderbuffer);
            _gameDepthRenderbuffer = 0;
        }
        _allocatedGameWidth = 0;
        _allocatedGameHeight = 0;
        if (_gameMode) ios_gfx_renderer_restore_state();
        return YES;
    }

    BOOL dimensionsChanged = width != _allocatedGameWidth ||
        height != _allocatedGameHeight;
    if (_gameFramebuffer == 0) glGenFramebuffersOES(1, &_gameFramebuffer);
    if (_gameColorTexture == 0) glGenTextures(1, &_gameColorTexture);
    if (_gameDepthRenderbuffer == 0) {
        glGenRenderbuffersOES(1, &_gameDepthRenderbuffer);
    }

    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, _gameColorTexture);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER,
        _linearFiltering ? GL_LINEAR : GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER,
        _linearFiltering ? GL_LINEAR : GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    if (dimensionsChanged || !_gameFramebufferReady) {
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGB, width, height, 0,
            GL_RGB, GL_UNSIGNED_SHORT_5_6_5, NULL);
    }

    glBindFramebufferOES(GL_FRAMEBUFFER_OES, _gameFramebuffer);
    glFramebufferTexture2DOES(GL_FRAMEBUFFER_OES, GL_COLOR_ATTACHMENT0_OES,
        GL_TEXTURE_2D, _gameColorTexture, 0);
    glBindRenderbufferOES(GL_RENDERBUFFER_OES, _gameDepthRenderbuffer);
    if (dimensionsChanged || !_gameFramebufferReady) {
        glRenderbufferStorageOES(GL_RENDERBUFFER_OES, GL_DEPTH_COMPONENT16_OES,
            width, height);
    }
    glFramebufferRenderbufferOES(GL_FRAMEBUFFER_OES, GL_DEPTH_ATTACHMENT_OES,
        GL_RENDERBUFFER_OES, _gameDepthRenderbuffer);

    _allocatedGameWidth = width;
    _allocatedGameHeight = height;
    GLenum status = glCheckFramebufferStatusOES(GL_FRAMEBUFFER_OES);
    _gameFramebufferReady = status == GL_FRAMEBUFFER_COMPLETE_OES;
    glBindTexture(GL_TEXTURE_2D, 0);
    if (!_gameFramebufferReady) {
        [self writeHeartbeatLine:[NSString stringWithFormat:
            @"eagl: scaled framebuffer unavailable 0x%x (%dx%d)\n",
            (unsigned)status, _gameWidth, _gameHeight]];
    } else {
        glViewport(0, 0, _gameWidth, _gameHeight);
    }
    if (_gameMode) ios_gfx_renderer_restore_state();
    return _gameFramebufferReady;
}

- (void)setupFramebuffer {
    if (_context == nil) return;
    [EAGLContext setCurrentContext:_context];
    if (_framebuffer == 0) glGenFramebuffersOES(1, &_framebuffer);
    if (_renderbuffer == 0) glGenRenderbuffersOES(1, &_renderbuffer);
    if (_depthRenderbuffer == 0) glGenRenderbuffersOES(1, &_depthRenderbuffer);
    glBindFramebufferOES(GL_FRAMEBUFFER_OES, _framebuffer);
    glBindRenderbufferOES(GL_RENDERBUFFER_OES, _renderbuffer);
    [_context renderbufferStorage:GL_RENDERBUFFER_OES fromDrawable:(CAEAGLLayer *)self.layer];
    glGetRenderbufferParameterivOES(GL_RENDERBUFFER_OES,
        GL_RENDERBUFFER_WIDTH_OES, &_backingWidth);
    glGetRenderbufferParameterivOES(GL_RENDERBUFFER_OES,
        GL_RENDERBUFFER_HEIGHT_OES, &_backingHeight);
    // The game renderer depth-tests everything and clears the depth buffer
    // each frame (gfx_opengl_start_frame), and its fog / two-texture
    // second passes draw the same triangles again counting on the depth
    // test to confine them. EAGL has no default depth buffer, so one must
    // be allocated and attached explicitly here, or nothing composites
    // correctly (no depth buffering, multi-pass overdraw).
    glBindRenderbufferOES(GL_RENDERBUFFER_OES, _depthRenderbuffer);
    glRenderbufferStorageOES(GL_RENDERBUFFER_OES, GL_DEPTH_COMPONENT16_OES,
        _backingWidth, _backingHeight);
    // The color attachment must be explicitly connected; without this the
    // framebuffer can never be GL_FRAMEBUFFER_COMPLETE_OES.
    glFramebufferRenderbufferOES(GL_FRAMEBUFFER_OES, GL_COLOR_ATTACHMENT0_OES,
        GL_RENDERBUFFER_OES, _renderbuffer);
    glFramebufferRenderbufferOES(GL_FRAMEBUFFER_OES, GL_DEPTH_ATTACHMENT_OES,
        GL_RENDERBUFFER_OES, _depthRenderbuffer);
    GLenum status = glCheckFramebufferStatusOES(GL_FRAMEBUFFER_OES);
    if (status != GL_FRAMEBUFFER_COMPLETE_OES) {
        if (_framebufferReady) {
            [self writeHeartbeatLine:[NSString stringWithFormat:
                @"eagl: framebuffer lost 0x%x (%dx%d)\n",
                (unsigned)status, _backingWidth, _backingHeight]];
        }
        _framebufferReady = NO;
        return;
    }
    _framebufferReady = YES;
    glViewport(0, 0, _backingWidth, _backingHeight);
    if (![self setupGameFramebuffer]) {
        _renderResolutionIndex = 0;
        _renderScale = 1.0;
        _gameWidth = _backingWidth;
        _gameHeight = _backingHeight;
    }
    glBindFramebufferOES(GL_FRAMEBUFFER_OES, _framebuffer);
    glBindRenderbufferOES(GL_RENDERBUFFER_OES, _renderbuffer);
    glViewport(0, 0, _backingWidth, _backingHeight);
    if (!_loggedFbW || _loggedFbW != _backingWidth || _loggedFbH != _backingHeight) {
        _loggedFbW = _backingWidth;
        _loggedFbH = _backingHeight;
        [self writeHeartbeatLine:[NSString stringWithFormat:
            @"eagl: framebuffer ready %dx%d color+depth\n",
            _backingWidth, _backingHeight]];
    }
}

- (void)startPump {
    [self stopPump];
    _displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(renderFrame)];
    _displayLink.frameInterval = _frameInterval;
    [_displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSDefaultRunLoopMode];
}

- (void)stopPump {
    [_displayLink invalidate];
    _displayLink = nil;
}

- (void)writeHeartbeatLine:(NSString *)line {
    // Append a line to Documents/sm64ios-heartbeat.log (readable via SSH).
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    if ([paths count] == 0) return;
    NSString *log = [[paths objectAtIndex:0] stringByAppendingPathComponent:@"sm64ios-heartbeat.log"];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:log];
    if (fh == nil) {
        [line writeToFile:log atomically:YES encoding:NSUTF8StringEncoding error:nil];
    } else {
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    }
}

- (void)renderFrame {
    if (_context == nil) return;
    if (!_framebufferReady) return; // layoutSubviews sets it up once on screen
    if (_gameMode && _gameFrameFn != NULL) {
        if (!_loggedFirstGameFrame) {
            _loggedFirstGameFrame = YES;
            [self writeHeartbeatLine:@"game mode: entering game frame 1\n"];
        }
        double now = CACurrentMediaTime();
        if (_lastFrameStart > 0.0 && now > _lastFrameStart) {
            _frameIntervalMilliseconds = (now - _lastFrameStart) * 1000.0;
            _frameIntervals[_frameIntervalIndex] = _frameIntervalMilliseconds;
            _frameIntervalIndex = (_frameIntervalIndex + 1) % 60;
            if (_frameIntervalCount < 60) _frameIntervalCount++;
        }
        _lastFrameStart = now;
        _fpsWindowFrames++;
        if (now - _fpsWindowStart >= 1.0) {
            _framesPerSecond = (double)_fpsWindowFrames / (now - _fpsWindowStart);
            _fpsWindowFrames = 0;
            _fpsWindowStart = now;
        }
        _gameFrameFn();
        _frameCount++;
        return;
    }
    [EAGLContext setCurrentContext:_context];
    glBindFramebufferOES(GL_FRAMEBUFFER_OES, _framebuffer);
    glViewport(0, 0, _backingWidth, _backingHeight);
    glClearColor(0.05f, 0.05f, 0.12f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT);
    glBindRenderbufferOES(GL_RENDERBUFFER_OES, _renderbuffer);
    [_context presentRenderbuffer:GL_RENDERBUFFER_OES];
    _frameCount++;
}

- (unsigned long)frameCount {
    return _frameCount;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    // The CAEAGLLayer only has a drawable once the view is on screen, so
    // (re)create the framebuffer/renderbuffer here (idempotent; also handles
    // resize by re-allocating storage and re-attaching the color buffer).
    [self setupFramebuffer];
}

- (void)setGameMode:(BOOL)game frameFn:(void (*)(void))fn {
    _gameMode = game;
    _gameFrameFn = fn;
    if (game) {
        _lastFrameStart = 0.0;
        _fpsWindowStart = CACurrentMediaTime();
        _fpsWindowFrames = 0;
        _framesPerSecond = 0.0;
    }
}

- (CGFloat)renderScale { return _renderScale; }
- (NSInteger)renderResolutionIndex {
    return MAX(0, _renderResolutionIndex);
}
- (NSInteger)renderResolutionCount {
    int width = _backingWidth;
    int height = _backingHeight;
    if (width <= 0 || height <= 0) return 1;

    NSInteger count = 1;
    while (width / 2 >= 320 && height / 2 >= 240) {
        width = (width + 1) / 2;
        height = (height + 1) / 2;
        count++;
    }
    int minimumWidth = _backingHeight > 0
        ? MAX(1, (int)round(240.0 * (double)_backingWidth / _backingHeight))
        : 320;
    if (_backingWidth >= minimumWidth && _backingHeight >= 240 &&
            (width != minimumWidth || height != 240)) {
        count++;
    }
    return count;
}

- (void)getResolutionWidth:(int *)width height:(int *)height
    atIndex:(NSInteger)index {
    int resolutionWidth = _backingWidth;
    int resolutionHeight = _backingHeight;
    NSInteger count = [self renderResolutionCount];
    index = MIN(MAX(0, index), count - 1);
    for (NSInteger i = 0; i < index; i++) {
        if (resolutionWidth / 2 >= 320 && resolutionHeight / 2 >= 240) {
            resolutionWidth = (resolutionWidth + 1) / 2;
            resolutionHeight = (resolutionHeight + 1) / 2;
        } else {
            resolutionWidth = MAX(1, (int)round(
                240.0 * (double)_backingWidth / _backingHeight));
            resolutionHeight = 240;
        }
    }
    if (width) *width = resolutionWidth;
    if (height) *height = resolutionHeight;
}

- (BOOL)linearFiltering { return _linearFiltering; }
- (NSInteger)frameInterval { return _frameInterval; }
- (double)framesPerSecond { return _framesPerSecond; }
- (double)frameIntervalMilliseconds { return _frameIntervalMilliseconds; }
- (double)cpuUsagePercent { return _cpuUsagePercent; }
- (unsigned long long)residentMemoryBytes { return _residentMemoryBytes; }

- (BOOL)setRenderScale:(CGFloat)scale linearFiltering:(BOOL)linear {
    _initialRenderScale = MAX(1.0, scale);
    if (_context == nil || !_framebufferReady) {
        _linearFiltering = linear;
        return YES;
    }
    CGFloat deviceScale = MAX(1.0, self.contentScaleFactor);
    int desiredWidth = MAX(1, (int)round(
        (double)_backingWidth * _initialRenderScale / deviceScale));
    int desiredHeight = MAX(1, (int)round(
        (double)_backingHeight * _initialRenderScale / deviceScale));
    NSInteger nearestIndex = 0;
    unsigned long long nearestDistance = ULLONG_MAX;
    NSInteger count = [self renderResolutionCount];
    for (NSInteger i = 0; i < count; i++) {
        int candidateWidth = 0;
        int candidateHeight = 0;
        [self getResolutionWidth:&candidateWidth height:&candidateHeight
            atIndex:i];
        long long dx = (long long)candidateWidth - desiredWidth;
        long long dy = (long long)candidateHeight - desiredHeight;
        unsigned long long distance = (unsigned long long)(dx * dx + dy * dy);
        if (distance < nearestDistance) {
            nearestDistance = distance;
            nearestIndex = i;
        }
    }
    return [self setRenderResolutionIndex:nearestIndex
        linearFiltering:linear];
}

- (BOOL)setRenderResolutionIndex:(NSInteger)index
    linearFiltering:(BOOL)linear {
    NSInteger previousIndex = _renderResolutionIndex;
    BOOL previousFiltering = _linearFiltering;
    if (_backingWidth <= 0 || _backingHeight <= 0) {
        _renderResolutionIndex = MAX(0, index);
        _linearFiltering = linear;
        return YES;
    }
    NSInteger count = [self renderResolutionCount];
    _renderResolutionIndex = MIN(MAX(0, index), count - 1);
    _linearFiltering = linear;
    if (_context == nil || !_framebufferReady) return YES;
    [EAGLContext setCurrentContext:_context];
    BOOL ready = [self setupGameFramebuffer];
    if (!ready) {
        _renderResolutionIndex = previousIndex;
        _linearFiltering = previousFiltering;
        if (![self setupGameFramebuffer]) {
            _renderResolutionIndex = 0;
            [self setupGameFramebuffer];
        }
    }
    glBindFramebufferOES(GL_FRAMEBUFFER_OES,
        _gameFramebufferReady ? _gameFramebuffer : _framebuffer);
    glViewport(0, 0, _gameFramebufferReady ? _gameWidth : _backingWidth,
        _gameFramebufferReady ? _gameHeight : _backingHeight);
    return ready;
}

- (void)setFrameInterval:(NSInteger)frameInterval {
    _frameInterval = frameInterval >= 3 ? 3 : 2;
    _displayLink.frameInterval = _frameInterval;
}

- (void)refreshPerformanceMetrics {
    struct rusage usage;
    double now = CACurrentMediaTime();
    if (getrusage(RUSAGE_SELF, &usage) == 0) {
        double cpuTime = usageTimevalSeconds(usage.ru_utime) +
            usageTimevalSeconds(usage.ru_stime);
        if (_lastCpuSampleTime > 0.0 && now > _lastCpuSampleTime) {
            _cpuUsagePercent = MAX(0.0, MIN(100.0,
                (cpuTime - _lastCpuTime) / (now - _lastCpuSampleTime) * 100.0));
        }
        _lastCpuTime = cpuTime;
        _lastCpuSampleTime = now;
    }

    struct mach_task_basic_info info;
    mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
    if (task_info(mach_task_self(), MACH_TASK_BASIC_INFO,
            (task_info_t)&info, &count) == KERN_SUCCESS) {
        _residentMemoryBytes = (unsigned long long)info.resident_size;
    }
}

- (void)copyFrameIntervals:(double *)values count:(NSUInteger)count {
    if (values == NULL || count == 0) return;
    NSUInteger copied = MIN(MIN(count, (NSUInteger)_frameIntervalCount),
        (NSUInteger)60);
    NSUInteger start = (_frameIntervalIndex + 60 - copied) % 60;
    for (NSUInteger i = 0; i < copied; i++) {
        values[i] = _frameIntervals[(start + i) % 60];
    }
    for (NSUInteger i = copied; i < count; i++) values[i] = 0.0;
}

- (void)makeCurrent {
    if (_context != nil) {
        [EAGLContext setCurrentContext:_context];
        glBindFramebufferOES(GL_FRAMEBUFFER_OES,
            _gameFramebufferReady ? _gameFramebuffer : _framebuffer);
        glViewport(0, 0, _gameFramebufferReady ? _gameWidth : _backingWidth,
            _gameFramebufferReady ? _gameHeight : _backingHeight);
    }
}

- (void)presentFramebuffer {
    if (_context == nil) return;
    [EAGLContext setCurrentContext:_context];
    glBindFramebufferOES(GL_FRAMEBUFFER_OES, _framebuffer);
    if (_gameFramebufferReady) {
        static const GLfloat vertices[] = {
            -1.f, -1.f, 1.f, -1.f, -1.f, 1.f, 1.f, 1.f
        };
        static const GLfloat texCoords[] = {
            0.f, 0.f, 1.f, 0.f, 0.f, 1.f, 1.f, 1.f
        };
        glViewport(0, 0, _backingWidth, _backingHeight);
        glDisable(GL_SCISSOR_TEST);
        glDisable(GL_DEPTH_TEST);
        glDisable(GL_CULL_FACE);
        glDisable(GL_BLEND);
        glDisable(GL_ALPHA_TEST);
        glDepthMask(GL_TRUE);
        glColor4f(1.f, 1.f, 1.f, 1.f);
        glMatrixMode(GL_PROJECTION);
        glPushMatrix();
        glLoadIdentity();
        glMatrixMode(GL_MODELVIEW);
        glPushMatrix();
        glLoadIdentity();
        glActiveTexture(GL_TEXTURE0);
        glEnable(GL_TEXTURE_2D);
        glBindTexture(GL_TEXTURE_2D, _gameColorTexture);
        glTexEnvi(GL_TEXTURE_ENV, GL_TEXTURE_ENV_MODE, GL_REPLACE);
        glEnableClientState(GL_VERTEX_ARRAY);
        glEnableClientState(GL_TEXTURE_COORD_ARRAY);
        glDisableClientState(GL_COLOR_ARRAY);
        glVertexPointer(2, GL_FLOAT, 0, vertices);
        glTexCoordPointer(2, GL_FLOAT, 0, texCoords);
        glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
        glDisableClientState(GL_TEXTURE_COORD_ARRAY);
        glDisable(GL_TEXTURE_2D);
        glMatrixMode(GL_MODELVIEW);
        glPopMatrix();
        glMatrixMode(GL_PROJECTION);
        glPopMatrix();
        glMatrixMode(GL_MODELVIEW);
        ios_gfx_renderer_restore_state();
    }
    glBindRenderbufferOES(GL_RENDERBUFFER_OES, _renderbuffer);
    [_context presentRenderbuffer:GL_RENDERBUFFER_OES];
    if (_gameFramebufferReady) {
        glBindFramebufferOES(GL_FRAMEBUFFER_OES, _gameFramebuffer);
        glViewport(0, 0, _gameWidth, _gameHeight);
    }
}

// Debug aid (flag-file gated): when Documents/ios_framedump.flag exists, write
// the current framebuffer as raw top-down RGBA to Documents/framedump.raw so a
// dev machine can fetch it over SFTP and convert it to PNG. Creating the flag
// costs nothing on normal runs.
- (void)maybeDumpFramebuffer {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    if ([paths count] == 0) return;
    NSString *dir = [paths objectAtIndex:0];
    NSString *flag = [dir stringByAppendingPathComponent:@"ios_framedump.flag"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:flag]) return;
    int w = _backingWidth, h = _backingHeight;
    if (w <= 0 || h <= 0) return;
    unsigned char *px = (unsigned char *)malloc((size_t)w * (size_t)h * 4);
    if (px == NULL) return;
    glReadPixels(0, 0, w, h, GL_RGBA, GL_UNSIGNED_BYTE, px);
    NSString *out = [dir stringByAppendingPathComponent:@"framedump.raw"];
    FILE *f = fopen([out fileSystemRepresentation], "wb");
    if (f != NULL) {
        int y;
        for (y = h - 1; y >= 0; y--) { // GL rows are bottom-up; write top-down
            fwrite(px + (size_t)y * (size_t)w * 4, 1, (size_t)w * 4, f);
        }
        fclose(f);
        [self writeHeartbeatLine:[NSString stringWithFormat:
            @"framedump %dx%d frame=%lu\n", w, h, _frameCount]];
    }
    free(px);
}

- (void)getBackingWidth:(int *)w height:(int *)h {
    if (w) *w = _backingWidth;
    if (h) *h = _backingHeight;
}

- (void)getLogicalWidth:(int *)w height:(int *)h {
    CGFloat scale = MAX(1.0, self.contentScaleFactor);
    if (w) *w = MAX(1, (int)round((double)_backingWidth / scale));
    if (h) *h = MAX(1, (int)round((double)_backingHeight / scale));
}

- (void)getRenderWidth:(int *)w height:(int *)h {
    if (w) *w = _gameFramebufferReady ? _gameWidth : _backingWidth;
    if (h) *h = _gameFramebufferReady ? _gameHeight : _backingHeight;
}

static SM64EAGLView *sRegisteredView = nil;

void ios_bridge_register_view(SM64EAGLView *view) {
    sRegisteredView = view;
}

void ios_bridge_present(void) {
    [sRegisteredView presentFramebuffer];
}

void ios_bridge_make_current(void) {
    [sRegisteredView makeCurrent];
}

void ios_bridge_get_dimensions(unsigned int *w, unsigned int *h) {
    int bw = 0, bh = 0;
    [sRegisteredView getLogicalWidth:&bw height:&bh];
    if (w) *w = (unsigned int)bw;
    if (h) *h = (unsigned int)bh;
}

float ios_bridge_get_render_scale(void) {
    int logicalWidth = 0;
    int renderWidth = 0;
    [sRegisteredView getLogicalWidth:&logicalWidth height:NULL];
    [sRegisteredView getRenderWidth:&renderWidth height:NULL];
    return logicalWidth > 0 ? (float)renderWidth / (float)logicalWidth : 1.0f;
}

float ios_bridge_get_render_scale_y(void) {
    int logicalHeight = 0;
    int renderHeight = 0;
    [sRegisteredView getLogicalWidth:NULL height:&logicalHeight];
    [sRegisteredView getRenderWidth:NULL height:&renderHeight];
    return logicalHeight > 0 ? (float)renderHeight / (float)logicalHeight : 1.0f;
}

void ios_bridge_set_frame_fn(void (*fn)(void)) {
    [sRegisteredView setGameMode:(fn != NULL) frameFn:fn];
}

@end
