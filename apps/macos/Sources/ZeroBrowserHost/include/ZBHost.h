#import <AppKit/AppKit.h>
#import "ZBAccessibility.h"

NS_ASSUME_NONNULL_BEGIN

@class ZBHost;

/// Zero's side of Zero Browser: the browser app's process, which zerod starts. It connects to it, checks it is ours,
/// receives every tab's frames over Mach and sends input over the channel the app hands it. One process hosts every tab.
@interface ZBEngine : NSObject
- (instancetype)initWithBrowserApp:(NSString *)path;
/// Connects to the browser app zerod started (Zero's way: zerod owns it, and answers Zero.app with its pid). The
/// channel to it comes back over Mach from that pid, signed as Zero Browser; then every open tab reopens. When it goes,
/// `stopped` (it quit, zerod stopping it) or `crashed`; connect again after asking zerod again.
- (void)connectToPid:(pid_t)pid;
/// Closes every tab and stops the browser app cleanly (it writes its cookies and storage out first). Connected to
/// zerod's: closes this app's tabs only; zerod keeps it running.
- (void)quit;
@property (nonatomic, readonly) BOOL running;
@property (nonatomic, readonly) pid_t pid;
/// Frames on the display's clock (CEF external begin frames), and trackpad deltas as exact. Both on by default.
@property (nonatomic) BOOL beginFrames;
@property (nonatomic) BOOL preciseScrolling;
/// The browser app died (every tab shows it), or stopped as asked.
@property (nonatomic, copy, nullable) void (^crashed)(NSString *why);
@property (nonatomic, copy, nullable) void (^stopped)(void);
- (ZBHost *)openTab:(NSString *)url isolated:(BOOL)isolated;
/// A tab an agent opened (through zerod's tools), for the task `session`: told once it's the task's, and again each
/// time Zero.app connects. The tab is in `tabs` from then on, as Zero.app's own are.
@property (nonatomic, copy, nullable) void (^agentTab)(ZBHost *tab, NSString *session);
/// Links that open in their apps rather than in the page, by prefix (any scheme but the web's does too). Kept, and
/// sent again whenever the browser app connects.
- (void)setOutside:(NSArray<NSString *> *)prefixes;
/// A tab the browser app closed itself (an agent closed it): gone from `tabs`.
@property (nonatomic, copy, nullable) void (^tabClosed)(ZBHost *tab);
@property (nonatomic, readonly) NSArray<ZBHost *> *tabs;
@end

/// One tab: its page view and what it shows. Shaped like Zero's WebPage (address, title, loading, back, forward).
@interface ZBHost : NSObject
@property (nonatomic, readonly, weak) ZBEngine *engine;
@property (nonatomic, readonly) int number;
/// An agent's tab: its task (Zero Browser reopens it as that task's after a restart); nil for the user's own.
@property (nonatomic, copy, nullable) NSString *session;
@property (nonatomic, readonly) BOOL isolated;
/// A text field in the page has the keyboard (an input, a textarea, an editor).
@property (nonatomic, readonly) BOOL editing;
- (void)load:(NSString *)url;
- (void)command:(NSString *)name;
/// Hidden tabs neither paint nor run their timers at full rate (CEF's WasHidden for off-screen browsers).
- (void)setHidden:(BOOL)hidden;
- (void)close;
@property (nonatomic, readonly) NSString *url;
@property (nonatomic, readonly) NSString *title;
@property (nonatomic, readonly) BOOL loading;
@property (nonatomic, copy, nullable) void (^changed)(NSString *url, NSString *title, BOOL loading, BOOL back, BOOL forward);
/// This tab's page died: its renderer, or the whole browser app.
@property (nonatomic, copy, nullable) void (^crashed)(NSString *why);
@property (nonatomic, readonly) NSView *view;
/// The DevTools protocol in the browser app, for this tab: a method's result, or an expression's.
- (void)cdp:(NSString *)method params:(nullable NSDictionary *)params completion:(void (^)(BOOL ok, NSString *json))done;
- (void)evaluate:(NSString *)expression completion:(void (^)(BOOL ok, NSString *json))done;
/// The page's cursor (CEF's cef_cursor_type_t) and whether a <select> popup shows, as last told.
@property (nonatomic, readonly) int cursorType;
@property (nonatomic, readonly) BOOL popupShown;
/// The browser app asks Zero: kind "menu" (items, x, y, link, selection, editable → command), "file" (mode, accept →
/// paths), "dialog" (type alert/confirm/prompt/beforeunload, message, default → ok, text), "media" / "permission"
/// (origin, wanted → allowed / result accept, deny, dismiss), "download" (name, url, size → path). No hook: cancelled.
@property (nonatomic, copy, nullable) void (^asked)(NSDictionary *question, void (^answer)(NSDictionary *answer));
/// The user clicked a link that opens in its app (setOutside): the page stayed put.
@property (nonatomic, copy, nullable) void (^outside)(NSString *url);
/// The page opened a window (target=_blank, window.open): url, background, gesture (a user's click or not).
@property (nonatomic, copy, nullable) void (^opened)(NSDictionary *request);
/// A download's progress: download, received, total, complete, canceled, path.
@property (nonatomic, copy, nullable) void (^downloaded)(NSDictionary *progress);
/// Find in page: matches and the active one, as Chromium counts them.
- (void)find:(NSString *)text forward:(BOOL)forward next:(BOOL)next;
- (void)stopFinding;
@property (nonatomic, copy, nullable) void (^found)(int count, int active, BOOL final);
/// Chrome's own dialog for this page (a passkey's) shows or went: a window of the browser app's, kept centred on the
/// page and just above its window while it shows (the page is dimmed under it).
@property (nonatomic, copy, nullable) void (^dialogShown)(BOOL shown);
/// The part of the page's window its dialog keeps to itself while it shows (the side panel's column), in the
/// window's coordinates: the browser app dims it and takes its clicks, giving the dialog the keyboard.
@property (nonatomic, copy, nullable) NSRect (^modalArea)(void);
/// The page's element fullscreen (requestFullscreen) on or off; Esc in the page leaves it.
@property (nonatomic, copy, nullable) void (^fullscreen)(BOOL on);
/// The page asks to print (its window.print(), or Print… in its menu).
@property (nonatomic, copy, nullable) void (^printAsked)(void);
/// What the page's accessibility tree posts for VoiceOver (announcements, values, states), for Zero Dev's checks.
@property (nonatomic, copy, nullable) void (^axPosted)(id element, NSString *name, NSDictionary *_Nullable info);
/// The page printed to a PDF at `path` (its print styles, on paper of `inches`); `done` says whether it was written.
- (void)printToPDF:(NSString *)path paper:(NSSize)inches done:(void (^)(BOOL ok))done;
/// Whether the page's tab is the one in view (its task shown, its panel open, it selected): its dialog hides otherwise.
@property (nonatomic, copy, nullable) BOOL (^inView)(void);
/// Its dialog placed again (what `inView` or `modalArea` says changed); nothing while none shows.
- (void)placeDialog;
/// The page's place last sent for its dialog (x, y, w, h on the screen; cx, cy, cw, ch its modal area on the screen;
/// window, visible); nil while none is expected.
@property (nonatomic, readonly, nullable) NSDictionary *placed;
/// Zero Dev only: a click in the page's window taken as if Zero were the active app (Zero Dev never is).
@property (nonatomic) BOOL devActive;
/// Zero Dev only: a click's place held back, so what Zero alone does with the click shows.
@property (nonatomic) BOOL devHoldPlace;
/// Zero Dev only: the clicks in the page's window kept from bringing it forward over the dialog.
@property (nonatomic, readonly) NSInteger devKeptUnder;
/// Zero Dev only: the browser app's dialog and shield take clicks and the keyboard without activating it.
@property (nonatomic, readonly) BOOL devKeepsZeroActive;
/// Zero Dev only: a stand-in dialog its page didn't say it asked for (the browser app goes by the tab last clicked).
- (void)devUnhookedDialog;
/// Zero Dev only: the dialog's and the shield's collection behaviour, level and activation, asked for and as answered.
- (void)devAskDialogState;
@property (nonatomic, readonly, nullable) NSDictionary *devDialogState;
/// Zero Dev only: the stand-in moved elsewhere, as Chrome moves its dialog.
- (void)devMoveDialog;
/// Zero Dev only: a click on the browser app's shield over the panel, posted there.
- (void)devClickShield;
/// Zero Dev only: the browser app's stand-in for a dialog, opened or closed (its browser ignores it otherwise).
- (void)devDialog:(BOOL)open;
/// Chromium's zoom level: 0 is 100 %, each step ×1.2.
- (void)setZoomLevel:(double)level;
@property (nonatomic, readonly) BOOL preciseScrolling;
@end

NS_ASSUME_NONNULL_END
