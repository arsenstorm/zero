// Loaded into every probe (probe.sh, DYLD_INSERT_LIBRARIES): whatever window the probe makes stays off every display,
// and the probe never activates, so nothing of it shows on the user's screen or takes their focus. macOS moves a
// window placed off-screen back onto a display (constrainFrameRect), so placing it away in the probe isn't enough.
#import <AppKit/AppKit.h>
#import <objc/runtime.h>

static NSPoint away(void) {
    NSRect all = NSZeroRect;
    for (NSScreen *screen in NSScreen.screens) all = NSUnionRect(all, screen.frame);
    return NSMakePoint(NSMaxX(all) + 4000, NSMaxY(all) + 4000);
}

@implementation NSWindow (ZeroProbe)
- (NSRect)zeroProbe_constrainFrameRect:(NSRect)rect toScreen:(NSScreen *)screen {
    rect.origin = away();
    return rect;
}
- (void)zeroProbe_setFrame:(NSRect)rect display:(BOOL)display {
    rect.origin = away();
    [self zeroProbe_setFrame:rect display:display];
}
- (void)zeroProbe_setFrameOrigin:(NSPoint)point {
    [self zeroProbe_setFrameOrigin:away()];
}
@end

@implementation NSApplication (ZeroProbe)
- (void)zeroProbe_activateIgnoringOtherApps:(BOOL)flag {}
- (void)zeroProbe_activate {}
@end

static void swap(Class cls, SEL original, SEL replacement) {
    Method a = class_getInstanceMethod(cls, original), b = class_getInstanceMethod(cls, replacement);
    if (a && b) method_exchangeImplementations(a, b);
}

__attribute__((constructor)) static void install(void) {
    swap(NSWindow.class, @selector(constrainFrameRect:toScreen:), @selector(zeroProbe_constrainFrameRect:toScreen:));
    swap(NSWindow.class, @selector(setFrame:display:), @selector(zeroProbe_setFrame:display:));
    swap(NSWindow.class, @selector(setFrameOrigin:), @selector(zeroProbe_setFrameOrigin:));
    swap(NSApplication.class, @selector(activateIgnoringOtherApps:), @selector(zeroProbe_activateIgnoringOtherApps:));
    swap(NSApplication.class, @selector(activate), @selector(zeroProbe_activate));
}
