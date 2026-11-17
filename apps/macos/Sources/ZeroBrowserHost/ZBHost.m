#import "ZBHost.h"
#import "ZBAccessibility.h"

#import <IOSurface/IOSurface.h>
#import <QuartzCore/QuartzCore.h>
#import <Security/Security.h>
#include <mach/mach.h>
#include <servers/bootstrap.h>
#include <sys/socket.h>
#include <sys/wait.h>

// The Mach messages (the browser app has the same).
enum { kMsgSurface = 1, kMsgFrame = 2, kMsgHello = 3, kMsgControl = 4 };
typedef struct { mach_msg_header_t h; mach_msg_body_t body; mach_msg_port_descriptor_t port; uint32_t id, w, h2, popup, tab; } SurfaceMsg;
typedef struct { mach_msg_header_t h; uint32_t id, popup; int32_t x, y; double painted, copied; uint32_t tab; } FrameMsg;
typedef struct { mach_msg_header_t h; mach_msg_body_t body; mach_msg_port_descriptor_t port; } HelloMsg;

extern int fileport_makefd(mach_port_t port);

static BOOL Trusted(audit_token_t token, NSString *requirement) {
  SecCodeRef code = NULL;
  SecRequirementRef req = NULL;
  NSDictionary *attrs = @{(__bridge id)kSecGuestAttributeAudit: [NSData dataWithBytes:&token length:sizeof token]};
  BOOL ok = SecCodeCopyGuestWithAttributes(NULL, (__bridge CFDictionaryRef)attrs, kSecCSDefaultFlags, &code) == errSecSuccess &&
            SecRequirementCreateWithString((__bridge CFStringRef)requirement, kSecCSDefaultFlags, &req) == errSecSuccess &&
            SecCodeCheckValidity(code, kSecCSDefaultFlags, req) == errSecSuccess;
  if (code) CFRelease(code);
  if (req) CFRelease(req);
  return ok;
}

// CEF's event flags.
enum {
  kCaps = 1 << 0, kShift = 1 << 1, kControl = 1 << 2, kAlt = 1 << 3, kLeft = 1 << 4, kMiddle = 1 << 5, kRight = 1 << 6,
  kCommand = 1 << 7, kKeyPad = 1 << 9, kRepeat = 1 << 13, kPrecise = 1 << 14
};

static int Modifiers(NSEvent *event) {
  NSEventModifierFlags f = event.modifierFlags;
  int m = 0;
  if (f & NSEventModifierFlagCapsLock) m |= kCaps;
  if (f & NSEventModifierFlagShift) m |= kShift;
  if (f & NSEventModifierFlagControl) m |= kControl;
  if (f & NSEventModifierFlagOption) m |= kAlt;
  if (f & NSEventModifierFlagCommand) m |= kCommand;
  if (f & NSEventModifierFlagNumericPad) m |= kKeyPad;
  // The button a mouse event is about, from the event itself (the hardware's state may already have moved on).
  switch (event.type) {
    case NSEventTypeLeftMouseDown: case NSEventTypeLeftMouseDragged: m |= kLeft; break;
    case NSEventTypeRightMouseDown: case NSEventTypeRightMouseDragged: m |= kRight; break;
    case NSEventTypeOtherMouseDown: case NSEventTypeOtherMouseDragged: m |= kMiddle; break;
    default: break;
  }
  if ((event.type == NSEventTypeKeyDown || event.type == NSEventTypeKeyUp) && event.isARepeat) m |= kRepeat;
  return m;
}

static NSCursor *Cursor(int type) {
  switch (type) {
    case 1: return NSCursor.crosshairCursor;          // CT_CROSS
    case 2: return NSCursor.pointingHandCursor;       // CT_HAND
    case 3: return NSCursor.IBeamCursor;              // CT_IBEAM
    case 14: case 18: return NSCursor.resizeUpDownCursor;     // CT_NORTHSOUTHRESIZE, CT_ROWRESIZE
    case 15: case 17: return NSCursor.resizeLeftRightCursor;  // CT_EASTWESTRESIZE, CT_COLUMNRESIZE
    case 37: return NSCursor.operationNotAllowedCursor;        // CT_NOTALLOWED
    case 40: return NSCursor.openHandCursor;          // CT_GRAB
    case 41: return NSCursor.closedHandCursor;        // CT_GRABBING
    default: return NSCursor.arrowCursor;
  }
}

@class ZBHost;

// The page: the frames as a layer, and every event forwarded. It is Zero's own view, so focus and the key window
// stay Zero's.
@interface ZBPageView : NSView <NSTextInputClient, NSDraggingSource>
@property (nonatomic, weak) ZBHost *host;
@property (nonatomic, strong) NSCursor *pageCursor;
@property (nonatomic) NSRect caret;
@property (nonatomic, strong) CALayer *popup;
@property (nonatomic, strong) ZBAXTree *axTree;
/// A drag that started in the page, followed here while it stays over the view.
@property (nonatomic) BOOL pageDragging;
@property (nonatomic, copy, nullable) NSDictionary *pageDrag;
@property (nonatomic) BOOL axEnabled;
@end

@interface ZBHost ()
- (instancetype)initWithEngine:(ZBEngine *)engine number:(int)number url:(NSString *)url isolated:(BOOL)isolated;
- (void)send:(NSDictionary *)message;
- (void)sendSize;
- (void)reopen;
- (void)handle:(NSDictionary *)m;
- (void)showFrame:(id)surface popup:(BOOL)popup;
- (void)engineCrashed:(NSString *)why;
@end

@interface ZBEngine ()
- (void)send:(NSDictionary *)message;
- (void)forget:(ZBHost *)tab;
@end

@implementation ZBPageView {
  BOOL _handlingKeyDown, _hasMarked, _oldHasMarked, _unmarkCalled, _hasEditCommands;
  NSMutableArray<NSString *> *_commands;
  NSMutableString *_toInsert;
  NSString *_marked;
  NSRange _selected;
  double _restX, _restY;
  NSTrackingArea *_tracking;
  NSMutableArray *_observers;
}

- (instancetype)initWithFrame:(NSRect)frame {
  if ((self = [super initWithFrame:frame])) {
    self.wantsLayer = YES;
    self.layer.backgroundColor = NSColor.whiteColor.CGColor;
    self.layer.contentsGravity = kCAGravityTopLeft;
    _popup = [CALayer layer];
    _popup.contentsGravity = kCAGravityTopLeft;
    _popup.hidden = YES;
    _popup.anchorPoint = CGPointZero;
    [self.layer addSublayer:_popup];
    _pageCursor = NSCursor.arrowCursor;
    _axTree = [ZBAXTree new];
    _axTree.view = self;
    [self registerForDraggedTypes:@[NSPasteboardTypeFileURL, NSPasteboardTypeURL, NSPasteboardTypeString]];
    _toInsert = [NSMutableString string];
    _commands = [NSMutableArray array];
  }
  return self;
}

- (BOOL)isFlipped { return YES; }

// MARK: Accessibility: the page's tree, from Chromium. It is turned on the first time anything asks (VoiceOver,
// Accessibility Inspector), since building it costs the page time.
- (void)wantAccessibility {
  if (_axEnabled) return;
  _axEnabled = YES;
  [self.host send:@{@"t": @"ax", @"on": @YES}];
}
- (BOOL)isAccessibilityElement { return NO; }
- (NSAccessibilityRole)accessibilityRole { return NSAccessibilityGroupRole; }
- (NSArray *)accessibilityChildren {
  [self wantAccessibility];
  ZBAXNode *root = _axTree.root;
  return root ? @[root] : @[];
}
- (id)accessibilityFocusedUIElement {
  [self wantAccessibility];
  return _axTree.focused ?: self;
}
- (id)accessibilityHitTest:(NSPoint)point {
  [self wantAccessibility];
  NSPoint inView = [self convertPoint:[self.window convertPointFromScreen:point] fromView:nil];
  ZBAXNode *best = nil;
  for (ZBAXNode *n = _axTree.root; n;) {
    best = n;
    ZBAXNode *next = nil;
    for (ZBAXNode *c in n.accessibilityChildren.reverseObjectEnumerator)
      if (NSPointInRect(inView, c.pageRect)) { next = c; break; }
    n = next;
  }
  return best ?: self;
}
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }
- (BOOL)becomeFirstResponder {
  [self.host send:@{@"t": @"focus", @"on": @YES}];
  return YES;
}
- (BOOL)resignFirstResponder {
  [self.host send:@{@"t": @"focus", @"on": @NO}];
  return YES;
}
// A window that stops being key takes the page's focus with it (blur, no caret), as in Safari and Chrome.
- (void)viewDidMoveToWindow {
  [super viewDidMoveToWindow];
  for (id o in _observers) [NSNotificationCenter.defaultCenter removeObserver:o];
  _observers = [NSMutableArray array];
  if (!self.window) return;
  __weak ZBPageView *weak = self;
  for (NSNotificationName name in @[NSWindowDidBecomeKeyNotification, NSWindowDidResignKeyNotification]) {
    [_observers addObject:[NSNotificationCenter.defaultCenter addObserverForName:name object:self.window queue:nil usingBlock:^(NSNotification *note) {
      ZBPageView *me = weak;
      if (me && me.window.firstResponder == me)
        [me.host send:@{@"t": @"focus", @"on": @([note.name isEqual:NSWindowDidBecomeKeyNotification])}];
    }]];
  }
}

- (void)setFrameSize:(NSSize)size {
  [super setFrameSize:size];
  [self.host sendSize];
}
- (void)viewDidChangeBackingProperties {
  [super viewDidChangeBackingProperties];
  self.layer.contentsScale = self.popup.contentsScale = self.window.backingScaleFactor ?: 2;
  [self.host sendSize];
}

- (void)updateTrackingAreas {
  if (_tracking) [self removeTrackingArea:_tracking];
  _tracking = [[NSTrackingArea alloc] initWithRect:NSZeroRect
                                           options:NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited |
                                                   NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect | NSTrackingCursorUpdate
                                             owner:self userInfo:nil];
  [self addTrackingArea:_tracking];
  [super updateTrackingAreas];
}
- (void)cursorUpdate:(NSEvent *)event { [self.pageCursor set]; }
- (void)setPageCursor:(NSCursor *)cursor {
  _pageCursor = cursor;
  NSPoint p = [self convertPoint:self.window.mouseLocationOutsideOfEventStream fromView:nil];
  if (NSPointInRect(p, self.bounds)) [cursor set];
}

// MARK: Mouse

- (void)mouse:(NSEvent *)event kind:(NSString *)kind button:(int)button {
  NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
  NSMutableDictionary *m = [@{@"t": @"mouse", @"kind": kind, @"x": @((int)p.x), @"y": @((int)p.y), @"mods": @(Modifiers(event))} mutableCopy];
  if (button >= 0) {
    m[@"button"] = @(button);
    m[@"clicks"] = @(event.clickCount);
  }
  [self.host send:m];
}
- (void)mouseDown:(NSEvent *)e {
  [self.window makeFirstResponder:self];
  [self mouse:e kind:@"down" button:0];
}
- (void)mouseUp:(NSEvent *)e {
  if (self.pageDragging) {
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    [self.host send:@{@"t": @"drag-drop", @"x": @((int)p.x), @"y": @((int)p.y), @"ops": self.pageDrag[@"ops"] ?: @1, @"mods": @(Modifiers(e))}];
    [self.host send:@{@"t": @"drag-end", @"x": @((int)p.x), @"y": @((int)p.y), @"op": @16}];
    self.pageDragging = NO;
    self.pageDrag = nil;
    return;
  }
  [self mouse:e kind:@"up" button:0];
}
- (void)rightMouseDown:(NSEvent *)e {
  [self.window makeFirstResponder:self];
  [self mouse:e kind:@"down" button:2];
}
- (void)rightMouseUp:(NSEvent *)e { [self mouse:e kind:@"up" button:2]; }
- (void)otherMouseDown:(NSEvent *)e { [self mouse:e kind:@"down" button:1]; }
- (void)otherMouseUp:(NSEvent *)e { [self mouse:e kind:@"up" button:1]; }
- (void)mouseMoved:(NSEvent *)e { [self mouse:e kind:@"move" button:-1]; }
- (void)mouseDragged:(NSEvent *)e {
  if (self.pageDragging) {
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    if (NSPointInRect(p, self.bounds)) {
      [self.host send:@{@"t": @"drag-over", @"x": @((int)p.x), @"y": @((int)p.y), @"ops": self.pageDrag[@"ops"] ?: @1, @"mods": @(Modifiers(e))}];
    } else {
      [self dragOut:e];
    }
    return;
  }
  [self mouse:e kind:@"move" button:-1];
}

// The page's drag left the view: macOS takes it from here (text or a link, to another app).
- (void)dragOut:(NSEvent *)e {
  NSDictionary *d = self.pageDrag;
  self.pageDragging = NO;
  [self.host send:@{@"t": @"drag-leave"}];
  NSPasteboardItem *item = [NSPasteboardItem new];
  if ([d[@"url"] length]) [item setString:d[@"url"] forType:NSPasteboardTypeURL];
  [item setString:([d[@"text"] length] ? d[@"text"] : d[@"url"]) ?: @"" forType:NSPasteboardTypeString];
  NSDraggingItem *drag = [[NSDraggingItem alloc] initWithPasteboardWriter:item];
  NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
  [drag setDraggingFrame:NSMakeRect(p.x, p.y, 1, 1) contents:nil];
  [self beginDraggingSessionWithItems:@[drag] event:e source:self];
}

- (NSDragOperation)draggingSession:(NSDraggingSession *)session sourceOperationMaskForDraggingContext:(NSDraggingContext)context {
  return NSDragOperationCopy | NSDragOperationLink | NSDragOperationGeneric;
}
- (void)draggingSession:(NSDraggingSession *)session endedAtPoint:(NSPoint)screen operation:(NSDragOperation)op {
  NSPoint p = [self convertPoint:[self.window convertPointFromScreen:screen] fromView:nil];
  [self.host send:@{@"t": @"drag-end", @"x": @((int)p.x), @"y": @((int)p.y), @"op": @(op)}];
  self.pageDrag = nil;
}

// MARK: Drops from other apps (files, text, links), and the page's own drag coming back
- (NSDictionary *)drop:(id<NSDraggingInfo>)info kind:(NSString *)kind {
  NSPoint p = [self convertPoint:info.draggingLocation fromView:nil];
  NSMutableDictionary *m = [@{@"t": kind, @"x": @((int)p.x), @"y": @((int)p.y), @"ops": @(info.draggingSourceOperationMask)} mutableCopy];
  if ([kind isEqual:@"drag-enter"]) {
    if (info.draggingSource == self) {
      m[@"own"] = @YES;
    } else {
      NSPasteboard *pb = info.draggingPasteboard;
      NSMutableArray *files = [NSMutableArray array];
      for (NSURL *u in [pb readObjectsForClasses:@[NSURL.class] options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}] ?: @[])
        [files addObject:u.path];
      m[@"files"] = files;
      NSURL *link = [[pb readObjectsForClasses:@[NSURL.class] options:@{NSPasteboardURLReadingFileURLsOnlyKey: @NO}] firstObject];
      if (link && !link.isFileURL) m[@"url"] = link.absoluteString;
      m[@"text"] = [pb stringForType:NSPasteboardTypeString] ?: @"";
    }
  }
  return m;
}
- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)info {
  [self.host send:[self drop:info kind:@"drag-enter"]];
  return NSDragOperationCopy;
}
- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)info {
  [self.host send:[self drop:info kind:@"drag-over"]];
  return NSDragOperationCopy;
}
- (void)draggingExited:(id<NSDraggingInfo>)info { [self.host send:@{@"t": @"drag-leave"}]; }
- (BOOL)performDragOperation:(id<NSDraggingInfo>)info {
  [self.host send:[self drop:info kind:@"drag-drop"]];
  return YES;
}
- (void)rightMouseDragged:(NSEvent *)e { [self mouse:e kind:@"move" button:-1]; }
- (void)otherMouseDragged:(NSEvent *)e { [self mouse:e kind:@"move" button:-1]; }
- (void)mouseExited:(NSEvent *)e { [self mouse:e kind:@"leave" button:-1]; }

- (void)scrollWheel:(NSEvent *)event {
  // Trackpads give fractional points; CEF takes whole pixels, so the remainder carries to the next event.
  double dx = event.hasPreciseScrollingDeltas ? event.scrollingDeltaX : event.scrollingDeltaX * 40;
  double dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 40;
  dx += _restX;
  dy += _restY;
  int ix = (int)dx, iy = (int)dy;
  _restX = dx - ix;
  _restY = dy - iy;
  if (!ix && !iy) return;
  NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
  // A trackpad's deltas are exact: Chromium then scrolls by them at once. Without the flag it animates each event
  // as a mouse wheel's step, which lags behind the fingers.
  int mods = Modifiers(event) | (event.hasPreciseScrollingDeltas && self.host.preciseScrolling ? kPrecise : 0);
  [self.host send:@{@"t": @"wheel", @"x": @((int)p.x), @"y": @((int)p.y), @"dx": @(ix), @"dy": @(iy), @"mods": @(mods)}];
}

// MARK: Keys (Chromium's own order: render_widget_host_view_cocoa.mm, keyEvent:)

- (NSDictionary *)key:(NSEvent *)event kind:(NSString *)kind {
  NSString *chars = event.characters ?: @"";
  return @{@"t": @"key", @"kind": kind, @"code": @(event.keyCode), @"mods": @(Modifiers(event)),
           @"key": (event.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagControl)) ? (event.charactersIgnoringModifiers ?: @"") : chars,
           @"unmod": event.charactersIgnoringModifiers ?: @""};
}

- (void)keyDown:(NSEvent *)event {
  _oldHasMarked = _hasMarked;
  _handlingKeyDown = YES;
  _hasEditCommands = NO;
  [_commands removeAllObjects];
  [_toInsert setString:@""];
  _marked = nil;
  _unmarkCalled = NO;
  [self.inputContext handleEvent:event];
  _handlingKeyDown = NO;

  BOOL composing = _hasMarked || _oldHasMarked;
  if (!composing) {
    NSMutableDictionary *down = [[self key:event kind:@"rawKeyDown"] mutableCopy];
    if (_commands.count) down[@"commands"] = [_commands copy];
    [self.host send:down];
  }
  // More than one character, or the end of a composition: as committed text.
  BOOL inserted = NO;
  if (_toInsert.length > (composing ? 0u : 1u)) {
    [self.host send:@{@"t": @"ime-commit", @"text": [_toInsert copy]}];
    inserted = YES;
  }
  if (_hasMarked && _marked.length) {
    [self.host send:@{@"t": @"ime-set", @"text": _marked, @"selStart": @(_selected.location), @"selEnd": @(NSMaxRange(_selected))}];
  } else if (_oldHasMarked && !_hasMarked && !inserted) {
    [self.host send:@{@"t": _unmarkCalled ? @"ime-finish" : @"ime-cancel"}];
  }
  if (_hasMarked) return;
  NSString *chars = event.characters ?: @"";
  BOOL ctrlOrCmd = (event.modifierFlags & (NSEventModifierFlagControl | NSEventModifierFlagCommand)) != 0;
  if (!inserted && _toInsert.length == 1) {
    NSMutableDictionary *c = [[self key:event kind:@"char"] mutableCopy];
    c[@"text"] = [_toInsert copy];
    [self.host send:c];
  } else if (!inserted && chars.length && [chars characterAtIndex:0] < 0xF700 &&
             (ctrlOrCmd || (_hasEditCommands && _commands.count == 0))) {
    // No insertText: with ⌃/⌘ down, or for a key that maps to an insert command (Return, Tab): a char anyway,
    // unless the key ran another command.
    NSMutableDictionary *c = [[self key:event kind:@"char"] mutableCopy];
    c[@"text"] = chars;
    [self.host send:c];
  }
}

- (void)keyUp:(NSEvent *)event { [self.host send:[self key:event kind:@"keyUp"]]; }

// ⌘ keys come here before the menu. The menu keeps its own (⌘C, ⌘L, ⌘Q…); every other one goes to the page
// (⌘⌫, ⌘←, ⌘B in an editor). AppKit sends no key up for them, so it is sent at once.
- (BOOL)performKeyEquivalent:(NSEvent *)event {
  if (self.window.firstResponder != self || !(event.modifierFlags & NSEventModifierFlagCommand)) return NO;
  if ([NSApp.mainMenu performKeyEquivalent:event]) return YES;
  [self keyDown:event];
  [self.host send:[self key:event kind:@"keyUp"]];
  return YES;
}

// The Edit menu.
- (void)copy:(id)sender { [self.host command:@"copy"]; }
- (void)cut:(id)sender { [self.host command:@"cut"]; }
- (void)paste:(id)sender { [self.host command:@"paste"]; }
- (void)selectAll:(id)sender { [self.host command:@"selectAll"]; }
- (void)undo:(id)sender { [self.host command:@"undo"]; }
- (void)redo:(id)sender { [self.host command:@"redo"]; }

// MARK: NSTextInputClient

- (void)insertText:(id)string replacementRange:(NSRange)range {
  NSString *text = [string isKindOfClass:NSAttributedString.class] ? [string string] : string;
  if (_handlingKeyDown) [_toInsert appendString:text];
  else [self.host send:@{@"t": @"ime-commit", @"text": text}];
  _hasMarked = NO;
}
- (void)setMarkedText:(id)string selectedRange:(NSRange)selected replacementRange:(NSRange)range {
  NSString *text = [string isKindOfClass:NSAttributedString.class] ? [string string] : string;
  _marked = text;
  _selected = selected;
  _hasMarked = text.length > 0;
  if (!_handlingKeyDown)
    [self.host send:@{@"t": @"ime-set", @"text": text, @"selStart": @(selected.location), @"selEnd": @(NSMaxRange(selected))}];
}
- (void)unmarkText {
  _hasMarked = NO;
  _marked = nil;
  if (_handlingKeyDown) _unmarkCalled = YES;
  else [self.host send:@{@"t": @"ime-finish"}];
}
// macOS's text system names what a key does; Chromium sends these with the key down, as edit commands, and Blink
// runs them (render_widget_host_view_cocoa.mm). Commands that insert text are left to the char event.
- (void)doCommandBySelector:(SEL)selector {
  if (selector == @selector(noop:)) return;
  NSString *name = NSStringFromSelector(selector);
  if (selector == @selector(insertParagraphSeparator:) || selector == @selector(insertNewlineIgnoringFieldEditor:)) name = @"InsertNewline:";
  else if (selector == @selector(insertTabIgnoringFieldEditor:)) name = @"InsertTab:";
  else if (selector == @selector(pageDown:)) name = @"MovePageDown:";
  else if (selector == @selector(pageDownAndModifySelection:)) name = @"MovePageDownAndModifySelection:";
  else if (selector == @selector(pageUp:)) name = @"MovePageUp:";
  else if (selector == @selector(pageUpAndModifySelection:)) name = @"MovePageUpAndModifySelection:";
  name = [name substringToIndex:name.length - 1];
  BOOL insert = [name.lowercaseString hasPrefix:@"insert"];
  if (_handlingKeyDown) {
    _hasEditCommands = YES;
    if (!insert) [_commands addObject:name];
  } else {
    [self.host send:@{@"t": @"cdp", @"id": @0, @"method": @"Input.dispatchKeyEvent",
                      @"params": @{@"type": @"rawKeyDown", @"commands": @[name]}}];
  }
}
- (BOOL)hasMarkedText { return _hasMarked; }
- (NSRange)markedRange { return _hasMarked ? NSMakeRange(0, _marked.length) : NSMakeRange(NSNotFound, 0); }
- (NSRange)selectedRange { return _selected; }
- (NSArray<NSAttributedStringKey> *)validAttributesForMarkedText { return @[]; }
- (NSAttributedString *)attributedSubstringForProposedRange:(NSRange)range actualRange:(NSRangePointer)actual { return nil; }
- (NSUInteger)characterIndexForPoint:(NSPoint)point { return NSNotFound; }
- (NSRect)firstRectForCharacterRange:(NSRange)range actualRange:(NSRangePointer)actual {
  NSRect r = NSIsEmptyRect(self.caret) ? NSMakeRect(0, 0, 1, 20) : self.caret;
  return [self.window convertRectToScreen:[self convertRect:r toView:nil]];
}
@end

// MARK: - A tab

@implementation ZBHost {
  @public
  CFAbsoluteTime _fillsDone;  // when the accessibility fills asked for so far are through
  @protected
  ZBPageView *_page;
  NSString *_url, *_title;
  BOOL _back, _forward;
  NSMutableDictionary<NSNumber *, void (^)(BOOL, NSString *)> *_pending;
  int _nextRequest;
  BOOL _tabHidden;
  BOOL _dialogUp;
  NSInteger _shield;
  BOOL _devDialogKeeps, _devShieldKeeps;
  NSDictionary *_devDialogState;
  NSMutableDictionary<NSString *, void (^)(BOOL)> *_pdfs;
  NSInteger _devKeptUnder;
  NSMutableArray *_placeObservers;  // while a dialog is expected or shows: what moves, hides or shows the page
  id _clickMonitor;                 // and every click in Zero, which brings the clicked window above the dialog
}

- (instancetype)initWithEngine:(ZBEngine *)engine number:(int)number url:(NSString *)url isolated:(BOOL)isolated {
  if ((self = [super init])) {
    _engine = engine;
    _number = number;
    _isolated = isolated;
    _url = url;
    _title = @"";
    _pending = [NSMutableDictionary dictionary];
    _page = [[ZBPageView alloc] initWithFrame:NSMakeRect(0, 0, 800, 600)];
    _page.host = self;
    // VoiceOver's press: a click at the element's centre.
    __weak ZBHost *weak = self;
    _page.axTree.press = ^(ZBAXNode *node) {
      CGRect r = node.pageRect;
      int x = (int)CGRectGetMidX(r), y = (int)CGRectGetMidY(r);
      for (NSString *kind in @[@"down", @"up"])
        [weak send:@{@"t": @"mouse", @"kind": kind, @"x": @(x), @"y": @(y), @"button": @0, @"clicks": @1, @"mods": @0}];
    };
    // A field focused by a click, so the keyboard is the page's (1Password types when a set doesn't take); a value as
    // typed text over the field's own, so the page's input events run (React forms see it).
    void (^press)(ZBAXNode *) = _page.axTree.press;
    // One at a time: a fill's click, select-all and text land before the next field's click.
    _page.axTree.fill = ^(ZBAXNode *node, NSString *text) {
      ZBHost *me = weak;
      if (!me) return;
      CFAbsoluteTime now = CFAbsoluteTimeGetCurrent(), start = MAX(now, me->_fillsDone);
      me->_fillsDone = start + (text ? 0.2 : 0.05);
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((start - now) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ZBHost *me = weak;
        if (!me) return;
        [me.view.window makeFirstResponder:me.view];
        press(node);
        if (!text) return;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 80 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
          [weak command:@"selectAll"];
          dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            [weak send:@{@"t": @"ime-commit", @"text": text}];
          });
        });
      });
    };
  }
  return self;
}

- (NSView *)view { return _page; }
- (NSString *)url { return _url; }
- (NSString *)title { return _title; }
- (BOOL)preciseScrolling { return _engine.preciseScrolling; }

- (void)send:(NSDictionary *)message {
  NSMutableDictionary *m = [message mutableCopy];
  m[@"tab"] = @(_number);
  [_engine send:m];
}

- (void)setAxPosted:(void (^)(id, NSString *, NSDictionary *))axPosted {
  _axPosted = [axPosted copy];
  _page.axTree.posted = _axPosted;
}

/// Opens this tab in the browser app: at first, and again after the app restarts.
- (void)reopen {
  NSMutableDictionary *open = [@{@"t": @"open", @"tab": @(_number), @"url": _url, @"isolated": @(_isolated)} mutableCopy];
  if (self.session.length) open[@"session"] = self.session;
  [_engine send:open];
  [self sendSize];
  ZBAXTree *tree = [ZBAXTree new];
  tree.view = _page;
  tree.press = _page.axTree.press;
  tree.fill = _page.axTree.fill;
  tree.posted = _page.axTree.posted;
  _page.axTree = tree;
  if (_page.axEnabled) [self send:@{@"t": @"ax", @"on": @YES}];
}

- (void)sendSize {
  if (_placeObservers) [self sendPlace];
  NSSize s = _page.bounds.size;
  // A window on no display still needs frames on some display's clock: without them Chromium paints nothing and drops
  // every click (it finds what is under the mouse in its frames).
  NSNumber *display = (_page.window.screen ?: (_page.window ? NSScreen.mainScreen : nil)).deviceDescription[@"NSScreenNumber"];
  if (display) [_engine send:@{@"t": @"display", @"id": display}];
  [self send:@{@"t": @"size", @"w": @((int)s.width), @"h": @((int)s.height), @"scale": @(_page.window.backingScaleFactor ?: 2)}];
}

- (void)load:(NSString *)url {
  _url = url;
  [self send:@{@"t": @"load", @"url": url}];
}

- (void)command:(NSString *)name { [self send:@{@"t": @"cmd", @"name": name}]; }
- (void)find:(NSString *)text forward:(BOOL)forward next:(BOOL)next {
  [self send:@{@"t": @"find", @"text": text, @"forward": @(forward), @"next": @(next), @"matchCase": @NO}];
}
- (void)stopFinding { [self send:@{@"t": @"stop-find"}]; }
- (void)setZoomLevel:(double)level { [self send:@{@"t": @"zoom", @"level": @(level)}]; }
- (void)setHidden:(BOOL)hidden {
  _tabHidden = hidden;
  [self send:@{@"t": @"hidden", @"on": @(hidden)}];
  if (_placeObservers) [self sendPlace];
}
- (void)devDialog:(BOOL)open { [self send:@{@"t": @"dev-dialog", @"open": @(open)}]; }
- (void)devUnhookedDialog { [self send:@{@"t": @"dev-dialog", @"open": @YES, @"unhooked": @YES}]; }
- (void)devMoveDialog { [self send:@{@"t": @"dev-move-dialog"}]; }
- (void)devAskDialogState {
  _devDialogState = nil;
  [self send:@{@"t": @"dev-dialog-state"}];
}
- (NSDictionary *)devDialogState { return _devDialogState; }
- (void)devClickShield { [self send:@{@"t": @"dev-shield-click"}]; }
- (NSInteger)devKeptUnder { return _devKeptUnder; }
- (BOOL)devKeepsZeroActive { return _devDialogKeeps && _devShieldKeeps; }

// MARK: Its dialog's place

// Where the page is on the screen, and whether its window shows (not hidden, minimised, on another Space, or this tab
// hidden): for the browser app to keep the dialog centred on it, just above its window.
- (void)sendPlace {
  NSWindow *w = _page.window;
  NSRect r = w ? [w convertRectToScreen:[_page convertRect:_page.bounds toView:nil]] : NSZeroRect;
  NSRect c = w && self.modalArea ? [w convertRectToScreen:self.modalArea()] : NSZeroRect;
  BOOL visible = w.isVisible && !w.isMiniaturized && w.isOnActiveSpace && !NSApp.isHidden && !_tabHidden && (!self.inView || self.inView());
  _placed = @{@"x": @(r.origin.x), @"y": @(r.origin.y), @"w": @(r.size.width), @"h": @(r.size.height), @"cx": @(c.origin.x),
              @"cy": @(c.origin.y), @"cw": @(c.size.width), @"ch": @(c.size.height), @"window": @(w.windowNumber),
              @"visible": @(visible)};
  NSMutableDictionary *m = [_placed mutableCopy];
  m[@"t"] = @"place";
  [self send:m];
}

- (void)printToPDF:(NSString *)path paper:(NSSize)inches done:(void (^)(BOOL))done {
  if (!_pdfs) _pdfs = [NSMutableDictionary dictionary];
  _pdfs[path] = [done copy];
  [self send:@{@"t": @"pdf", @"path": path, @"w": @(inches.width), @"h": @(inches.height)}];
}

- (void)placeDialog {
  if (_placeObservers) [self sendPlace];
}

- (void)startPlacing {
  if (!_placeObservers) {
    _placeObservers = [NSMutableArray array];
    __weak ZBHost *weak = self;
    void (^place)(NSNotification *) = ^(NSNotification *) { [weak sendPlace]; };
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    for (NSNotificationName name in @[
           NSWindowDidMoveNotification, NSWindowDidResizeNotification, NSWindowDidMiniaturizeNotification,
           NSWindowDidDeminiaturizeNotification, NSWindowDidBecomeKeyNotification, NSWindowDidBecomeMainNotification,
           NSWindowDidChangeOcclusionStateNotification,
           NSWindowDidChangeScreenNotification, NSWindowWillCloseNotification
         ])
      [_placeObservers addObject:[center addObserverForName:name object:_page.window queue:nil usingBlock:place]];
    for (NSNotificationName name in @[NSApplicationDidHideNotification, NSApplicationDidUnhideNotification, NSApplicationDidBecomeActiveNotification])
      [_placeObservers addObject:[center addObserverForName:name object:nil queue:nil usingBlock:place]];
    // A click anywhere in Zero brings its window above the dialog: the dialog above it again once the click is
    // handled (the click itself goes on as ever: the dialog is its tab's, not the app's).
    _clickMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown | NSEventMaskRightMouseDown |
                                                                  NSEventMaskOtherMouseDown | NSEventMaskLeftMouseUp
                                                          handler:^NSEvent *(NSEvent *event) {
                                                            [weak keepUnder:event];
                                                            dispatch_async(dispatch_get_main_queue(), ^{
                                                              if (!weak.devHoldPlace) [weak sendPlace];
                                                            });
                                                            return event;
                                                          }];
    [_placeObservers addObject:[NSWorkspace.sharedWorkspace.notificationCenter addObserverForName:NSWorkspaceActiveSpaceDidChangeNotification
                                                                                           object:nil
                                                                                            queue:nil
                                                                                       usingBlock:place]];
  }
  [self sendPlace];
}

// A click in the page's window while its dialog shows, with Zero or the browser app in front: the window stays where it
// is, under the dialog and its shield, rather than coming forward over them until they're ordered again (frames in which
// the dialog is gone). From another app, the window comes forward as ever, and the dialog follows it.
- (void)keepUnder:(NSEvent *)event {
  if (!_dialogUp || event.window != _page.window || event.type == NSEventTypeLeftMouseUp) return;
  BOOL front = NSApp.isActive || self.devActive ||
               NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier == _engine.pid;
  if (!front) return;
  [NSApp preventWindowOrdering];
  // And if the window server brought it forward anyway, back under the shield in the same event.
  if (_shield) [_page.window orderWindow:NSWindowBelow relativeTo:_shield];
  _devKeptUnder++;
}

- (void)stopPlacing {
  for (id o in _placeObservers) {
    [NSNotificationCenter.defaultCenter removeObserver:o];
    [NSWorkspace.sharedWorkspace.notificationCenter removeObserver:o];
  }
  _placeObservers = nil;
  if (_clickMonitor) [NSEvent removeMonitor:_clickMonitor];
  _clickMonitor = nil;
  _placed = nil;
}


- (void)close {
  [self stopPlacing];
  [self send:@{@"t": @"close"}];
  [_engine forget:self];
}

- (void)cdp:(NSString *)method params:(NSDictionary *)params completion:(void (^)(BOOL, NSString *))done {
  int rid = ++_nextRequest;
  _pending[@(rid)] = done;
  [self send:@{@"t": @"cdp", @"id": @(rid), @"method": method, @"params": params ?: @{}}];
}

- (void)evaluate:(NSString *)expression completion:(void (^)(BOOL, NSString *))done {
  int rid = ++_nextRequest;
  _pending[@(rid)] = done;
  [self send:@{@"t": @"eval", @"id": @(rid), @"expr": expression}];
}

- (void)handle:(NSDictionary *)m {
  NSString *t = m[@"t"];
  if ([t isEqual:@"cdp-result"]) {
    void (^done)(BOOL, NSString *) = _pending[m[@"id"]];
    [_pending removeObjectForKey:m[@"id"]];
    if (done) done([m[@"ok"] boolValue], m[@"json"]);
    return;
  }
  if ([t isEqual:@"address"]) _url = m[@"url"];
  else if ([t isEqual:@"title"]) _title = m[@"title"];
  else if ([t isEqual:@"editing"]) _editing = [m[@"on"] boolValue];
  else if ([t isEqual:@"loading"]) {
    _loading = [m[@"loading"] boolValue];
    _back = [m[@"back"] boolValue];
    _forward = [m[@"forward"] boolValue];
  } else if ([t isEqual:@"cursor"]) {
    _cursorType = [m[@"type"] intValue];
    _page.pageCursor = Cursor(_cursorType);
  } else if ([t isEqual:@"caret"]) _page.caret = NSMakeRect([m[@"x"] doubleValue], [m[@"y"] doubleValue], [m[@"w"] doubleValue], [m[@"h"] doubleValue]);
  else if ([t isEqual:@"popup"]) {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _page.popup.hidden = ![m[@"show"] boolValue];
    _popupShown = [m[@"show"] boolValue];
    if (m[@"w"]) _page.popup.frame = CGRectMake([m[@"x"] doubleValue], [m[@"y"] doubleValue], [m[@"w"] doubleValue], [m[@"h"] doubleValue]);
    [CATransaction commit];
  } else if ([t isEqual:@"renderer-gone"]) {
    if (self.crashed) self.crashed([NSString stringWithFormat:@"renderer: status %@", m[@"status"]]);
  } else if ([t isEqual:@"ask"]) {
    NSNumber *ask = m[@"ask"];
    __weak ZBHost *weak = self;
    void (^answer)(NSDictionary *) = ^(NSDictionary *a) {
      NSMutableDictionary *r = [a ?: @{} mutableCopy];
      r[@"t"] = @"answer";
      r[@"ask"] = ask;
      [weak.engine send:r];
    };
    if (self.asked) self.asked(m, answer);
    else answer(@{});
    return;
  } else if ([t isEqual:@"outside"]) {
    if (self.outside) self.outside(m[@"url"]);
    return;
  } else if ([t isEqual:@"dialog-expected"]) {
    [self startPlacing];
    return;
  } else if ([t isEqual:@"dialog-shown"]) {
    [self startPlacing];
    _dialogUp = YES;
    _devDialogKeeps = [m[@"keepsZeroActive"] boolValue];
    if (self.dialogShown) self.dialogShown(YES);
    return;
  } else if ([t isEqual:@"dev-dialog-state"]) {
    _devDialogState = m;
    return;
  } else if ([t isEqual:@"shield"]) {
    _shield = [m[@"window"] integerValue];
    _devShieldKeeps = [m[@"keepsZeroActive"] boolValue];
    return;
  } else if ([t isEqual:@"dialog-gone"]) {
    [self stopPlacing];
    _dialogUp = NO;
    _shield = 0;
    if (self.dialogShown) self.dialogShown(NO);
    // The front back to Zero, if the browser app still has it.
    if (NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier == _engine.pid) [NSApp activate];
    return;
  } else if ([t isEqual:@"fullscreen"]) {
    if (self.fullscreen) self.fullscreen([m[@"on"] boolValue]);
    return;
  } else if ([t isEqual:@"print"]) {
    if (self.printAsked) self.printAsked();
    return;
  } else if ([t isEqual:@"pdf-done"]) {
    void (^done)(BOOL) = _pdfs[m[@"path"]];
    [_pdfs removeObjectForKey:m[@"path"]];
    if (done) done([m[@"ok"] boolValue]);
    return;
  } else if ([t isEqual:@"new-tab"]) {
    if (self.opened) self.opened(m);
    return;
  } else if ([t isEqual:@"download"]) {
    if (self.downloaded) self.downloaded(m);
    return;
  } else if ([t isEqual:@"find-result"]) {
    if (self.found) self.found([m[@"count"] intValue], [m[@"active"] intValue], [m[@"final"] boolValue]);
    return;
  } else if ([t isEqual:@"drag-start"]) {
    // Chromium began dragging something in the page: follow the mouse until it drops or leaves.
    _page.pageDrag = m;
    _page.pageDragging = YES;
    [self send:@{@"t": @"drag-enter", @"own": @YES, @"x": m[@"x"], @"y": m[@"y"], @"ops": m[@"ops"]}];
    return;
  } else if ([t isEqual:@"ax-tree"]) {
    ZBAXNode *focused = _page.axTree.focused;
    [_page.axTree apply:m[@"json"]];
    NSAccessibilityPostNotification(_page, NSAccessibilityLayoutChangedNotification);
    if (_page.axTree.focused && _page.axTree.focused != focused)
      NSAccessibilityPostNotification(_page.axTree.focused, NSAccessibilityFocusedUIElementChangedNotification);
    return;
  } else if ([t isEqual:@"ax-loc"]) {
    [_page.axTree move:m[@"json"]];
    return;
  }
  if (self.changed) self.changed(_url, _title, _loading, _back, _forward);
}

- (void)showFrame:(id)surface popup:(BOOL)popup {
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  if (popup) _page.popup.contents = surface;
  else _page.layer.contents = surface;
  [CATransaction commit];
}

- (void)engineCrashed:(NSString *)why {
  _loading = NO;
  _cursorType = 0;
  if (self.crashed) self.crashed(why);
}
@end

// MARK: - The browser app's process

// A code requirement for `identifier` signed by this code's own team (any build's: Zero's official one, or one built
// from source under another team); unsigned, the identifier alone, as zerod checks.
static NSString *SignedAs(NSString *identifier) {
  static NSString *team;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    SecCodeRef me = NULL;
    CFDictionaryRef info = NULL;
    if (SecCodeCopySelf(kSecCSDefaultFlags, &me) == errSecSuccess &&
        SecCodeCopySigningInformation(me, kSecCSSigningInformation, &info) == errSecSuccess)
      team = [((__bridge NSDictionary *)info)[(__bridge NSString *)kSecCodeInfoTeamIdentifier] copy];
    if (info) CFRelease(info);
    if (me) CFRelease(me);
  });
  if (!team.length) return [NSString stringWithFormat:@"identifier \"%@\"", identifier];
  return [NSString stringWithFormat:@"anchor apple generic and certificate leaf[subject.OU] = \"%@\" and identifier \"%@\"", team, identifier];
}

@implementation ZBEngine {
  NSString *_app, *_identifier, *_requirement;
  NSArray<NSString *> *_outside;
  int _socket;
  mach_port_t _port;
  BOOL _trusted, _quitting;
  dispatch_source_t _read, _exit, _mach;
  NSMutableData *_buffer;
  NSMutableDictionary<NSNumber *, id> *_surfaces;
  NSMutableArray<ZBHost *> *_tabs;
  int _nextTab;
}

- (instancetype)initWithBrowserApp:(NSString *)path {
  if ((self = [super init])) {
    _app = path;
    // The browser app is held to its own identifier, signed by this app's team.
    _identifier = [NSBundle bundleWithPath:path].bundleIdentifier ?: @"com.arsen.zero.browser";
    _requirement = SignedAs(_identifier);
    _socket = -1;
    _beginFrames = YES;
    _preciseScrolling = YES;
    _tabs = [NSMutableArray array];
    // Numbered from this process's own range: after Zero.app restarts, its tabs never take the numbers of the last one's, which
    // zerod's browser app may still be closing. ponytail: pid-based, collides only across 1000 pids apart.
    _nextTab = (getpid() % 1000) * 1000;
  }
  return self;
}

- (BOOL)running { return _pid != 0; }
- (NSArray<ZBHost *> *)tabs { return [_tabs copy]; }

- (ZBHost *)openTab:(NSString *)url isolated:(BOOL)isolated {
  ZBHost *tab = [[ZBHost alloc] initWithEngine:self number:++_nextTab url:url isolated:isolated];
  [_tabs addObject:tab];
  if (_pid) [tab reopen];
  return tab;
}

- (void)forget:(ZBHost *)tab { [_tabs removeObject:tab]; }

- (void)setOutside:(NSArray<NSString *> *)prefixes {
  if ([prefixes isEqual:_outside]) return;
  _outside = [prefixes copy];
  [self send:@{@"t": @"outside", @"prefixes": _outside}];
}

- (void)watch {
  _surfaces = [NSMutableDictionary dictionary];
  _trusted = NO;
  _quitting = NO;
  __weak ZBEngine *weak = self;
  _exit = dispatch_source_create(DISPATCH_SOURCE_TYPE_PROC, _pid, DISPATCH_PROC_EXIT, dispatch_get_main_queue());
  dispatch_source_set_event_handler(_exit, ^{ [weak exited]; });
  dispatch_resume(_exit);
}

// The control channel is up: options first, then every open tab where it was.
- (void)controlled:(int)fd {
  _socket = fd;
  _buffer = [NSMutableData data];
  __weak ZBEngine *weak = self;
  _read = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, _socket, 0, dispatch_get_main_queue());
  dispatch_source_set_event_handler(_read, ^{ [weak readSocket]; });
  dispatch_resume(_read);
  [self send:@{@"t": @"options", @"beginFrames": @(_beginFrames)}];
  [self send:@{@"t": @"outside", @"prefixes": _outside ?: @[]}];
  for (ZBHost *tab in [_tabs copy]) [tab reopen];
}

- (void)connectToPid:(pid_t)pid {
  if (_pid) return;
  _pid = pid;
  _socket = -1;
  [self watch];
  [self lookUp:0];
}

// zerod's browser app checks its name in just after it starts: looked for a few seconds, without blocking.
- (void)lookUp:(int)attempt {
  if (!_pid || _port) return;
  mach_port_t service = MACH_PORT_NULL;
  if (bootstrap_look_up(bootstrap_port, [self framesName].UTF8String, &service) == KERN_SUCCESS) return [self hello:service];
  if (attempt >= 100) return;
  __weak ZBEngine *weak = self;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ [weak lookUp:attempt + 1]; });
}

- (void)quit {
  if (_pid) [self stop];
}

- (void)exited {
  // Not this process's child (zerod started it): no status, only whether it said it was quitting.
  BOOL clean = _quitting;
  NSString *why = @"it quit unexpectedly";
  [self stop];
  if (clean) {
    if (self.stopped) self.stopped();
    return;
  }
  for (ZBHost *tab in [_tabs copy]) [tab engineCrashed:why];
  if (self.crashed) self.crashed(why);
}

- (void)stop {
  if (_read) dispatch_source_cancel(_read);
  if (_exit) dispatch_source_cancel(_exit);
  if (_mach) dispatch_source_cancel(_mach);
  _read = _exit = _mach = nil;
  if (_socket >= 0) close(_socket);
  _socket = -1;
  if (_port) mach_port_mod_refs(mach_task_self(), _port, MACH_PORT_RIGHT_RECEIVE, -1);
  _port = MACH_PORT_NULL;
  _pid = 0;
  [_surfaces removeAllObjects];
}

- (void)send:(NSDictionary *)message {
  if (_socket < 0) return;
  NSMutableData *data = [[NSJSONSerialization dataWithJSONObject:message options:0 error:nil] mutableCopy];
  [data appendBytes:"\n" length:1];
  const char *p = data.bytes;
  size_t left = data.length;
  while (left) {
    ssize_t n = write(_socket, p, left);
    if (n <= 0) return;
    p += n;
    left -= n;
  }
}

- (void)readSocket {
  char chunk[65536];
  ssize_t n = read(_socket, chunk, sizeof chunk);
  if (n <= 0) return;
  [_buffer appendBytes:chunk length:n];
  while (YES) {
    const char *bytes = _buffer.bytes;
    const char *nl = memchr(bytes, '\n', _buffer.length);
    if (!nl) break;
    NSData *line = [_buffer subdataWithRange:NSMakeRange(0, nl - bytes)];
    [_buffer replaceBytesInRange:NSMakeRange(0, nl - bytes + 1) withBytes:NULL length:0];
    NSDictionary *m = [NSJSONSerialization JSONObjectWithData:line options:0 error:nil];
    if (![m isKindOfClass:NSDictionary.class]) continue;
    if ([m[@"t"] isEqual:@"ready"]) {
      [self connectFrames:m[@"mach"]];
      continue;
    }
    if ([m[@"t"] isEqual:@"quitting"]) {
      _quitting = YES;
      continue;
    }
    if ([m[@"t"] isEqual:@"closed"]) {
      if (_quitting) continue;  // every tab closes as it quits; they open again with the next one
      for (ZBHost *tab in [_tabs copy])
        if (tab.number == [m[@"tab"] intValue]) {
          [_tabs removeObject:tab];
          if (self.tabClosed) self.tabClosed(tab);
        }
      continue;
    }
    if ([m[@"t"] isEqual:@"agent-tab"]) {
      ZBHost *tab = nil;
      for (ZBHost *known in _tabs)
        if (known.number == [m[@"tab"] intValue]) tab = known;
      if (!tab) {
        tab = [[ZBHost alloc] initWithEngine:self number:[m[@"tab"] intValue] url:m[@"url"] ?: @"" isolated:NO];
        [tab handle:@{@"t": @"title", @"title": m[@"title"] ?: @""}];
        [_tabs addObject:tab];
      }
      tab.session = m[@"session"] ?: @"";
      if (self.agentTab) self.agentTab(tab, tab.session);
      continue;
    }
    for (ZBHost *tab in [_tabs copy])
      if (tab.number == [m[@"tab"] intValue]) [tab handle:m];
  }
}

// The browser app checked in a Mach name of its own pid; send it the port frames come to.
- (void)connectFrames:(NSString *)name {
  if (![name isEqual:[self framesName]]) return;
  mach_port_t service = MACH_PORT_NULL;
  if (bootstrap_look_up(bootstrap_port, name.UTF8String, &service) != KERN_SUCCESS) return;
  [self hello:service];
}

- (NSString *)framesName { return [NSString stringWithFormat:@"%@.frames.%d", _identifier, _pid]; }

- (void)hello:(mach_port_t)service {
  mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &_port);
  HelloMsg hello = {0};
  hello.h.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0) | MACH_MSGH_BITS_COMPLEX;
  hello.h.msgh_remote_port = service;
  hello.h.msgh_size = sizeof hello;
  hello.h.msgh_id = kMsgHello;
  hello.body.msgh_descriptor_count = 1;
  hello.port.name = _port;
  hello.port.disposition = MACH_MSG_TYPE_MAKE_SEND;
  hello.port.type = MACH_MSG_PORT_DESCRIPTOR;
  mach_msg(&hello.h, MACH_SEND_MSG | MACH_SEND_TIMEOUT, sizeof hello, 0, MACH_PORT_NULL, 1000, MACH_PORT_NULL);
  mach_port_deallocate(mach_task_self(), service);
  __weak ZBEngine *weak = self;
  _mach = dispatch_source_create(DISPATCH_SOURCE_TYPE_MACH_RECV, _port, 0, dispatch_get_main_queue());
  dispatch_source_set_event_handler(_mach, ^{ [weak receiveFrames]; });
  dispatch_resume(_mach);
}

- (void)receiveFrames {
  while (_port) {
    struct { union { SurfaceMsg s; FrameMsg f; } m; mach_msg_audit_trailer_t trailer; } r;
    memset(&r, 0, sizeof r);
    kern_return_t kr = mach_msg(&r.m.s.h, MACH_RCV_MSG | MACH_RCV_TIMEOUT | MACH_RCV_TRAILER_TYPE(MACH_MSG_TRAILER_FORMAT_0) |
                                MACH_RCV_TRAILER_ELEMENTS(MACH_RCV_TRAILER_AUDIT), 0, sizeof r, _port, 0, MACH_PORT_NULL);
    if (kr != KERN_SUCCESS) return;
    // The audit trailer sits right after the message body.
    mach_msg_audit_trailer_t *trailer = (mach_msg_audit_trailer_t *)((char *)&r.m + round_msg(r.m.s.h.msgh_size));
    pid_t sender = (pid_t)trailer->msgh_audit.val[5];
    if (sender != _pid || (!_trusted && !(_trusted = Trusted(trailer->msgh_audit, _requirement)))) {
      mach_msg_destroy(&r.m.s.h);
      continue;
    }
    if (r.m.s.h.msgh_id == kMsgControl && _socket < 0) {
      // zerod's browser app answered the hello with the control channel: from its pid, signed as it.
      int fd = fileport_makefd(r.m.s.port.name);
      mach_port_deallocate(mach_task_self(), r.m.s.port.name);
      if (fd >= 0) [self controlled:fd];
      continue;
    }
    if (r.m.s.h.msgh_id == kMsgSurface) {
      IOSurfaceRef surface = IOSurfaceLookupFromMachPort(r.m.s.port.name);
      mach_port_deallocate(mach_task_self(), r.m.s.port.name);
      if (surface) _surfaces[@(r.m.s.id)] = (__bridge_transfer id)surface;
      // Old sizes' surfaces go once a tab has three of a newer one (ids only grow).
      for (NSNumber *old in _surfaces.allKeys)
        if (old.unsignedIntValue + 12 * MAX(1u, (unsigned)_tabs.count) < r.m.s.id) [_surfaces removeObjectForKey:old];
    } else if (r.m.s.h.msgh_id == kMsgFrame) {
      id surface = _surfaces[@(r.m.f.id)];
      if (!surface) continue;
      for (ZBHost *tab in [_tabs copy])
        if (tab.number == (int)r.m.f.tab) [tab showFrame:surface popup:r.m.f.popup != 0];
    }
  }
}
@end
