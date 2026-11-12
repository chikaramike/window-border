// window-border — draw a colored outline around every on-screen window,
// one stable color per app, so you can tell windows apart at a glance.
//
// Reads only window geometry + owner app via CGWindowList (no screen-recording
// permission needed), and overlays a transparent, click-through border window
// ordered just above each target window so the layering stays correct.

#import <Cocoa/Cocoa.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ServiceManagement/ServiceManagement.h>

static const CGFloat kDefaultLineWidth = 1.0;
static const CGFloat kMaxLineWidth = 20.0;
static const CGFloat kMaxGlow = 30.0;
static const CGFloat kCornerRadius = 10.0;
static const NSTimeInterval kTick = 1.0 / 60.0; // 60 Hz

// The innermost 1pt of the outline sits on the window's edge (as it always
// has); any extra thickness grows outward so thick borders don't cover content.
static CGFloat OutsetForWidth(CGFloat w) { return MAX(0.0, w - kDefaultLineWidth); }

#pragma mark - Border view

@interface BorderView : NSView
@property(nonatomic, strong) NSColor *color;
@property(nonatomic) CGFloat lineWidth;
@property(nonatomic) CGFloat glow; // blur radius of the halo; 0 = none
@end

@implementation BorderView
- (BOOL)isOpaque { return NO; }
- (void)drawRect:(NSRect)dirtyRect {
    [[NSColor clearColor] set];
    NSRectFill(self.bounds);
    NSColor *color = self.color ?: [NSColor systemRedColor];
    CGFloat lw = self.lineWidth > 0 ? self.lineWidth : kDefaultLineWidth;
    CGFloat outset = OutsetForWidth(lw);
    CGFloat radius = kCornerRadius + outset;
    // The overlay is padded by `glow` on every side so the halo isn't clipped.
    NSRect r = NSInsetRect(self.bounds, self.glow + lw / 2.0, self.glow + lw / 2.0);
    NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:r
                                                        xRadius:radius
                                                        yRadius:radius];
    [path setLineWidth:lw];
    [color set];

    if (self.glow > 0) {
        [NSGraphicsContext saveGraphicsState];
        // Keep the halo outside the window so it never dims the app's content.
        NSRect inner = NSInsetRect(self.bounds, self.glow + outset + kDefaultLineWidth,
                                   self.glow + outset + kDefaultLineWidth);
        NSBezierPath *clip = [NSBezierPath bezierPathWithRect:self.bounds];
        [clip appendBezierPath:[NSBezierPath bezierPathWithRoundedRect:inner
                                                               xRadius:kCornerRadius
                                                               yRadius:kCornerRadius]];
        clip.windingRule = NSWindingRuleEvenOdd;
        [clip addClip];
        NSShadow *shadow = [[NSShadow alloc] init];
        shadow.shadowColor = color;
        shadow.shadowBlurRadius = self.glow;
        shadow.shadowOffset = NSZeroSize;
        [shadow set];
        [path stroke]; // two passes make the halo bright enough to read as a glow
        [path stroke];
        [NSGraphicsContext restoreGraphicsState];
    }
    [path stroke];
}
@end

#pragma mark - Border window

@interface BorderWindow : NSWindow
@end

@implementation BorderWindow
- (BOOL)canBecomeKeyWindow { return NO; }
- (BOOL)canBecomeMainWindow { return NO; }
// Place the overlay exactly where told — don't let AppKit shift it to keep a
// title bar on screen (it has none), which otherwise causes a visible offset.
- (NSRect)constrainFrameRect:(NSRect)frameRect toScreen:(NSScreen *)screen {
    return frameRect;
}
@end

#pragma mark - App delegate

@interface AppDelegate : NSObject <NSApplicationDelegate>
@property(nonatomic, strong) NSStatusItem *statusItem;
@property(nonatomic, strong) NSTimer *timer;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, BorderWindow *> *overlays;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSColor *> *assigned;
@property(nonatomic, strong) NSDictionary<NSString *, NSString *> *configColors;
@property(nonatomic, strong) NSArray<NSColor *> *palette;
@property(nonatomic) NSUInteger paletteIndex;
@property(nonatomic) CGFloat lineWidth;       // inactive windows
@property(nonatomic) CGFloat activeLineWidth; // frontmost window
@property(nonatomic, strong) NSDictionary<NSString *, NSNumber *> *glows; // app name -> glow radius
@property(nonatomic) BOOL enabled;
@property(nonatomic, copy) NSString *lastOrder;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)note {
    self.overlays = [NSMutableDictionary dictionary];
    self.assigned = [NSMutableDictionary dictionary];
    self.enabled = YES;
    self.palette = @[
        [NSColor systemRedColor], [NSColor systemOrangeColor], [NSColor systemYellowColor],
        [NSColor systemGreenColor], [NSColor systemTealColor], [NSColor systemBlueColor],
        [NSColor systemIndigoColor], [NSColor systemPurpleColor], [NSColor systemPinkColor],
        [NSColor systemBrownColor], [NSColor systemCyanColor], [NSColor systemMintColor],
    ];
    [self loadConfig];
    [self loadSettings];
    [self setupMenu];

    self.timer = [NSTimer scheduledTimerWithTimeInterval:kTick
                                                  target:self
                                                selector:@selector(tick)
                                                userInfo:nil
                                                 repeats:YES];
    [[NSRunLoop currentRunLoop] addTimer:self.timer forMode:NSRunLoopCommonModes];
}

#pragma mark Menu

- (void)setupMenu {
    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.button.title = @"⬜"; // white square
    NSMenu *menu = [[NSMenu alloc] init];
    [menu addItemWithTitle:@"Borders On/Off" action:@selector(toggle:) keyEquivalent:@""];
    [menu addItemWithTitle:@"Reload Colors" action:@selector(reloadColors:) keyEquivalent:@""];
    NSMenuItem *login = [menu addItemWithTitle:@"Open at Login" action:@selector(toggleLogin:) keyEquivalent:@""];
    login.state = [self loginEnabled] ? NSControlStateValueOn : NSControlStateValueOff;
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItemWithTitle:@"Quit" action:@selector(quit:) keyEquivalent:@"q"];
    for (NSMenuItem *item in menu.itemArray) item.target = self;
    self.statusItem.menu = menu;
}

- (BOOL)loginEnabled {
    if (@available(macOS 13.0, *)) {
        return SMAppService.mainAppService.status == SMAppServiceStatusEnabled;
    }
    return NO;
}

- (void)toggleLogin:(NSMenuItem *)sender {
    if (@available(macOS 13.0, *)) {
        NSError *err = nil;
        if (self.loginEnabled) {
            [SMAppService.mainAppService unregisterAndReturnError:&err];
        } else {
            [SMAppService.mainAppService registerAndReturnError:&err];
        }
        if (err) NSLog(@"login item error: %@", err);
        sender.state = [self loginEnabled] ? NSControlStateValueOn : NSControlStateValueOff;
    }
}

- (void)toggle:(id)sender {
    self.enabled = !self.enabled;
    if (!self.enabled) [self clearOverlays];
    self.statusItem.button.title = self.enabled ? @"⬜" : @"□";
}

- (void)reloadColors:(id)sender {
    [self loadConfig];
    [self loadSettings];
    [self.assigned removeAllObjects];
    self.paletteIndex = 0;
}

- (void)quit:(id)sender {
    [self clearOverlays];
    [NSApp terminate:nil];
}

#pragma mark Config

- (void)loadConfig {
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@".config/window-border/colors.json"];
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) { self.configColors = @{}; return; }
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    self.configColors = [obj isKindOfClass:[NSDictionary class]] ? obj : @{};
}

// Optional ~/.config/window-border/settings.json:
//   { "width": 1, "activeWidth": 4 }
// Both are in points; activeWidth defaults to width when omitted.
- (void)loadSettings {
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@".config/window-border/settings.json"];
    NSData *data = [NSData dataWithContentsOfFile:path];
    id obj = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    NSDictionary *s = [obj isKindOfClass:[NSDictionary class]] ? obj : @{};
    self.lineWidth = [self widthFrom:s[@"width"] fallback:kDefaultLineWidth];
    self.activeLineWidth = [self widthFrom:s[@"activeWidth"] fallback:self.lineWidth];

    // "glow": { "AppName": radius, ... } gives that app's border a soft halo.
    NSMutableDictionary *glows = [NSMutableDictionary dictionary];
    id g = s[@"glow"];
    if ([g isKindOfClass:[NSDictionary class]]) {
        for (id name in g) {
            id v = g[name];
            if (![name isKindOfClass:[NSString class]] || ![v isKindOfClass:[NSNumber class]]) continue;
            CGFloat r = MIN(MAX([v doubleValue], 0.0), kMaxGlow);
            if (r > 0) glows[name] = @(r);
        }
    }
    self.glows = glows;
}

- (CGFloat)widthFrom:(id)value fallback:(CGFloat)fallback {
    if (![value isKindOfClass:[NSNumber class]]) return fallback;
    CGFloat w = [value doubleValue];
    if (w <= 0) return fallback;
    return MIN(w, kMaxLineWidth);
}

- (NSColor *)colorFromHex:(NSString *)hex {
    NSString *s = [hex stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if ([s hasPrefix:@"#"]) s = [s substringFromIndex:1];
    if (s.length != 6) return nil;
    unsigned int v = 0;
    if (![[NSScanner scannerWithString:s] scanHexInt:&v]) return nil;
    return [NSColor colorWithSRGBRed:((v >> 16) & 0xFF) / 255.0
                               green:((v >> 8) & 0xFF) / 255.0
                                blue:(v & 0xFF) / 255.0
                               alpha:1.0];
}

- (NSColor *)colorForApp:(NSString *)name {
    if (name.length == 0) name = @"?";
    NSString *hex = self.configColors[name];
    if (hex) {
        NSColor *c = [self colorFromHex:hex];
        if (c) return c;
    }
    // Optional "*" key: one color for every app not listed by name.
    NSString *fallback = self.configColors[@"*"];
    if (fallback) {
        NSColor *c = [self colorFromHex:fallback];
        if (c) return c;
    }
    NSColor *existing = self.assigned[name];
    if (existing) return existing;
    NSColor *c = self.palette[self.paletteIndex % self.palette.count];
    self.paletteIndex++;
    self.assigned[name] = c;
    return c;
}

#pragma mark Window tracking

- (CGFloat)primaryHeight {
    NSArray<NSScreen *> *screens = [NSScreen screens];
    return screens.count ? NSHeight(screens[0].frame) : 0;
}

- (BOOL)shouldSkipOwner:(NSString *)name {
    static NSSet *skip;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        skip = [NSSet setWithArray:@[ @"Window Server", @"WindowManager", @"Dock",
                                      @"Control Center", @"Notification Center", @"Spotlight" ]];
    });
    return [skip containsObject:name];
}

- (void)tick {
    if (!self.enabled) return;

    CFArrayRef listRef = CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID);
    NSArray *windows = CFBridgingRelease(listRef);
    CGFloat primaryHeight = [self primaryHeight];
    pid_t myPid = getpid();
    NSMutableSet<NSNumber *> *live = [NSMutableSet set];
    NSMutableArray<NSNumber *> *order = [NSMutableArray array];
    BOOL dirty = NO;

    for (NSDictionary *w in windows) {
        if ([w[(id)kCGWindowLayer] intValue] != 0) continue;            // normal windows only
        if ([w[(id)kCGWindowOwnerPID] intValue] == myPid) continue;     // skip our own
        NSNumber *alpha = w[(id)kCGWindowAlpha];
        if (alpha && alpha.doubleValue <= 0.01) continue;
        NSString *owner = w[(id)kCGWindowOwnerName] ?: @"";
        if ([self shouldSkipOwner:owner]) continue;

        CGRect bounds = CGRectZero;
        CGRectMakeWithDictionaryRepresentation((CFDictionaryRef)w[(id)kCGWindowBounds], &bounds);
        if (bounds.size.width < 80 || bounds.size.height < 60) continue; // skip tiny

        NSNumber *wid = w[(id)kCGWindowNumber];
        // CGWindowList is front-to-back, so the first window we keep is the active one.
        BOOL isFront = (order.count == 0);
        CGFloat lw = isFront ? self.activeLineWidth : self.lineWidth;
        CGFloat glow = self.glows[owner].doubleValue;
        CGFloat outset = OutsetForWidth(lw) + glow;
        NSRect frame = NSMakeRect(bounds.origin.x - outset,
                                  primaryHeight - bounds.origin.y - bounds.size.height - outset,
                                  bounds.size.width + 2 * outset, bounds.size.height + 2 * outset);
        [live addObject:wid];
        [order addObject:wid];

        BorderWindow *ov = self.overlays[wid];
        if (!ov) {
            ov = [[BorderWindow alloc] initWithContentRect:frame
                                                 styleMask:NSWindowStyleMaskBorderless
                                                   backing:NSBackingStoreBuffered
                                                     defer:NO];
            ov.opaque = NO;
            ov.backgroundColor = [NSColor clearColor];
            ov.hasShadow = NO;
            ov.ignoresMouseEvents = YES;
            ov.level = NSNormalWindowLevel;
            ov.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                                    NSWindowCollectionBehaviorStationary |
                                    NSWindowCollectionBehaviorIgnoresCycle;
            BorderView *bv = [[BorderView alloc] initWithFrame:(NSRect){NSZeroPoint, frame.size}];
            bv.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
            ov.contentView = bv;
            self.overlays[wid] = ov;
            dirty = YES;
        }

        if (!NSEqualRects(ov.frame, frame)) { [ov setFrame:frame display:YES]; dirty = YES; }
        BorderView *bv = (BorderView *)ov.contentView;
        NSColor *color = [self colorForApp:owner];
        if (![bv.color isEqual:color]) { bv.color = color; [bv setNeedsDisplay:YES]; }
        if (bv.lineWidth != lw) { bv.lineWidth = lw; [bv setNeedsDisplay:YES]; }
        if (bv.glow != glow) { bv.glow = glow; [bv setNeedsDisplay:YES]; }
    }

    // Re-stack overlays above their windows whenever anything moved or the
    // window order changed (a dragged/activated window jumps above its overlay,
    // so the overlay must be lifted back on top). When the screen is fully
    // static we skip this, so there's no idle churn or jank.
    NSString *signature = [order componentsJoinedByString:@","];
    if (![signature isEqualToString:self.lastOrder]) { dirty = YES; self.lastOrder = signature; }
    if (dirty) {
        for (NSNumber *wid in order) {
            [self.overlays[wid] orderWindow:NSWindowAbove relativeTo:wid.integerValue];
        }
    }

    // The frontmost (active) window jumps above its overlay on every click/keypress,
    // so keep just that one lifted every frame. It's a single call, so no churn.
    if (order.count > 0) {
        NSNumber *front = order.firstObject;
        [self.overlays[front] orderWindow:NSWindowAbove relativeTo:front.integerValue];
    }

    // Drop overlays for windows that are gone.
    for (NSNumber *key in self.overlays.allKeys) {
        if (![live containsObject:key]) {
            [self.overlays[key] orderOut:nil];
            [self.overlays removeObjectForKey:key];
        }
    }
}

- (void)clearOverlays {
    for (BorderWindow *ov in self.overlays.allValues) [ov orderOut:nil];
    [self.overlays removeAllObjects];
}

@end

int main(void) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        AppDelegate *delegate = [[AppDelegate alloc] init];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
