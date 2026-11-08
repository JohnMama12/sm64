//
// SM64AppDelegate.m — boots straight into the emulator shell:
// EAGL surface + on-screen N64 pad + ROM status. No ROM required.
// When a known-good ROM appears in Documents (iTunes File Sharing),
// the status flips and the game core takes over the pump.
//
#import "SM64AppDelegate.h"
#import "ROMValidator.h"
#import "N64PadView.h"
#import "../gfx/EAGLView.h"
#import "ios_game.h"
#import <unistd.h>
#import <QuartzCore/QuartzCore.h>
#import <string.h>
#import <math.h>

@interface SM64LagGraphView : UIView {
    double _samples[30];
    NSUInteger _sampleCount;
    double _thresholdMilliseconds;
}
- (void)setSamples:(const double *)samples count:(NSUInteger)count
    thresholdMilliseconds:(double)threshold;
@end

@implementation SM64LagGraphView

- (void)setSamples:(const double *)samples count:(NSUInteger)count
    thresholdMilliseconds:(double)threshold {
    _sampleCount = MIN(count, 30);
    _thresholdMilliseconds = threshold;
    if (_sampleCount > 0) {
        memcpy(_samples, samples + count - _sampleCount,
            _sampleCount * sizeof(double));
    }
    [self setNeedsDisplay];
}

- (void)drawRect:(CGRect)rect {
    (void)rect;
    CGContextRef context = UIGraphicsGetCurrentContext();
    CGContextSetStrokeColorWithColor(context,
        [[UIColor colorWithWhite:1.0 alpha:0.22] CGColor]);
    CGContextSetLineWidth(context, 1.0);
    CGContextMoveToPoint(context, 0, self.bounds.size.height - 1);
    CGContextAddLineToPoint(context, self.bounds.size.width,
        self.bounds.size.height - 1);
    CGContextStrokePath(context);

    if (_sampleCount == 0) return;
    CGFloat barWidth = self.bounds.size.width / (CGFloat)_sampleCount;
    for (NSUInteger i = 0; i < _sampleCount; i++) {
        double milliseconds = _samples[i];
        CGFloat height = (CGFloat)MIN(1.0, milliseconds / 100.0)
            * (self.bounds.size.height - 2.0);
        UIColor *color = milliseconds > _thresholdMilliseconds
            ? [UIColor colorWithRed:1.0 green:0.25 blue:0.2 alpha:0.9]
            : [UIColor colorWithRed:0.35 green:0.85 blue:0.55 alpha:0.8];
        CGContextSetFillColorWithColor(context, [color CGColor]);
        CGContextFillRect(context, CGRectMake(
            i * barWidth, self.bounds.size.height - height,
            MAX(1.0, barWidth - 1.0), height));
    }
}

@end

@interface SM64PerformanceOverlay : UIView {
    UILabel *_metricsLabel;
    UILabel *_graphTitleLabel;
    SM64LagGraphView *_graphView;
    NSInteger _mode;
}
- (void)setMode:(NSInteger)mode;
- (void)updateFPS:(double)fps cpu:(double)cpu frameMilliseconds:(double)frameMs
    targetFrameMilliseconds:(double)targetFrameMs
    memory:(unsigned long long)memory frameIntervals:(const double *)intervals
    count:(NSUInteger)count;
@end

@implementation SM64PerformanceOverlay

- (id)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor colorWithWhite:0 alpha:0.7];
        self.layer.cornerRadius = 4.0;
        self.userInteractionEnabled = NO;
        _metricsLabel = [[UILabel alloc] initWithFrame:CGRectMake(6, 2,
            frame.size.width - 12, 22)];
        _metricsLabel.backgroundColor = [UIColor clearColor];
        _metricsLabel.textColor = [UIColor whiteColor];
        _metricsLabel.font = [UIFont boldSystemFontOfSize:11];
        [self addSubview:_metricsLabel];
        _graphTitleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _graphTitleLabel.backgroundColor = [UIColor clearColor];
        _graphTitleLabel.textColor = [UIColor colorWithWhite:0.72 alpha:1];
        _graphTitleLabel.font = [UIFont systemFontOfSize:8];
        _graphTitleLabel.text = @"FRAME INTERVAL (MS)";
        [self addSubview:_graphTitleLabel];
        _graphView = [[SM64LagGraphView alloc] initWithFrame:CGRectZero];
        _graphView.backgroundColor = [UIColor clearColor];
        [self addSubview:_graphView];
    }
    return self;
}

- (void)setMode:(NSInteger)mode {
    _mode = MIN(MAX(mode, 0), 2);
    self.hidden = (_mode == 0);
    _metricsLabel.numberOfLines = _mode == 2 ? 2 : 1;
    _metricsLabel.frame = CGRectMake(6, 2, self.bounds.size.width - 12,
        _mode == 2 ? 36 : 22);
    _graphTitleLabel.hidden = (_mode != 2);
    _graphTitleLabel.frame = CGRectMake(6, 38, self.bounds.size.width - 12, 10);
    _graphView.hidden = (_mode != 2);
    _graphView.frame = CGRectMake(6, 49, self.bounds.size.width - 12, 30);
    self.frame = CGRectMake(self.frame.origin.x, self.frame.origin.y,
        self.frame.size.width, _mode == 2 ? 84 : 26);
}

- (void)updateFPS:(double)fps cpu:(double)cpu frameMilliseconds:(double)frameMs
    targetFrameMilliseconds:(double)targetFrameMs
    memory:(unsigned long long)memory frameIntervals:(const double *)intervals
    count:(NSUInteger)count {
    if (_mode == 1) {
        _metricsLabel.text = [NSString stringWithFormat:@"FPS %.0f", fps];
    } else if (_mode == 2) {
        _metricsLabel.text = [NSString stringWithFormat:
            @"FPS %.0f   CPU %.0f%%\nRAM %.0f MB   Frame %.0f ms",
            fps, cpu, (double)memory / (1024.0 * 1024.0), frameMs];
        [_graphView setSamples:intervals count:count
            thresholdMilliseconds:targetFrameMs * 1.5];
    }
}

@end

@interface SM64RootViewController : UIViewController <UIActionSheetDelegate> {
    SM64EAGLView *_glView;
    N64PadView *_padView;
    UILabel *_statusLabel;
    UIButton *_romsButton;
    UIButton *_settingsButton;
    UIView *_settingsScrim;
    UIView *_settingsPanel;
    UILabel *_renderScaleLabel;
    UISlider *_renderScaleSlider;
    UISegmentedControl *_filterControl;
    UISegmentedControl *_frameRateControl;
    UISegmentedControl *_performanceControl;
    SM64PerformanceOverlay *_performanceOverlay;
    NSTimer *_metricsTimer;
    NSInteger _performanceMode;
    BOOL _gameStarted;
}
- (void)refreshROMStatus;
- (void)bootGameWithROM:(SM64RomInfo *)rom;
- (void)appendHeartbeat:(NSString *)line;
- (void)refreshPerformanceOverlay;
- (void)showSettings;
- (void)closeSettings;
- (void)updateRenderResolutionLabel;
- (void)renderScaleChanged:(UISlider *)slider;
- (void)filterChanged:(UISegmentedControl *)control;
- (void)frameRateChanged:(UISegmentedControl *)control;
- (void)performanceModeChanged:(UISegmentedControl *)control;
@end

@implementation SM64RootViewController

- (void)loadView {
    CGRect bounds = [[UIScreen mainScreen] bounds];
    // iPad 1 runs this game in landscape only. UIScreen.bounds can still
    // report the portrait size at launch time (device flat/asleep), so force
    // the landscape dimensions: the EAGL drawable and thus the game's
    // framebuffer must come up 1024x768.
    CGRect frame = CGRectMake(0, 0, MAX(bounds.size.width, bounds.size.height),
                                    MIN(bounds.size.width, bounds.size.height));
    UIView *root = [[UIView alloc] initWithFrame:frame];
    root.backgroundColor = [UIColor blackColor];

    _glView = [[SM64EAGLView alloc] initWithFrame:frame];
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    BOOL linearFiltering = [defaults boolForKey:@"SM64LinearFiltering"];
    NSInteger frameInterval = [defaults objectForKey:@"SM64FrameInterval"] != nil
        ? [defaults integerForKey:@"SM64FrameInterval"] : 2;
    if ([defaults objectForKey:@"SM64ResolutionIndex"] != nil) {
        [_glView setRenderResolutionIndex:
            [defaults integerForKey:@"SM64ResolutionIndex"]
            linearFiltering:linearFiltering];
    } else {
        CGFloat renderScale = [defaults objectForKey:@"SM64RenderScale"] != nil
            ? [defaults floatForKey:@"SM64RenderScale"] : 1.0;
        [_glView setRenderScale:renderScale linearFiltering:linearFiltering];
    }
    [_glView setFrameInterval:frameInterval];
    [root addSubview:_glView];
    ios_bridge_register_view(_glView);

    _padView = [[N64PadView alloc] initWithFrame:frame];
    [_padView setDemoMode:YES];
    [root addSubview:_padView];

    _statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, frame.size.width, 44)];
    _statusLabel.backgroundColor = [UIColor colorWithWhite:0 alpha:0.6];
    _statusLabel.textColor = [UIColor whiteColor];
    _statusLabel.textAlignment = NSTextAlignmentCenter;
    _statusLabel.font = [UIFont systemFontOfSize:14];
    [root addSubview:_statusLabel];

    UIButton *roms = [UIButton buttonWithType:UIButtonTypeRoundedRect];
    roms.frame = CGRectMake(frame.size.width - 120, 52, 112, 36);
    [roms setTitle:@"ROMs" forState:UIControlStateNormal];
    [roms addTarget:self action:@selector(showROMs) forControlEvents:UIControlEventTouchUpInside];
    [root addSubview:roms];
    _romsButton = roms;

    UIButton *settings = [UIButton buttonWithType:UIButtonTypeRoundedRect];
    settings.frame = CGRectMake(frame.size.width - 92, 8, 84, 32);
    [settings setTitle:@"Settings" forState:UIControlStateNormal];
    [settings addTarget:self action:@selector(showSettings)
        forControlEvents:UIControlEventTouchUpInside];
    [root addSubview:settings];
    _settingsButton = settings;

    _performanceMode = MIN(MAX(
        [defaults integerForKey:@"SM64PerformanceMode"], 0), 2);
    _performanceOverlay = [[SM64PerformanceOverlay alloc]
        initWithFrame:CGRectMake(8, 8, 190, 26)];
    [_performanceOverlay setMode:_performanceMode];
    _performanceOverlay.hidden = YES;
    [root addSubview:_performanceOverlay];

    self.view = root;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    if ([paths count] > 0) {
        NSString *log = [[paths objectAtIndex:0] stringByAppendingPathComponent:@"sm64ios-heartbeat.log"];
        NSString *line = [NSString stringWithFormat:@"launch %@\n", [NSDate date]];
        [line writeToFile:log atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
    if ([_glView createContext]) {
        [_glView startPump];
        if ([paths count] > 0) {
            NSString *log = [[paths objectAtIndex:0] stringByAppendingPathComponent:@"sm64ios-heartbeat.log"];
            NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:log];
            [fh seekToEndOfFile];
            [fh writeData:[@"eagl ok, pump started\n" dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        }
    } else {
        _statusLabel.text = @"EAGL context failed — no GLES on this device?";
    }
    _metricsTimer = [NSTimer timerWithTimeInterval:0.5 target:self
        selector:@selector(refreshPerformanceOverlay) userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:_metricsTimer forMode:NSRunLoopCommonModes];
    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(refreshROMStatus)
        name:UIApplicationDidBecomeActiveNotification object:nil];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    // Boot only once the view is on screen: the EAGL drawable (and thus the
    // real framebuffer dimensions) only exist after the first layout pass,
    // and gfx_init reads the dimensions during ios_game_init.
    CGRect wb = self.view.window ? self.view.window.bounds : CGRectZero;
    CGRect vb = self.view.bounds;
    [self appendHeartbeat:[NSString stringWithFormat:
        @"ui: window %.0fx%.0f view %.0fx%.0f statusOrientation=%d\n",
        wb.size.width, wb.size.height, vb.size.width, vb.size.height,
        (int)[UIApplication sharedApplication].statusBarOrientation]];
    [self refreshROMStatus];
}

- (void)refreshROMStatus {
    SM64RomInfo *rom = [SM64ROMValidator firstValidROM];
    NSArray *all = [SM64ROMValidator scanDocuments];
    if (rom != nil) {
        [self bootGameWithROM:rom];
    } else if ([all count] > 0) {
        _statusLabel.text = @"ROMs found, but no known SM64 dump — check hashes";
        [_padView setDemoMode:YES];
    } else {
        _statusLabel.text = @"No ROM — add a .z64 via iTunes File Sharing";
        [_padView setDemoMode:YES];
    }
}

- (void)bootGameWithROM:(SM64RomInfo *)rom {
    // Game CWD = Documents so sm64config.txt + sm64_save_file.bin persist
    // next to the ROMs, emulator-style.
    static BOOL booted = NO;
    if (booted) return;
    booted = YES;
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    if ([paths count] > 0) {
        chdir([[paths objectAtIndex:0] fileSystemRepresentation]);
    }
    [self appendHeartbeat:[NSString stringWithFormat:@"booting %@\n", [rom displayName]]];
    _statusLabel.text = [@"Booting: " stringByAppendingString:[rom displayName]];
    ios_game_init();
    [self appendHeartbeat:@"game init returned\n"];
    ios_bridge_set_frame_fn(produce_one_frame);
    [_padView setDemoMode:NO];
    _gameStarted = YES;
    _performanceOverlay.hidden = (_performanceMode == 0);
    _statusLabel.text = [@"Playing: " stringByAppendingString:[rom displayName]];
    [self appendHeartbeat:[NSString stringWithFormat:@"playing %@\n", [rom displayName]]];
    // The game owns the screen now: drop the debug chrome so nothing extra
    // composites over (or overlaps) the framebuffer.
    _statusLabel.hidden = YES;
    _romsButton.hidden = YES;
}

- (void)showSettings {
    if (_settingsScrim != nil) return;

    CGRect bounds = self.view.bounds;
    CGFloat panelWidth = MIN(390.0, bounds.size.width - 24.0);
    CGFloat panelHeight = MIN(286.0, bounds.size.height - 16.0);
    UIView *scrim = [[UIView alloc] initWithFrame:bounds];
    scrim.backgroundColor = [UIColor colorWithWhite:0 alpha:0.62];
    scrim.autoresizingMask = UIViewAutoresizingFlexibleWidth |
        UIViewAutoresizingFlexibleHeight;

    UIView *panel = [[UIView alloc] initWithFrame:CGRectMake(
        (bounds.size.width - panelWidth) / 2.0,
        (bounds.size.height - panelHeight) / 2.0,
        panelWidth, panelHeight)];
    panel.backgroundColor = [UIColor colorWithWhite:0.12 alpha:0.98];
    panel.layer.cornerRadius = 8.0;
    panel.layer.borderColor = [[UIColor colorWithWhite:1 alpha:0.25] CGColor];
    panel.layer.borderWidth = 1.0;
    [scrim addSubview:panel];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(
        14, 8, panelWidth - 90, 28)];
    title.text = @"Settings";
    title.textColor = [UIColor whiteColor];
    title.backgroundColor = [UIColor clearColor];
    title.font = [UIFont boldSystemFontOfSize:18];
    [panel addSubview:title];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeRoundedRect];
    close.frame = CGRectMake(panelWidth - 70, 7, 58, 30);
    [close setTitle:@"Done" forState:UIControlStateNormal];
    [close addTarget:self action:@selector(closeSettings)
        forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:close];

    UILabel *resolutionTitle = [[UILabel alloc] initWithFrame:CGRectMake(
        14, 38, panelWidth - 28, 18)];
    resolutionTitle.text = @"Render resolution (slide right to lower)";
    resolutionTitle.textColor = [UIColor whiteColor];
    resolutionTitle.backgroundColor = [UIColor clearColor];
    resolutionTitle.font = [UIFont systemFontOfSize:13];
    [panel addSubview:resolutionTitle];

    _renderScaleSlider = [[UISlider alloc] initWithFrame:CGRectMake(
        14, 54, panelWidth - 28, 30)];
    _renderScaleSlider.minimumValue = 0.0;
    _renderScaleSlider.maximumValue =
        (float)MAX(0, [_glView renderResolutionCount] - 1);
    _renderScaleSlider.value = (float)[_glView renderResolutionIndex];
    _renderScaleSlider.continuous = NO;
    _renderScaleSlider.enabled = [_glView renderResolutionCount] > 1;
    [_renderScaleSlider addTarget:self action:@selector(renderScaleChanged:)
        forControlEvents:UIControlEventValueChanged];
    [panel addSubview:_renderScaleSlider];

    _renderScaleLabel = [[UILabel alloc] initWithFrame:CGRectMake(
        14, 82, panelWidth - 28, 16)];
    _renderScaleLabel.textColor = [UIColor colorWithWhite:0.82 alpha:1];
    _renderScaleLabel.backgroundColor = [UIColor clearColor];
    _renderScaleLabel.font = [UIFont systemFontOfSize:10];
    [panel addSubview:_renderScaleLabel];
    [self updateRenderResolutionLabel];

    UILabel *filterTitle = [[UILabel alloc] initWithFrame:CGRectMake(
        14, 101, panelWidth - 28, 17)];
    filterTitle.text = @"Upscaling filter";
    filterTitle.textColor = [UIColor whiteColor];
    filterTitle.backgroundColor = [UIColor clearColor];
    filterTitle.font = [UIFont systemFontOfSize:13];
    [panel addSubview:filterTitle];
    _filterControl = [[UISegmentedControl alloc] initWithItems:
        [NSArray arrayWithObjects:@"Sharp", @"Smooth", nil]];
    _filterControl.frame = CGRectMake(14, 119, panelWidth - 28, 29);
    _filterControl.segmentedControlStyle = UISegmentedControlStyleBar;
    _filterControl.selectedSegmentIndex = [_glView linearFiltering] ? 1 : 0;
    [_filterControl addTarget:self action:@selector(filterChanged:)
        forControlEvents:UIControlEventValueChanged];
    [panel addSubview:_filterControl];

    UILabel *frameRateTitle = [[UILabel alloc] initWithFrame:CGRectMake(
        14, 153, panelWidth - 28, 17)];
    frameRateTitle.text = @"Frame pacing (lower rate may slow gameplay)";
    frameRateTitle.textColor = [UIColor whiteColor];
    frameRateTitle.backgroundColor = [UIColor clearColor];
    frameRateTitle.font = [UIFont systemFontOfSize:13];
    [panel addSubview:frameRateTitle];
    _frameRateControl = [[UISegmentedControl alloc] initWithItems:
        [NSArray arrayWithObjects:@"30 FPS", @"20 FPS", nil]];
    _frameRateControl.frame = CGRectMake(14, 171, panelWidth - 28, 29);
    _frameRateControl.segmentedControlStyle = UISegmentedControlStyleBar;
    _frameRateControl.selectedSegmentIndex =
        [_glView frameInterval] >= 3 ? 1 : 0;
    [_frameRateControl addTarget:self action:@selector(frameRateChanged:)
        forControlEvents:UIControlEventValueChanged];
    [panel addSubview:_frameRateControl];

    UILabel *performanceTitle = [[UILabel alloc] initWithFrame:CGRectMake(
        14, 205, panelWidth - 28, 17)];
    performanceTitle.text = @"Performance overlay";
    performanceTitle.textColor = [UIColor whiteColor];
    performanceTitle.backgroundColor = [UIColor clearColor];
    performanceTitle.font = [UIFont systemFontOfSize:13];
    [panel addSubview:performanceTitle];
    _performanceControl = [[UISegmentedControl alloc] initWithItems:
        [NSArray arrayWithObjects:@"Off", @"FPS", @"Detailed", nil]];
    _performanceControl.frame = CGRectMake(14, 223, panelWidth - 28, 29);
    _performanceControl.segmentedControlStyle = UISegmentedControlStyleBar;
    _performanceControl.selectedSegmentIndex = _performanceMode;
    [_performanceControl addTarget:self action:@selector(performanceModeChanged:)
        forControlEvents:UIControlEventValueChanged];
    [panel addSubview:_performanceControl];

    UILabel *note = [[UILabel alloc] initWithFrame:CGRectMake(
        14, 258, panelWidth - 28, 18)];
    note.text = @"Left: device pixels. Right: N64-scale resolution.";
    note.textColor = [UIColor colorWithWhite:0.72 alpha:1];
    note.backgroundColor = [UIColor clearColor];
    note.font = [UIFont systemFontOfSize:10];
    note.adjustsFontSizeToFitWidth = YES;
    [panel addSubview:note];

    _settingsScrim = scrim;
    _settingsPanel = panel;
    [self.view addSubview:scrim];
}

- (void)closeSettings {
    [_settingsScrim removeFromSuperview];
    _settingsScrim = nil;
    _settingsPanel = nil;
    _renderScaleSlider = nil;
    _renderScaleLabel = nil;
    _filterControl = nil;
    _frameRateControl = nil;
    _performanceControl = nil;
}

- (void)updateRenderResolutionLabel {
    if (_renderScaleLabel == nil) return;
    int width = 0;
    int height = 0;
    [_glView getRenderWidth:&width height:&height];
    _renderScaleLabel.text = [NSString stringWithFormat:
        @"%dx%d game render target", width, height];
}

- (void)renderScaleChanged:(UISlider *)slider {
    NSInteger index = (NSInteger)roundf(slider.value);
    index = MIN(MAX(0, index), [_glView renderResolutionCount] - 1);
    slider.value = (float)index;
    if (![_glView setRenderResolutionIndex:index
            linearFiltering:[_glView linearFiltering]]) {
        slider.value = (float)[_glView renderResolutionIndex];
        UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"Resolution unavailable"
            message:@"The device could not allocate this render target. The previous resolution remains active."
            delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil];
        [alert show];
        [self updateRenderResolutionLabel];
        return;
    }
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setInteger:index forKey:@"SM64ResolutionIndex"];
    [defaults synchronize];
    [self updateRenderResolutionLabel];
}

- (void)filterChanged:(UISegmentedControl *)control {
    BOOL linear = (control.selectedSegmentIndex == 1);
    if (![_glView setRenderResolutionIndex:[_glView renderResolutionIndex]
            linearFiltering:linear]) {
        control.selectedSegmentIndex = [_glView linearFiltering] ? 1 : 0;
        return;
    }
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setBool:linear forKey:@"SM64LinearFiltering"];
    [defaults synchronize];
}

- (void)frameRateChanged:(UISegmentedControl *)control {
    NSInteger interval = control.selectedSegmentIndex == 1 ? 3 : 2;
    [_glView setFrameInterval:interval];
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setInteger:interval forKey:@"SM64FrameInterval"];
    [defaults synchronize];
}

- (void)performanceModeChanged:(UISegmentedControl *)control {
    _performanceMode = control.selectedSegmentIndex;
    [_performanceOverlay setMode:_performanceMode];
    _performanceOverlay.hidden = (!_gameStarted || _performanceMode == 0);
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setInteger:_performanceMode forKey:@"SM64PerformanceMode"];
    [defaults synchronize];
}

- (void)refreshPerformanceOverlay {
    if (!_gameStarted || _performanceMode == 0) return;
    [_glView refreshPerformanceMetrics];
    double intervals[30];
    [_glView copyFrameIntervals:intervals count:30];
    [_performanceOverlay updateFPS:[_glView framesPerSecond]
        cpu:[_glView cpuUsagePercent]
        frameMilliseconds:[_glView frameIntervalMilliseconds]
        targetFrameMilliseconds:(_glView.frameInterval * (1000.0 / 60.0))
        memory:[_glView residentMemoryBytes]
        frameIntervals:intervals count:30];
}

- (void)dealloc {
    [_metricsTimer invalidate];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)appendHeartbeat:(NSString *)line {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    if ([paths count] == 0) return;
    NSString *log = [[paths objectAtIndex:0] stringByAppendingPathComponent:@"sm64ios-heartbeat.log"];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:log];
    if (fh == nil) {
        [line writeToFile:log atomically:YES encoding:NSUTF8StringEncoding error:nil];
        return;
    }
    [fh seekToEndOfFile];
    [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    [fh closeFile];
}

- (void)showROMs {
    NSArray *all = [SM64ROMValidator scanDocuments];
    NSString *msg = ([all count] == 0)
        ? @"Documents is empty.\nAdd baserom.us.z64 via iTunes File Sharing."
        : [NSString stringWithFormat:@"%d file(s):\n%@",
            [all count],
            [[all valueForKey:@"displayName"] componentsJoinedByString:@"\n"]];
    UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"N64 ROMs"
        message:msg delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil];
    [alert show];
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)o {
    return UIInterfaceOrientationIsLandscape(o);
}

@end

@implementation SM64AppDelegate
@synthesize window = _window;

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)opts {
    _window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    // iPad 1 + this game: always landscape. Info.plist already restricts the
    // supported orientations, but iOS 6 can still start portrait (device
    // flat/asleep at launch), which would give the game a 768x1024 surface.
    [[UIApplication sharedApplication] setStatusBarOrientation:UIInterfaceOrientationLandscapeRight animated:NO];
    // Full screen: the game view is a fixed 1024x768 framebuffer.
    [[UIApplication sharedApplication] setStatusBarHidden:YES withAnimation:UIStatusBarAnimationNone];
    SM64RootViewController *root = [[SM64RootViewController alloc] init];
    _window.rootViewController = root;
    [_window makeKeyAndVisible];
    return YES;
}

@end
