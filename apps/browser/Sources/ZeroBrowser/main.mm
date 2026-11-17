// Zero Browser: Chromium in its own app, off-screen, with no window of its own. An app draws its frames and sends its
// input (Zero.app's side panel):
// - The control channel: JSON lines both ways (input, size, navigation; address, title, cursor).
// - Frames go over Mach: this app checks in a name of its own pid, the app sends it a port, and each frame is a
//   copied IOSurface (sent once as a Mach port) and then its id.
// Started by zerod (Zero's own): fd 0 is zerod's connection, for the tools agents use. Zero.app gets the control
// channel over Mach: it sends a hello signed as Zero.app, and this app answers on the port it gave with its end of a
// new socket pair (a file port). Zero.app takes it only from this pid, signed as Zero Browser, so a process squatting
// the name gets nothing. Zero.app going closes its tabs; zerod going quits this app.
// Every end checks the other's code signature: the socket's maker from its audit token, Mach messages from their
// audit trailers. Nothing is taken from arguments or the environment.
#import <AppKit/AppKit.h>
#import <IOSurface/IOSurface.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <Security/Security.h>
#import <objc/message.h>
#include <mach/mach.h>
#include <pwd.h>
#include <signal.h>
#include <servers/bootstrap.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#include <map>
#include <memory>
#include <string>
#include <set>
#include <vector>

#include "include/cef_app.h"
#include "include/cef_application_mac.h"
#include "include/cef_browser.h"
#include "include/cef_client.h"
#include "include/cef_devtools_message_observer.h"
#include "include/cef_parser.h"
#include "include/wrapper/cef_library_loader.h"

// The Mach messages (the host has the same three).
enum { kMsgSurface = 1, kMsgFrame = 2, kMsgHello = 3, kMsgControl = 4 };
struct SurfaceMsg { mach_msg_header_t h; mach_msg_body_t body; mach_msg_port_descriptor_t port; uint32_t id, w, h2, popup, tab; };
struct FrameMsg { mach_msg_header_t h; uint32_t id, popup; int32_t x, y; double painted, copied; uint32_t tab; };
struct HelloMsg { mach_msg_header_t h; mach_msg_body_t body; mach_msg_port_descriptor_t port; };
// To Zero.app, after its hello: its end of the control channel, as a file port.
struct ControlMsg { mach_msg_header_t h; mach_msg_body_t body; mach_msg_port_descriptor_t port; };
extern "C" int fileport_makeport(int fd, mach_port_t *port);

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
// The app that shows its pages: its identifier is this one's without ".browser" (com.arsen.zero.browser is
// com.arsen.zero's).
static std::string AppRequirement() {
  NSString *me = NSBundle.mainBundle.bundleIdentifier ?: @"";
  NSString *base = [me hasSuffix:@".browser"] ? [me substringToIndex:me.length - 8] : me;
  return SignedAs(base).UTF8String;
}
// Where the control channel is (-1 while no app is connected).
static int gControl = -1;

static bool Trusted(const audit_token_t &token, const char *requirement) {
  SecCodeRef code = nullptr;
  SecRequirementRef req = nullptr;
  NSDictionary *attrs = @{(__bridge id)kSecGuestAttributeAudit: [NSData dataWithBytes:&token length:sizeof token]};
  bool ok = SecCodeCopyGuestWithAttributes(nullptr, (__bridge CFDictionaryRef)attrs, kSecCSDefaultFlags, &code) == errSecSuccess &&
            SecRequirementCreateWithString((__bridge CFStringRef)@(requirement), kSecCSDefaultFlags, &req) == errSecSuccess &&
            SecCodeCheckValidity(code, kSecCSDefaultFlags, req) == errSecSuccess;
  if (code) CFRelease(code);
  if (req) CFRelease(req);
  return ok;
}

static void Log(NSString *line) { fprintf(stderr, "browser: %s\n", line.UTF8String); }

static void Send(NSDictionary *message) {
  NSMutableData *data = [[NSJSONSerialization dataWithJSONObject:message options:0 error:nil] mutableCopy];
  [data appendBytes:"\n" length:1];
  const char *p = (const char *)data.bytes;
  size_t left = data.length;
  while (left) {
    ssize_t n = gControl < 0 ? -1 : write(gControl, p, left);
    if (n <= 0) return;
    p += n;
    left -= n;
  }
}

static int Flags(NSDictionary *m) { return [m[@"mods"] intValue]; }

// CEF's event flags → the DevTools protocol's (Alt 1, Ctrl 2, Meta 4, Shift 8).
static int CdpModifiers(int f) { return ((f & (1 << 3)) ? 1 : 0) | ((f & (1 << 2)) ? 2 : 0) | ((f & (1 << 7)) ? 4 : 0) | ((f & (1 << 1)) ? 8 : 0); }

// A Mac key code → its DOM code, its key name when it prints nothing, and its Windows virtual key code.
struct KeyInfo { const char *code, *key; int vk; };
static KeyInfo Key(int mac) {
  switch (mac) {
    case 36: return {"Enter", "Enter", 13};
    case 76: return {"NumpadEnter", "Enter", 13};
    case 48: return {"Tab", "Tab", 9};
    case 49: return {"Space", nullptr, 32};
    case 51: return {"Backspace", "Backspace", 8};
    case 53: return {"Escape", "Escape", 27};
    case 117: return {"Delete", "Delete", 46};
    case 123: return {"ArrowLeft", "ArrowLeft", 37};
    case 124: return {"ArrowRight", "ArrowRight", 39};
    case 125: return {"ArrowDown", "ArrowDown", 40};
    case 126: return {"ArrowUp", "ArrowUp", 38};
    case 115: return {"Home", "Home", 36};
    case 119: return {"End", "End", 35};
    case 116: return {"PageUp", "PageUp", 33};
    case 121: return {"PageDown", "PageDown", 34};
    case 24: return {"Equal", nullptr, 187};
    case 27: return {"Minus", nullptr, 189};
    case 30: return {"BracketRight", nullptr, 221};
    case 33: return {"BracketLeft", nullptr, 219};
    case 39: return {"Quote", nullptr, 222};
    case 41: return {"Semicolon", nullptr, 186};
    case 42: return {"Backslash", nullptr, 220};
    case 43: return {"Comma", nullptr, 188};
    case 44: return {"Slash", nullptr, 191};
    case 47: return {"Period", nullptr, 190};
    case 50: return {"Backquote", nullptr, 192};
  }
  static const char *letters[] = {"KeyA", "KeyS", "KeyD", "KeyF", "KeyH", "KeyG", "KeyZ", "KeyX", "KeyC", "KeyV", "", "KeyB",
                                  "KeyQ", "KeyW", "KeyE", "KeyR", "KeyY", "KeyT", "Digit1", "Digit2", "Digit3", "Digit4",
                                  "Digit6", "Digit5", "", "Digit9", "Digit7", "", "Digit8", "Digit0", "", "KeyO", "KeyU",
                                  "", "KeyI", "KeyP", "", "KeyL", "KeyJ", "", "KeyK", "", "", "", "", "KeyN", "KeyM"};
  if (mac >= 0 && mac < (int)(sizeof letters / sizeof *letters) && *letters[mac]) {
    const char *c = letters[mac];
    int vk = c[0] == 'K' ? c[3] : c[5];  // 'A'…'Z' or '0'…'9'
    return {c, nullptr, vk};
  }
  return {"", "Unidentified", 0};
}


// A display link's tick as a block (the browser app has no view, so it asks the screen for one).
@interface Ticker : NSObject
@property (nonatomic, copy) void (^tick)(void);
- (void)fire:(CADisplayLink *)link;
@end
@implementation Ticker
- (void)fire:(CADisplayLink *)link { if (self.tick) self.tick(); }
@end

// MARK: - The app CEF needs

@interface BrowserApplication : NSApplication <CefAppProtocol> {
  BOOL _handling;
}
@end
@implementation BrowserApplication
- (BOOL)isHandlingSendEvent { return _handling; }
- (void)setHandlingSendEvent:(BOOL)v { _handling = v; }
- (void)sendEvent:(NSEvent *)event {
  CefScopedSendingEvent s;
  [super sendEvent:event];
}
@end

// Whether the user's default keychain is there: without one, a Keychain write puts "A keychain cannot be found" in
// front of the user, so Chromium keeps its key in memory instead (saved logins and cookies don't outlive the process).
static bool gNoKeychain = false;
#define kPasskeyAsked "zero:passkey-asked"
// A page's window.print(), told to Zero (kPrintAsked): Chrome's own printing on the Mac is its native print panel,
// a window of this app's with no place in Zero, so the page never reaches it.
#define kPrintAsked "zero:print-asked"
static void ExpectDialog(int tab, double seconds);
static void PlaceDialogs(NSDictionary *place);
static void DevDialog(int tab, bool open, bool hooked);
static void DevShieldClick();
static void DevMoveDialog();
static void DevDialogState();
// The tab the user last clicked or typed in: a dialog its page didn't say it asked for (kPasskeyAsked) is its.
static int gInputTab = 0;
static bool gDev = false;  // Zero Dev's browser (com.….dev.browser)

class PdfDone : public CefPdfPrintCallback {
 public:
  PdfDone(int tab, NSString *path) : tab_(tab), path_(path) {}
  void OnPdfPrintFinished(const CefString &, bool ok) override {
    ::Send(@{@"t": @"pdf-done", @"tab": @(tab_), @"path": path_, @"ok": @(ok)});
  }

 private:
  int tab_;
  NSString *path_;
  IMPLEMENT_REFCOUNTING(PdfDone);
};

class App : public CefApp {
 public:
  void OnBeforeCommandLineProcessing(const CefString &, CefRefPtr<CefCommandLine> line) override {
    if (gNoKeychain) line->AppendSwitch("use-mock-keychain");
  }
  IMPLEMENT_REFCOUNTING(App);
};

// MARK: - The process: its tabs, the port frames go to, the display clock

class Browser;
static std::map<int, CefRefPtr<Browser>> gTabs;
static mach_port_t gHost = MACH_PORT_NULL;
static bool gBeginFrames = false, gQuitting = false;
// Where a link the user clicks opens in its app rather than in the page: Zero.app's prefixes (Linear's, Slack's), and
// any scheme but the web's.
static NSArray<NSString *> *gOutside = @[];
static bool OpensOutside(NSString *url) {
  NSString *scheme = url.lowercaseString;
  NSRange colon = [scheme rangeOfString:@":"];
  if (colon.location == NSNotFound) return false;
  scheme = [scheme substringToIndex:colon.location];
  if (![@[@"http", @"https", @"about", @"data", @"blob", @"javascript", @"file", @"chrome", @"devtools", @"view-source"]
          containsObject:scheme])
    return true;
  for (NSString *prefix in gOutside)
    if ([url hasPrefix:prefix]) return true;
  return false;
}
static uint32_t gDisplay = 0, gNextSurface = 0;
static double gLastActive = 0;
static CADisplayLink *gLink = nil;
static NSTimer *gSlow = nil;
static Ticker *gTicker = nil;
static id<MTLDevice> gDevice = nil;
static id<MTLCommandQueue> gQueue = nil;
static void TickAll();
// Questions for Zero (a menu choice, files, a dialog, a permission, a download's place): each waits for its answer.
static std::map<int, void (^)(NSDictionary *)> gAsks;
static int gNextAsk = 0;
static void Idle(bool idle);
static void QuitWhenClosed();
// The tools page (below): told of tabs that went, and of debugger events on tabs it has the debugger on.
static void ToolsRemoved(int tab);
static void ToolsEvent(int tab, const std::string &method, const std::string &params);
static void ToolsMessage(int tab, const void *params, size_t size);
static std::string Json(id value);
static std::set<int> gDebugged;
static std::map<int, std::string> gOwners;  // an agent's tab → its task (session), shown in that task's side panel

// MARK: - One browser, off-screen

class Browser : public CefClient, public CefLifeSpanHandler, public CefDisplayHandler, public CefLoadHandler,
                public CefRenderHandler, public CefRequestHandler, public CefContextMenuHandler,
                public CefDevToolsMessageObserver, public CefAccessibilityHandler, public CefDialogHandler,
                public CefDownloadHandler, public CefFindHandler, public CefPermissionHandler, public CefJSDialogHandler {
 public:
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
  CefRefPtr<CefRenderHandler> GetRenderHandler() override { return this; }
  CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }
  CefRefPtr<CefContextMenuHandler> GetContextMenuHandler() override { return this; }
  CefRefPtr<CefAccessibilityHandler> GetAccessibilityHandler() override { return this; }
  CefRefPtr<CefDialogHandler> GetDialogHandler() override { return this; }
  CefRefPtr<CefDownloadHandler> GetDownloadHandler() override { return this; }
  CefRefPtr<CefFindHandler> GetFindHandler() override { return this; }
  CefRefPtr<CefPermissionHandler> GetPermissionHandler() override { return this; }
  CefRefPtr<CefJSDialogHandler> GetJSDialogHandler() override { return this; }

  /// Asks Zero; `answered` runs with its answer (or an empty one if the tab or the app goes first).
  void Ask(NSDictionary *question, void (^answered)(NSDictionary *)) {
    int ask = ++gNextAsk;
    gAsks[ask] = answered;
    NSMutableDictionary *m = [question mutableCopy];
    m[@"t"] = @"ask";
    m[@"ask"] = @(ask);
    Send(m);
  }

  // The page's menu: Zero draws it (its own popovers), with Chromium's items for what was clicked.
  bool RunContextMenu(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, CefRefPtr<CefContextMenuParams> params,
                      CefRefPtr<CefMenuModel> model, CefRefPtr<CefRunContextMenuCallback> callback) override {
    NSMutableArray *items = [NSMutableArray array];
    for (size_t i = 0; i < model->GetCount(); i++) {
      if (model->GetTypeAt(i) == MENUITEMTYPE_SEPARATOR) {
        [items addObject:@{@"separator": @YES}];
        continue;
      }
      if (model->GetTypeAt(i) == MENUITEMTYPE_SUBMENU) continue;
      // Chromium's labels carry Windows' accelerator marks ("Select &All"); "&&" is a real "&".
      NSString *label = [[@(model->GetLabelAt(i).ToString().c_str()) stringByReplacingOccurrencesOfString:@"&&" withString:@"\x01"]
                            stringByReplacingOccurrencesOfString:@"&" withString:@""];
      label = [label stringByReplacingOccurrencesOfString:@"\x01" withString:@"&"];
      [items addObject:@{@"id": @(model->GetCommandIdAt(i)), @"label": label,
                         @"enabled": @(model->IsEnabledAt(i))}];
    }
    Ask(@{@"kind": @"menu", @"x": @(params->GetXCoord()), @"y": @(params->GetYCoord()), @"items": items,
          @"link": @(params->GetLinkUrl().ToString().c_str()), @"selection": @(params->GetSelectionText().ToString().c_str()),
          @"editable": @(params->IsEditable())},
        ^(NSDictionary *a) {
          // Print… goes to Zero, as window.print() does (Chrome's would open its native panel).
          if ([a[@"command"] intValue] == MENU_ID_PRINT) {
            callback->Cancel();
            Send(@{@"t": @"print"});
          } else if (a[@"command"]) callback->Continue([a[@"command"] intValue], EVENTFLAG_NONE);
          else callback->Cancel();
        });
    return true;
  }

  // <input type=file>: Zero shows its own panel, as a sheet on its window.
  bool OnFileDialog(CefRefPtr<CefBrowser>, FileDialogMode mode, const CefString &title, const CefString &path,
                    const std::vector<CefString> &filters, const std::vector<CefString> &, const std::vector<CefString> &,
                    CefRefPtr<CefFileDialogCallback> callback) override {
    NSMutableArray *accept = [NSMutableArray array];
    for (auto &f : filters) [accept addObject:@(f.ToString().c_str())];
    static NSArray *modes = @[@"open", @"openMultiple", @"openFolder", @"save"];
    Ask(@{@"kind": @"file", @"mode": modes[MIN((size_t)mode, modes.count - 1)], @"title": @(title.ToString().c_str()),
          @"path": @(path.ToString().c_str()), @"accept": accept},
        ^(NSDictionary *a) {
          std::vector<CefString> paths;
          for (NSString *p in a[@"paths"]) paths.push_back(p.UTF8String);
          if (paths.empty()) callback->Cancel();
          else callback->Continue(paths);
        });
    return true;
  }

  // alert, confirm, prompt and "leave this page?": Zero's own, never a window from this faceless app. In an agent's
  // tab, the agent's: told as DevTools tells of one, answered with browser_dialog.
  void AgentDialog(NSString *type, const CefString &message, const CefString &prompt, CefRefPtr<CefJSDialogCallback> callback) {
    dialog = callback;
    ToolsEvent(tab, "Page.javascriptDialogOpening",
               Json(@{@"url": @((address.empty() ? url : address).c_str()), @"message": @(message.ToString().c_str()), @"type": type,
                      @"hasBrowserHandler": @YES, @"defaultPrompt": @(prompt.ToString().c_str())}));
  }
  bool OnJSDialog(CefRefPtr<CefBrowser>, const CefString &origin, JSDialogType type, const CefString &message,
                  const CefString &prompt, CefRefPtr<CefJSDialogCallback> callback, bool &) override {
    static NSArray *types = @[@"alert", @"confirm", @"prompt"];
    if (agent) {
      AgentDialog(types[MIN((size_t)type, types.count - 1)], message, prompt, callback);
      return true;
    }
    Ask(@{@"kind": @"dialog", @"type": types[MIN((size_t)type, types.count - 1)], @"origin": @(origin.ToString().c_str()),
          @"message": @(message.ToString().c_str()), @"default": @(prompt.ToString().c_str())},
        ^(NSDictionary *a) { callback->Continue([a[@"ok"] boolValue], [a[@"text"] ?: @"" UTF8String]); });
    return true;
  }
  bool OnBeforeUnloadDialog(CefRefPtr<CefBrowser>, const CefString &message, bool reload,
                            CefRefPtr<CefJSDialogCallback> callback) override {
    if (agent) {
      AgentDialog(@"beforeunload", message, "", callback);
      return true;
    }
    Ask(@{@"kind": @"dialog", @"type": @"beforeunload", @"message": @(message.ToString().c_str()), @"reload": @(reload)},
        ^(NSDictionary *a) { callback->Continue([a[@"ok"] boolValue], ""); });
    return true;
  }

  // Camera, microphone, screen; and the rest (location, notifications…): the user's call, through Zero.
  bool OnRequestMediaAccessPermission(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, const CefString &origin, uint32_t wanted,
                                      CefRefPtr<CefMediaAccessCallback> callback) override {
    Ask(@{@"kind": @"media", @"origin": @(origin.ToString().c_str()), @"wanted": @(wanted)},
        ^(NSDictionary *a) {
          uint32_t allowed = [a[@"allowed"] unsignedIntValue] & wanted;
          if (allowed) callback->Continue(allowed);
          else callback->Cancel();
        });
    return true;
  }
  bool OnShowPermissionPrompt(CefRefPtr<CefBrowser>, uint64_t, const CefString &origin, uint32_t wanted,
                              CefRefPtr<CefPermissionPromptCallback> callback) override {
    Ask(@{@"kind": @"permission", @"origin": @(origin.ToString().c_str()), @"wanted": @(wanted)},
        ^(NSDictionary *a) {
          NSString *r = a[@"result"];
          callback->Continue([r isEqual:@"accept"] ? CEF_PERMISSION_RESULT_ACCEPT
                             : [r isEqual:@"deny"] ? CEF_PERMISSION_RESULT_DENY : CEF_PERMISSION_RESULT_DISMISS);
        });
    return true;
  }

  // Downloads: Zero says where (or no), and hears how far each got.
  bool OnBeforeDownload(CefRefPtr<CefBrowser>, CefRefPtr<CefDownloadItem> item, const CefString &name,
                        CefRefPtr<CefBeforeDownloadCallback> callback) override {
    Ask(@{@"kind": @"download", @"name": @(name.ToString().c_str()), @"url": @(item->GetURL().ToString().c_str()),
          @"size": @(item->GetTotalBytes()), @"download": @(item->GetId())},
        ^(NSDictionary *a) {
          if ([a[@"path"] length]) callback->Continue([a[@"path"] UTF8String], false);
        });
    return true;
  }
  void OnDownloadUpdated(CefRefPtr<CefBrowser>, CefRefPtr<CefDownloadItem> item, CefRefPtr<CefDownloadItemCallback>) override {
    Send(@{@"t": @"download", @"download": @(item->GetId()), @"received": @(item->GetReceivedBytes()),
           @"total": @(item->GetTotalBytes()), @"complete": @(item->IsComplete()), @"canceled": @(item->IsCanceled()),
           @"path": @(item->GetFullPath().ToString().c_str())});
  }

  void OnFindResult(CefRefPtr<CefBrowser>, int, int count, const CefRect &, int active, bool final) override {
    Send(@{@"t": @"find-result", @"count": @(count), @"active": @(active), @"final": @(final)});
  }

  // Dragging from the page: Zero follows the mouse and drops back here (or hands the drag to macOS when it leaves).
  CefRefPtr<CefDragData> drag;
  bool StartDragging(CefRefPtr<CefBrowser>, CefRefPtr<CefDragData> data, DragOperationsMask ops, int x, int y) override {
    drag = data->Clone();
    Send(@{@"t": @"drag-start", @"ops": @(ops), @"x": @(x), @"y": @(y), @"text": @(data->GetFragmentText().ToString().c_str()),
           @"url": @(data->GetLinkURL().ToString().c_str()), @"isLink": @(data->IsLink())});
    return true;
  }

  // The page's accessibility tree, for VoiceOver: Chromium's updates as they come, as JSON; Zero keeps the tree.
  void OnAccessibilityTreeChange(CefRefPtr<CefValue> value) override {
    Send(@{@"t": @"ax-tree", @"json": @(CefWriteJSON(value, JSON_WRITER_DEFAULT).ToString().c_str())});
  }
  void OnAccessibilityLocationChange(CefRefPtr<CefValue> value) override {
    Send(@{@"t": @"ax-loc", @"json": @(CefWriteJSON(value, JSON_WRITER_DEFAULT).ToString().c_str())});
  }

  Browser(int tab, bool isolated, bool agent = false) : tab(tab), isolated(isolated), agent(agent) {}
  const int tab;
  const bool isolated;
  /// Opened by an agent's tools (zerod's), not by Zero.app: it outlives Zero.app's going.
  const bool agent;
  std::string address, title;
  bool loading = false;
  /// An agent's tab: the dialog open in it, which the agent answers (Page.handleJavaScriptDialog); and whether its
  /// tools' world has `zeroSend`, the way its content scripts' messages come out.
  CefRefPtr<CefJSDialogCallback> dialog;
  bool bound = false;
  int width = 800, height = 600;
  double scale = 2;
  bool hidden = false;
  CefRefPtr<CefBrowser> browser;
  std::string url = "about:blank";

  void Send(NSDictionary *message) {
    NSMutableDictionary *m = [message mutableCopy];
    m[@"tab"] = @(tab);
    ::Send(m);
  }

  // A link the user clicked that opens in its app (gOutside): the page stays put, and Zero.app opens it.
  bool OnBeforeBrowse(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame, CefRefPtr<CefRequest> request, bool user_gesture,
                      bool is_redirect) override {
    if (agent || !frame->IsMain() || !user_gesture || is_redirect) return false;
    NSString *url = @(request->GetURL().ToString().c_str());
    if (!OpensOutside(url)) return false;
    Send(@{@"t": @"outside", @"url": url});
    return true;
  }

  void OnAfterCreated(CefRefPtr<CefBrowser> b) override {
    browser = b;
    devtools_ = b->GetHost()->AddDevToolsMessageObserver(this);
    // A page that asks for a passkey says so (a console line, kPasskeyAsked): Chrome's passkey dialog (a window of its
    // own, not in the page) then goes with this tab (ExpectDialog). The call itself goes on as it was; autofill's quiet
    // requests (mediation "conditional") show no dialog and aren't told.
    // Every frame's window.print(), an agent's page's too (where it does nothing): never Chrome's print panel.
    Cdp(@"Page.addScriptToEvaluateOnNewDocument", @{@"runImmediately": @YES, @"source": @"window.print = function print() { console.debug('" kPrintAsked "'); };"}, nil);
    if (!agent)
      Cdp(@"Page.addScriptToEvaluateOnNewDocument", @{@"runImmediately": @YES, @"source": @"(() => { const c = navigator.credentials; if (!c) return; for (const n of ['get', 'create']) { const f = c[n].bind(c); c[n] = function (o) { if (o && o.publicKey && o.mediation !== 'conditional') console.debug('" kPasskeyAsked "'); return f(o); }; } })()"}, nil);
    if (url != createdWith_) b->GetMainFrame()->LoadURL(url);  // a load that came while it was being made
  }
  void OnBeforeClose(CefRefPtr<CefBrowser>) override {
    devtools_ = nullptr;
    browser = nullptr;
    Send(@{@"t": @"closed"});
    gDebugged.erase(tab);
    gOwners.erase(tab);
    ToolsRemoved(tab);
    CefRefPtr<Browser> keep = this;
    gTabs.erase(tab);
    QuitWhenClosed();
  }
  // A page opening a window (target=_blank, window.open): Zero opens it as a tab of its own.
  bool OnBeforePopup(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, int, const CefString &target, const CefString &,
                     WindowOpenDisposition disposition, bool gesture, const CefPopupFeatures &, CefWindowInfo &,
                     CefRefPtr<CefClient> &, CefBrowserSettings &, CefRefPtr<CefDictionaryValue> &, bool *) override {
    Send(@{@"t": @"new-tab", @"url": @(target.ToString().c_str()), @"background": @(disposition == CEF_WOD_NEW_BACKGROUND_TAB),
           @"gesture": @(gesture)});
    return true;
  }

  void OnAddressChange(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame, const CefString &u) override {
    if (!frame->IsMain()) return;
    address = u.ToString();
    Send(@{@"t": @"address", @"url": @(u.ToString().c_str())});
  }
  bool OnConsoleMessage(CefRefPtr<CefBrowser>, cef_log_severity_t, const CefString &message, const CefString &, int) override {
    if (message.ToString() == kPrintAsked) {
      if (!agent) Send(@{@"t": @"print"});
      return true;
    }
    if (agent || message.ToString() != kPasskeyAsked) return false;
    ExpectDialog(tab, 10);
    return true;
  }
  // A page's element fullscreen (a video's): Chromium sizes it to the page's area; Zero gives the page more of it.
  void OnFullscreenModeChange(CefRefPtr<CefBrowser>, bool fullscreen) override { Send(@{@"t": @"fullscreen", @"on": @(fullscreen)}); }
  void OnTitleChange(CefRefPtr<CefBrowser>, const CefString &title) override {
    this->title = title.ToString();
    Send(@{@"t": @"title", @"title": @(title.ToString().c_str())});
  }
  bool OnCursorChange(CefRefPtr<CefBrowser>, CefCursorHandle, cef_cursor_type_t type, const CefCursorInfo &) override {
    Send(@{@"t": @"cursor", @"type": @(type)});
    return true;
  }
  void OnLoadingStateChange(CefRefPtr<CefBrowser>, bool loading, bool back, bool forward) override {
    this->loading = loading;
    Send(@{@"t": @"loading", @"loading": @(loading), @"back": @(back), @"forward": @(forward)});
  }
  void OnRenderProcessTerminated(CefRefPtr<CefBrowser>, TerminationStatus status, int code, const CefString &) override {
    Send(@{@"t": @"renderer-gone", @"status": @(status), @"code": @(code)});
  }

  void GetViewRect(CefRefPtr<CefBrowser>, CefRect &rect) override { rect = CefRect(0, 0, width, height); }
  // Whether a text field in the page has the keyboard (Zero's ⌘Z undoes typing there, else reopens a closed tab).
  void OnVirtualKeyboardRequested(CefRefPtr<CefBrowser>, TextInputMode mode) override {
    Send(@{@"t": @"editing", @"on": @(mode != CEF_TEXT_INPUT_MODE_NONE)});
  }
  bool GetScreenInfo(CefRefPtr<CefBrowser>, CefScreenInfo &info) override {
    info.device_scale_factor = (float)scale;
    info.rect = info.available_rect = CefRect(0, 0, width, height);
    return true;
  }
  void OnPopupShow(CefRefPtr<CefBrowser>, bool show) override {
    if (!show) Send(@{@"t": @"popup", @"show": @NO});
  }
  void OnPopupSize(CefRefPtr<CefBrowser>, const CefRect &r) override {
    popupX_ = r.x;
    popupY_ = r.y;
    Send(@{@"t": @"popup", @"show": @YES, @"x": @(r.x), @"y": @(r.y), @"w": @(r.width), @"h": @(r.height)});
  }
  void OnImeCompositionRangeChanged(CefRefPtr<CefBrowser>, const CefRange &, const RectList &bounds) override {
    if (bounds.empty()) return;
    const CefRect &r = bounds.front();
    Send(@{@"t": @"caret", @"x": @(r.x), @"y": @(r.y), @"w": @(r.width), @"h": @(r.height)});
  }
  void OnPaint(CefRefPtr<CefBrowser>, PaintElementType, const RectList &, const void *, int, int) override {
    if (!warnedSoftware_++) Log(@"software paint: no shared texture");
  }

  // The frame is valid only inside this call: copy it into a surface this app owns, send that.
  void OnAcceleratedPaint(CefRefPtr<CefBrowser>, PaintElementType type, const RectList &,
                          const CefAcceleratedPaintInfo &info) override {
    if (gHost == MACH_PORT_NULL) return;
    double painted = CACurrentMediaTime();
    gLastActive = painted;
    bool popup = type == PET_POPUP;
    IOSurfaceRef src = (IOSurfaceRef)info.shared_texture_io_surface;
    size_t w = IOSurfaceGetWidth(src), h = IOSurfaceGetHeight(src);
    Ring &ring = popup ? popup_ : view_;
    if (!gDevice) {
      gDevice = MTLCreateSystemDefaultDevice();
      gQueue = [gDevice newCommandQueue];
    }
    if (w != ring.w || h != ring.h) {
      ring.surfaces.clear();
      ring.ids.clear();
      for (int i = 0; i < 3; i++) {
        NSDictionary *props = @{(id)kIOSurfaceWidth: @(w), (id)kIOSurfaceHeight: @(h), (id)kIOSurfaceBytesPerElement: @4,
                                (id)kIOSurfacePixelFormat: @(IOSurfaceGetPixelFormat(src))};
        IOSurfaceRef s = IOSurfaceCreate((__bridge CFDictionaryRef)props);
        ring.surfaces.push_back((__bridge_transfer id)s);
        uint32_t id = ++gNextSurface;
        ring.ids.push_back(id);
        SurfaceMsg m = {};
        m.h.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0) | MACH_MSGH_BITS_COMPLEX;
        m.h.msgh_remote_port = gHost;
        m.h.msgh_size = sizeof m;
        m.h.msgh_id = kMsgSurface;
        m.body.msgh_descriptor_count = 1;
        m.port.name = IOSurfaceCreateMachPort(s);
        m.port.disposition = MACH_MSG_TYPE_MOVE_SEND;
        m.port.type = MACH_MSG_PORT_DESCRIPTOR;
        m.id = id;
        m.w = (uint32_t)w;
        m.h2 = (uint32_t)h;
        m.popup = popup;
        m.tab = tab;
        mach_msg(&m.h, MACH_SEND_MSG | MACH_SEND_TIMEOUT, sizeof m, 0, MACH_PORT_NULL, 100, MACH_PORT_NULL);
      }
      ring.w = w;
      ring.h = h;
    }
    size_t i = ring.next++ % ring.surfaces.size();
    IOSurfaceRef dst = (__bridge IOSurfaceRef)ring.surfaces[i];
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                 width:w height:h mipmapped:NO];
    id<MTLCommandBuffer> cb = [gQueue commandBuffer];
    id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
    [blit copyFromTexture:[gDevice newTextureWithDescriptor:d iosurface:src plane:0]
                toTexture:[gDevice newTextureWithDescriptor:d iosurface:dst plane:0]];
    [blit endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
    FrameMsg f = {};
    f.h.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0);
    f.h.msgh_remote_port = gHost;
    f.h.msgh_size = sizeof f;
    f.h.msgh_id = kMsgFrame;
    f.id = ring.ids[i];
    f.popup = popup;
    f.x = popupX_;
    f.y = popupY_;
    f.painted = painted;
    f.copied = CACurrentMediaTime();
    f.tab = tab;
    mach_msg(&f.h, MACH_SEND_MSG | MACH_SEND_TIMEOUT, sizeof f, 0, MACH_PORT_NULL, 100, MACH_PORT_NULL);
  }

  // The DevTools protocol, in this process: no port, no pipe.
  void OnDevToolsEvent(CefRefPtr<CefBrowser>, const CefString &method, const void *params, size_t size) override {
    if (method.ToString() == "Runtime.bindingCalled") return ToolsMessage(tab, params, size);
    if (gDebugged.count(tab)) ToolsEvent(tab, method.ToString(), std::string((const char *)params, size));
  }
  void OnDevToolsMethodResult(CefRefPtr<CefBrowser>, int id, bool ok, const void *result, size_t size) override {
    auto it = pending_.find(id);
    if (it == pending_.end()) return;
    NSString *json = [[NSString alloc] initWithBytes:result length:size encoding:NSUTF8StringEncoding] ?: @"{}";
    it->second(ok, json);
    pending_.erase(it);
  }
  void Cdp(NSString *method, NSDictionary *params, void (^done)(bool, NSString *)) {
    if (!browser) {
      if (done) done(false, @"no browser");
      return;
    }
    NSData *data = [NSJSONSerialization dataWithJSONObject:params ?: @{} options:0 error:nil];
    auto value = CefParseJSON(std::string((const char *)data.bytes, data.length), JSON_PARSER_RFC);
    int id = browser->GetHost()->ExecuteDevToolsMethod(0, method.UTF8String,
                                                       value ? value->GetDictionary() : CefDictionaryValue::Create());
    if (id && done) pending_[id] = done;
  }

  // A key, as Chromium's own Mac view sends it: with the edit commands macOS's text system chose
  // (doCommandBySelector:), which Blink then runs: deleteToBeginningOfLine for ⌘⌫, moveWordLeft for ⌥←…
  void SendKey(NSDictionary *m) {
    int mac = [m[@"code"] intValue];
    // Esc leaves a page's fullscreen (as in Chrome, which keeps the key from the page then): Alloy leaves it to us.
    if (mac == 53 && browser && browser->GetHost()->IsFullscreen()) {
      if (![m[@"kind"] isEqual:@"keyUp"]) browser->GetHost()->ExitFullscreen(true);
      return;
    }
    KeyInfo info = Key(mac);
    NSString *text = m[@"text"] ?: @"";
    NSString *kind = m[@"kind"];
    NSMutableDictionary *p = [@{@"type": kind, @"modifiers": @(CdpModifiers(Flags(m))), @"code": @(info.code),
                                @"windowsVirtualKeyCode": @(info.vk), @"nativeVirtualKeyCode": @(mac),
                                @"autoRepeat": @((Flags(m) & (1 << 13)) != 0), @"isKeypad": @((Flags(m) & (1 << 9)) != 0)} mutableCopy];
    NSString *printed = m[@"key"];
    p[@"key"] = info.key ? @(info.key) : (printed.length ? printed : @"Unidentified");
    if ([kind isEqual:@"char"]) {
      p[@"text"] = text;
      p[@"unmodifiedText"] = m[@"unmod"] ?: text;
    }
    if ([m[@"commands"] count]) p[@"commands"] = m[@"commands"];
    Cdp(@"Input.dispatchKeyEvent", p, nil);
  }

  void Create() {
    Log([NSString stringWithFormat:@"tab %d: create %dx%d @%.0fx%@", tab, width, height, scale, isolated ? @", isolated" : @""]);
    CefWindowInfo info;
    info.SetAsWindowless(nullptr);
    info.shared_texture_enabled = true;
    info.external_begin_frame_enabled = gBeginFrames;
    info.runtime_style = CEF_RUNTIME_STYLE_ALLOY;
    CefBrowserSettings settings;
    settings.windowless_frame_rate = gBeginFrames ? 120 : 60;
    createdWith_ = url;
    // A separate context keeps its cookies and storage apart from the shared profile, in memory only.
    CefRefPtr<CefRequestContext> context;
    if (isolated) context = CefRequestContext::CreateContext(CefRequestContextSettings(), nullptr);
    CefBrowserHost::CreateBrowser(info, this, url, settings, nullptr, context);
  }

  void Tick() {
    if (browser && !hidden) browser->GetHost()->SendExternalBeginFrame();
  }

  // One message from the host.
  // One message from the host, for this tab.
  void Handle(NSDictionary *m) {
    NSString *t = m[@"t"];
    if ([t isEqual:@"size"]) {
      width = MAX(1, [m[@"w"] intValue]);
      height = MAX(1, [m[@"h"] intValue]);
      double s = [m[@"scale"] doubleValue];
      bool scaleChanged = s != scale;
      scale = s ?: 2;
      if (!browser && !created_) {
        created_ = true;
        Create();
      } else if (browser) {
        if (scaleChanged) browser->GetHost()->NotifyScreenInfoChanged();
        browser->GetHost()->WasResized();
      }
      return;
    }
    if ([t isEqual:@"load"]) {
      url = [m[@"url"] UTF8String];
      if (browser) browser->GetMainFrame()->LoadURL(url);
      return;
    }
    if ([t isEqual:@"place"]) return PlaceDialogs(m);
    if (gDev && [t isEqual:@"dev-dialog"]) return DevDialog(tab, [m[@"open"] boolValue], ![m[@"unhooked"] boolValue]);
    if (gDev && [t isEqual:@"dev-shield-click"]) return DevShieldClick();
    if (gDev && [t isEqual:@"dev-move-dialog"]) return DevMoveDialog();
    if (gDev && [t isEqual:@"dev-dialog-state"]) return DevDialogState();
    if (!browser) return;
    auto h = browser->GetHost();
    if ([t isEqual:@"mouse"]) {
      CefMouseEvent e;
      e.x = [m[@"x"] intValue];
      e.y = [m[@"y"] intValue];
      e.modifiers = Flags(m);
      NSString *kind = m[@"kind"];
      if ([kind isEqual:@"down"]) gInputTab = tab;
      if ([kind isEqual:@"move"]) h->SendMouseMoveEvent(e, false);
      else if ([kind isEqual:@"leave"]) h->SendMouseMoveEvent(e, true);
      else h->SendMouseClickEvent(e, (cef_mouse_button_type_t)[m[@"button"] intValue], [kind isEqual:@"up"], [m[@"clicks"] intValue] ?: 1);
    } else if ([t isEqual:@"wheel"]) {
      CefMouseEvent e;
      e.x = [m[@"x"] intValue];
      e.y = [m[@"y"] intValue];
      e.modifiers = Flags(m);
      h->SendMouseWheelEvent(e, [m[@"dx"] intValue], [m[@"dy"] intValue]);
    } else if ([t isEqual:@"key"]) {
      gInputTab = tab;
      SendKey(m);
    } else if ([t isEqual:@"eval"] || [t isEqual:@"cdp"]) {
      NSNumber *rid = m[@"id"];
      NSString *method = [t isEqual:@"eval"] ? @"Runtime.evaluate" : m[@"method"];
      NSDictionary *params = [t isEqual:@"eval"] ? @{@"expression": m[@"expr"], @"returnByValue": @YES, @"awaitPromise": @YES}
                                                 : (m[@"params"] ?: @{});
      CefRefPtr<Browser> me = this;
      Cdp(method, params, ^(bool ok, NSString *json) { me->Send(@{@"t": @"cdp-result", @"id": rid, @"ok": @(ok), @"json": json}); });
    } else if ([t isEqual:@"ime-set"]) {
      std::vector<CefCompositionUnderline> lines;
      CefString text([m[@"text"] UTF8String]);
      uint32_t len = (uint32_t)[m[@"text"] length];
      cef_composition_underline_t line = {sizeof(cef_composition_underline_t), {0, len}, 0xFF000000, 0, false};
      lines.push_back(line);
      h->ImeSetComposition(text, lines, CefRange::InvalidRange(),
                              CefRange([m[@"selStart"] unsignedIntValue], [m[@"selEnd"] unsignedIntValue]));
    } else if ([t isEqual:@"ime-commit"]) {
      h->ImeCommitText([m[@"text"] UTF8String], CefRange::InvalidRange(), 0);
    } else if ([t isEqual:@"ime-finish"]) {
      h->ImeFinishComposingText(false);
    } else if ([t isEqual:@"ime-cancel"]) {
      h->ImeCancelComposition();
    } else if ([t isEqual:@"focus"]) {
      h->SetFocus([m[@"on"] boolValue]);
    } else if ([t isEqual:@"find"]) {
      h->Find([m[@"text"] UTF8String], [m[@"forward"] boolValue], [m[@"matchCase"] boolValue], [m[@"next"] boolValue]);
    } else if ([t isEqual:@"stop-find"]) {
      h->StopFinding(true);
    } else if ([t isEqual:@"zoom"]) {
      h->SetZoomLevel([m[@"level"] doubleValue]);
    } else if ([t isEqual:@"pdf"]) {
      // The page printed to a PDF (its print styles, on the paper Zero says), for Zero's print panel.
      CefPdfPrintSettings s;
      s.paper_width = [m[@"w"] doubleValue];
      s.paper_height = [m[@"h"] doubleValue];
      s.prefer_css_page_size = true;
      s.generate_document_outline = true;
      NSString *path = m[@"path"];
      h->PrintToPDF(path.UTF8String, s, new PdfDone(tab, path));
    } else if ([t hasPrefix:@"drag-"]) {
      // A drag over the page: from the page itself (its own data), or from another app (what Zero read off the
      // pasteboard: files, text, a link).
      CefMouseEvent e;
      e.x = [m[@"x"] intValue];
      e.y = [m[@"y"] intValue];
      e.modifiers = Flags(m);
      DragOperationsMask ops = (DragOperationsMask)[m[@"ops"] unsignedIntValue];
      if ([t isEqual:@"drag-enter"]) {
        CefRefPtr<CefDragData> data;
        if ([m[@"own"] boolValue] && drag) data = drag->Clone();
        else {
          data = CefDragData::Create();
          for (NSString *f in m[@"files"]) data->AddFile([f UTF8String], [f.lastPathComponent UTF8String]);
          if ([m[@"text"] length]) data->SetFragmentText([m[@"text"] UTF8String]);
          if ([m[@"url"] length]) data->SetLinkURL([m[@"url"] UTF8String]);
        }
        h->DragTargetDragEnter(data, e, ops);
        h->DragTargetDragOver(e, ops);
      } else if ([t isEqual:@"drag-over"]) {
        h->DragTargetDragOver(e, ops);
      } else if ([t isEqual:@"drag-leave"]) {
        h->DragTargetDragLeave();
      } else if ([t isEqual:@"drag-drop"]) {
        h->DragTargetDragOver(e, ops);
        h->DragTargetDrop(e);
      } else if ([t isEqual:@"drag-end"]) {
        if (drag) h->DragSourceEndedAt(e.x, e.y, (DragOperation)[m[@"op"] unsignedIntValue]);
        h->DragSourceSystemDragEnded();
        drag = nullptr;
      }
    } else if ([t isEqual:@"ax"]) {
      h->SetAccessibilityState([m[@"on"] boolValue] ? STATE_ENABLED : STATE_DISABLED);
    } else if ([t isEqual:@"hidden"]) {
      hidden = [m[@"on"] boolValue];
      h->WasHidden(hidden);
    } else if ([t isEqual:@"cmd"]) {
      NSString *c = m[@"name"];
      CefRefPtr<CefFrame> frame = browser->GetFocusedFrame();
      if (!frame) frame = browser->GetMainFrame();
      if ([c isEqual:@"copy"]) frame->Copy();
      else if ([c isEqual:@"cut"]) frame->Cut();
      else if ([c isEqual:@"paste"]) frame->Paste();
      else if ([c isEqual:@"selectAll"]) frame->SelectAll();
      else if ([c isEqual:@"undo"]) frame->Undo();
      else if ([c isEqual:@"redo"]) frame->Redo();
      else if ([c isEqual:@"back"]) browser->GoBack();
      else if ([c isEqual:@"forward"]) browser->GoForward();
      else if ([c isEqual:@"reload"]) browser->Reload();
      else if ([c isEqual:@"stop"]) browser->StopLoad();
    }
  }

 private:
  struct Ring {
    std::vector<id> surfaces;
    std::vector<uint32_t> ids;
    size_t w = 0, h = 0, next = 0;
  };
  Ring view_, popup_;
  int popupX_ = 0, popupY_ = 0;
  int warnedSoftware_ = 0;
  bool created_ = false;
  CefRefPtr<CefRegistration> devtools_;
  std::map<int, void (^)(bool, NSString *)> pending_;
  std::string createdWith_;
  IMPLEMENT_REFCOUNTING(Browser);
};

// MARK: - Passkeys: Chrome's dialog with its tab

// A page asking for a passkey gets Chrome's own dialog (a security key, a phone's QR code): a window of this app's, as
// the page is off-screen. It belongs with its tab, not over every app. For as long as one is expected or shows,
// Zero.app sends the tab's place (`place`: its rect on the screen, its side panel's column, its window's number,
// whether that window shows), and the dialog sits centred on the tab over a shield on the panel's column, both just
// above Zero's window: behind whatever is above Zero, see-through while Zero's window is away (hidden, minimised, on
// another Space, another tab shown). The shield dims the panel and takes its clicks, giving the dialog the keyboard:
// a window of this app's, so a click there keeps the keyboard in this app rather than making Zero the active app and
// handing the front back (two apps active in turn, the dialog flickering between key and not). Zero.app hands this
// app the front once, as the dialog shows, while Zero is the active app. Faceless (activation policy prohibited)
// except while one shows.
static int gDialogTab = 0;          // the tab whose dialog is expected or shows
static NSDictionary *gPlace = nil;  // where it goes: Zero.app's last `place` for it
static NSTimer *gWatch = nil;
static double gWatchUntil = 0;
static bool gDialogShown = false;
static NSWindow *gDevDialog = nil;
static NSWindow *gShield = nil;

// The dialogs shown (not the shield).
static NSArray<NSWindow *> *Shown() {
  return [NSApp.orderedWindows filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSWindow *w, NSDictionary *) {
                                 return w.isVisible && w != gShield;
                               }]];
}
static void DialogTakesKeyboard();

static bool OnADisplay(NSRect r) {
  for (NSScreen *s in NSScreen.screens)
    if (NSIntersectsRect(s.frame, r)) return true;
  return false;
}

// Directly above that window already (the window server's order, front to back above it: the last is next to it).
static bool JustAbove(NSWindow *w, NSInteger below) {
  NSArray *above = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenAboveWindow, (CGWindowID)below));
  return [above.lastObject[(__bridge NSString *)kCGWindowNumber] integerValue] == w.windowNumber;
}

// Ordered directly above that window, unless it is already (ordering a key window again moves the keyboard), or
// whatever `moved` says: the window server's list doesn't show an order this turn of the run loop asked for yet.
static bool Above(NSWindow *w, NSInteger below, bool moved = false) {
  if (!moved && JustAbove(w, below)) return false;
  [w orderWindow:NSWindowAbove relativeTo:below];
  return true;
}

// Part of Zero's window, not a window of its own: left out of Mission Control and Exposé, and of the window cycle.
static void Attached(NSWindow *w) {
  NSWindowCollectionBehavior b = NSWindowCollectionBehaviorTransient | NSWindowCollectionBehaviorIgnoresCycle;
  if ((w.collectionBehavior & b) != b)
    w.collectionBehavior = (w.collectionBehavior & ~(NSWindowCollectionBehaviorManaged | NSWindowCollectionBehaviorStationary |
                                                     NSWindowCollectionBehaviorParticipatesInCycle)) | b;
}

// Takes clicks and the keyboard without making this app the active one, as a non-activating panel does (AppKit's own
// switch for one, on any window): Zero stays the active app while a dialog shows, so a click in Zero never activates
// it and brings its window forward over the dialog (frames in which the dialog is gone).
static bool KeepsZeroActive(NSWindow *w) {
  SEL set = NSSelectorFromString(@"_setPreventsActivation:"), get = NSSelectorFromString(@"_preventsActivation");
  if (![w respondsToSelector:set] || ![w respondsToSelector:get]) return false;
  if (!((BOOL (*)(id, SEL))objc_msgSend)(w, get)) ((void (*)(id, SEL, BOOL))objc_msgSend)(w, set, YES);
  return ((BOOL (*)(id, SEL))objc_msgSend)(w, get);
}

// Seen, or see-through and out of the way of clicks.
static void Shows(NSWindow *w, bool shows) {
  if (w.alphaValue != (shows ? 1 : 0)) w.alphaValue = shows ? 1 : 0;
  if (w.ignoresMouseEvents != !shows) w.ignoresMouseEvents = !shows;
}

@interface ZBShield : NSWindow
@end
@implementation ZBShield
- (BOOL)canBecomeKeyWindow { return NO; }
- (BOOL)canBecomeMainWindow { return NO; }
@end

@interface ZBShieldView : NSView
@end
// A click on it never brings it forward (over the dialog): the dialog takes the keyboard instead, and this app the front.
@implementation ZBShieldView
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }
- (BOOL)shouldDelayWindowOrderingForEvent:(NSEvent *)event { return YES; }
- (void)take {
  [NSApp preventWindowOrdering];
  DialogTakesKeyboard();
}
- (void)mouseDown:(NSEvent *)event { [self take]; }
- (void)rightMouseDown:(NSEvent *)event { [self take]; }
- (void)otherMouseDown:(NSEvent *)event { [self take]; }
- (void)scrollWheel:(NSEvent *)event {}
@end

static void PlaceDialogs(NSDictionary *place) {
  if (place) {
    if ([place[@"tab"] intValue] != gDialogTab) return;
    gPlace = place;
  }
  if (!gPlace || !gDialogShown) return;
  NSRect tab = NSMakeRect([gPlace[@"x"] doubleValue], [gPlace[@"y"] doubleValue], [gPlace[@"w"] doubleValue], [gPlace[@"h"] doubleValue]);
  NSRect column = NSMakeRect([gPlace[@"cx"] doubleValue], [gPlace[@"cy"] doubleValue], [gPlace[@"cw"] doubleValue], [gPlace[@"ch"] doubleValue]);
  bool shows = [gPlace[@"visible"] boolValue];
  NSInteger below = [gPlace[@"window"] integerValue];
  bool moved = false;
  // Zero Dev's never go where a display shows them (its Zero's window, and so its panel, is off every display).
  if (column.size.width > 0 && !(gDev && OnADisplay(column))) {
    if (!gShield) {
      gShield = [[ZBShield alloc] initWithContentRect:column styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
      gShield.releasedWhenClosed = NO;
      gShield.opaque = NO;
      gShield.hasShadow = NO;
      // A mid grey: a dark page lightens as a light one darkens.
      gShield.backgroundColor = [NSColor colorWithWhite:0.5 alpha:0.45];
      gShield.contentView = [ZBShieldView new];
      gShield.alphaValue = 0;
      Attached(gShield);
      bool keeps = KeepsZeroActive(gShield);
      // Zero keeps its window under it on a click (rather than coming forward over it and the dialog).
      Send(@{@"t": @"shield", @"tab": @(gDialogTab), @"window": @(gShield.windowNumber), @"keepsZeroActive": @(keeps)});
    }
    if (!NSEqualRects(gShield.frame, column)) [gShield setFrame:column display:NO];
    Shows(gShield, shows);
    // This app active, its windows are above Zero's already (Zero keeps its window from coming forward on a click
    // while a dialog shows): the shield stays put.
    if (!NSApp.isActive || !gShield.isVisible) moved = Above(gShield, below);
    below = gShield.windowNumber;
  }
  for (NSWindow *w in Shown()) {
    NSRect frame = {{round(NSMidX(tab) - w.frame.size.width / 2), round(NSMidY(tab) - w.frame.size.height / 2)}, w.frame.size};
    if (gDev && OnADisplay(frame)) continue;
    Attached(w);
    if (!NSEqualPoints(w.frame.origin, frame.origin)) {
      // Far from it: Chrome moved it (to where it thinks the tab is), or the tab moved.
      if (fabs(w.frame.origin.x - frame.origin.x) > 40 || fabs(w.frame.origin.y - frame.origin.y) > 40)
        Log([NSString stringWithFormat:@"tab %d: dialog put back on its tab from %@", gDialogTab, NSStringFromPoint(w.frame.origin)]);
      [w setFrameOrigin:frame.origin];
    }
    Shows(w, shows);
    // This app active, its dialog is in front already: only kept above its shield.
    if (!NSApp.isActive || gShield) Above(w, below, moved);
  }
}

// A click on the shield: the dialog has the keyboard (this app, active by that click), above the shield.
static void DialogTakesKeyboard() {
  NSWindow *dialog = Shown().firstObject;
  if (!dialog) return;
  // Ordered whatever the window server's list says: the click may have just brought the shield forward, which the
  // list doesn't show yet.
  if (gShield) [dialog orderWindow:NSWindowAbove relativeTo:gShield.windowNumber];
  if (!gDev) [dialog makeKeyWindow];
}

static void CheckDialogs() {
  NSArray<NSWindow *> *shown = Shown();
  if (shown.count && !gDialogShown) {
    gDialogShown = true;
    // Not asked for as far as this app knows (a page's request its hook missed): the tab the user was in.
    if (!gWatch) gDialogTab = gInputTab;
    NSApp.activationPolicy = NSApplicationActivationPolicyAccessory;
    // See-through until Zero.app says where it goes; there at once if it has.
    bool keeps = true;
    for (NSWindow *w in shown) {
      w.alphaValue = 0;
      keeps &= KeepsZeroActive(w);
    }
    PlaceDialogs(nil);
    // The keyboard (a security key's PIN), Zero still the active app. Never in Zero Dev: its key window would take the
    // keyboard from whatever app the user is in.
    if (!gDev) [shown[0] makeKeyWindow];
    Log([NSString stringWithFormat:@"tab %d: a dialog shows (%@), keeps Zero active %d", gDialogTab, shown[0].className, keeps]);
    Send(@{@"t": @"dialog-shown", @"tab": @(gDialogTab), @"keepsZeroActive": @(keeps)});
  } else if (!shown.count && (gDialogShown || CACurrentMediaTime() > gWatchUntil)) {
    [gWatch invalidate];
    gWatch = nil;
    if (gDialogShown) {
      // The front back to Zero.app (it takes it if this app still has it).
      NSString *zero = [[[NSBundle.mainBundle.bundlePath stringByDeletingLastPathComponent] stringByDeletingLastPathComponent]
          stringByDeletingLastPathComponent];
      for (NSRunningApplication *app in NSWorkspace.sharedWorkspace.runningApplications)
        if ([app.bundleURL.path isEqual:zero]) [NSApp yieldActivationToApplication:app];
      NSApp.activationPolicy = NSApplicationActivationPolicyProhibited;
      Log([NSString stringWithFormat:@"tab %d: no dialog shows", gDialogTab]);
    }
    gDialogShown = false;
    gPlace = nil;
    [gShield close];
    gShield = nil;
    Send(@{@"t": @"dialog-gone", @"tab": @(gDialogTab)});
  }
}

// A dialog may show for `seconds` (a passkey request in `tab`): Zero.app starts sending the tab's place.
static void ExpectDialog(int tab, double seconds) {
  gDialogTab = tab;
  gWatchUntil = CACurrentMediaTime() + seconds;
  Send(@{@"t": @"dialog-expected", @"tab": @(tab)});
  [gWatch invalidate];
  gWatch = [NSTimer scheduledTimerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *) { CheckDialogs(); }];
}

// Zero Dev's stand-in for Chrome's dialog (a real request could show Chrome's on the user's screen): a plain window,
// made off every display and kept off them, for the harness to read where it went.
// Zero Dev only: a click on the shield, posted in this app (as the user's would land; it never activates the app).
static void DevShieldClick() {
  if (!gShield) return;
  // Over the dialog, as the window server may bring it on a click.
  [gShield orderWindow:NSWindowAbove relativeTo:Shown().firstObject.windowNumber];
  NSPoint p = NSMakePoint(10, 10);
  for (NSEventType type : {NSEventTypeLeftMouseDown, NSEventTypeLeftMouseUp})
    [NSApp postEvent:[NSEvent mouseEventWithType:type location:p modifierFlags:0 timestamp:NSProcessInfo.processInfo.systemUptime
                                    windowNumber:gShield.windowNumber context:nil eventNumber:0 clickCount:1 pressure:1]
             atStart:NO];
}

static void DevDialog(int tab, bool open, bool hooked) {
  [gDevDialog close];
  gDevDialog = nil;
  if (!open) return;
  NSRect all = NSZeroRect;
  for (NSScreen *s in NSScreen.screens) all = NSUnionRect(all, s.frame);
  gDevDialog = [[NSWindow alloc] initWithContentRect:NSMakeRect(NSMaxX(all) + 8000, NSMaxY(all) + 8000, 300, 200)
                                           styleMask:NSWindowStyleMaskBorderless
                                             backing:NSBackingStoreBuffered
                                               defer:NO];
  gDevDialog.releasedWhenClosed = NO;
  if (hooked) ExpectDialog(tab, 10);
  if (!OnADisplay(gDevDialog.frame)) [gDevDialog orderFront:nil];
  // Placed where it shows, as Chrome does its dialog (off every display still).
  if (!hooked) [gDevDialog setFrameOrigin:NSMakePoint(gDevDialog.frame.origin.x + 10, gDevDialog.frame.origin.y)];
}

// Zero Dev only: how the dialog and the shield take part in Mission Control and activation, for the checks.
static void DevDialogState() {
  auto state = ^NSDictionary *(NSWindow *w) {
    if (!w) return @{};
    NSWindowCollectionBehavior b = w.collectionBehavior;
    return @{@"transient": @((b & NSWindowCollectionBehaviorTransient) != 0), @"managed": @((b & NSWindowCollectionBehaviorManaged) != 0),
             @"ignoresCycle": @((b & NSWindowCollectionBehaviorIgnoresCycle) != 0), @"level": @(w.level),
             @"keepsZeroActive": @(KeepsZeroActive(w))};
  };
  Send(@{@"t": @"dev-dialog-state", @"tab": @(gDialogTab), @"dialog": state(Shown().firstObject), @"shield": state(gShield)});
}

// Zero Dev only: the stand-in moved elsewhere (off every display), as Chrome moves its dialog to where it thinks the tab is.
static void DevMoveDialog() {
  NSPoint p = gDevDialog.frame.origin;
  [gDevDialog setFrameOrigin:NSMakePoint(p.x + 500, p.y + 300)];
}

// MARK: - The tools page: Zero's browser tools for agents (the extension's own, apps/chrome), through zerod

// A hidden page of Zero Browser's own: it loads about:blank and runs Contents/Resources/zero-tools.js, the tools on a
// chrome.* of this app's making (tools/shim.js). Its one way out is `zeroBridge`, a DevTools binding on this page
// alone: no page a tab loads can reach it, and this page goes nowhere else.
static int gNextAgentTab = 1000000000;
static NSString *gToolsState;  // the tools' saved state: a file in this app's cache folder
static void ToolsOp(NSDictionary *m);
static std::string Json(id value);

class ToolsPage : public CefClient, public CefLifeSpanHandler, public CefLoadHandler, public CefRenderHandler,
                  public CefRequestHandler, public CefDevToolsMessageObserver, public CefDisplayHandler {
 public:
  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  // What the tools log (their errors above all) goes to this app's log; tabs' consoles don't.
  bool OnConsoleMessage(CefRefPtr<CefBrowser>, cef_log_severity_t level, const CefString &message, const CefString &, int line) override {
    Log([NSString stringWithFormat:@"tools console (%d, line %d): %s", level, line, message.ToString().c_str()]);
    return true;
  }
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
  CefRefPtr<CefRenderHandler> GetRenderHandler() override { return this; }
  CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }
  CefRefPtr<CefBrowser> browser;

  void Create() {
    CefWindowInfo info;
    info.SetAsWindowless(nullptr);
    info.runtime_style = CEF_RUNTIME_STYLE_ALLOY;
    CefBrowserSettings settings;
    settings.windowless_frame_rate = 1;
    CefBrowserHost::CreateBrowser(info, this, "about:blank", settings, nullptr, nullptr);
  }
  void OnAfterCreated(CefRefPtr<CefBrowser> b) override {
    browser = b;
    devtools_ = b->GetHost()->AddDevToolsMessageObserver(this);
    b->GetHost()->WasHidden(true);
  }
  void OnBeforeClose(CefRefPtr<CefBrowser>) override {
    devtools_ = nullptr;
    browser = nullptr;
  }
  bool OnBeforePopup(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, int, const CefString &, const CefString &, WindowOpenDisposition,
                     bool, const CefPopupFeatures &, CefWindowInfo &, CefRefPtr<CefClient> &, CefBrowserSettings &,
                     CefRefPtr<CefDictionaryValue> &, bool *) override {
    return true;
  }
  // about:blank, once; nothing after.
  bool OnBeforeBrowse(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, CefRefPtr<CefRequest> request, bool, bool) override {
    bool first = !navigated_ && request->GetURL().ToString() == "about:blank";
    navigated_ = true;
    return !first;
  }
  void OnLoadEnd(CefRefPtr<CefBrowser> b, CefRefPtr<CefFrame> frame, int) override {
    if (!frame->IsMain() || loaded_) return;
    loaded_ = true;
    NSString *path = [NSBundle.mainBundle pathForResource:@"zero-tools" ofType:@"js"];
    NSString *source = path ? [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil] : nil;
    if (!source) return Log(@"tools: no zero-tools.js");
    // The binding first, then the script: DevTools runs a session's methods in order, so the script finds it.
    Method("Runtime.enable", "{}");
    Method("Runtime.addBinding", "{\"name\":\"zeroBridge\"}");
    std::string saved = Json([NSString stringWithContentsOfFile:gToolsState encoding:NSUTF8StringEncoding error:nil] ?: [NSNull null]);
    Method("Runtime.evaluate", Json(@{@"expression": @(("globalThis.__zeroSaved = " + saved).c_str())}).c_str());
    Method("Runtime.evaluate", Json(@{@"expression": source, @"replMode": @NO}).c_str());
    Log(@"tools: started");
  }
  void GetViewRect(CefRefPtr<CefBrowser>, CefRect &rect) override { rect = CefRect(0, 0, 16, 16); }
  void OnPaint(CefRefPtr<CefBrowser>, PaintElementType, const RectList &, const void *, int, int) override {}

  void OnDevToolsEvent(CefRefPtr<CefBrowser>, const CefString &method, const void *params, size_t size) override {
    if (method.ToString() != "Runtime.bindingCalled") return;
    NSDictionary *p = [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:params length:size] options:0 error:nil];
    if (![p[@"name"] isEqual:@"zeroBridge"]) return;
    NSDictionary *m = [NSJSONSerialization JSONObjectWithData:[p[@"payload"] dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    if ([m isKindOfClass:NSDictionary.class]) ToolsOp(m);
  }

  /// JavaScript in the page, as is.
  void Run(const std::string &js) {
    if (browser) browser->GetMainFrame()->ExecuteJavaScript(js, "zero-tools:///in", 0);
  }
  void Method(const char *method, const char *params) {
    if (!browser) return;
    auto value = CefParseJSON(params, JSON_PARSER_RFC);
    browser->GetHost()->ExecuteDevToolsMethod(0, method, value ? value->GetDictionary() : CefDictionaryValue::Create());
  }

 private:
  bool navigated_ = false, loaded_ = false;
  CefRefPtr<CefRegistration> devtools_;
  IMPLEMENT_REFCOUNTING(ToolsPage);
};
static CefRefPtr<ToolsPage> gTools;

static std::string Json(id value) {
  NSData *data = [NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingFragmentsAllowed error:nil];
  return data ? std::string((const char *)data.bytes, data.length) : "null";
}

// An answer to the tools page: `value` as JSON text, as it goes into the page.
static void Reply(NSNumber *ask, bool ok, const std::string &value) {
  if (gTools) gTools->Run("__zeroReply(" + Json(ask) + "," + (ok ? "true" : "false") + "," + value + ")");
}

static void ToolsRemoved(int tab) {
  if (gTools) gTools->Run("__zeroIn({\"kind\":\"removed\",\"tab\":" + std::to_string(tab) + "})");
}
static void ToolsEvent(int tab, const std::string &method, const std::string &params) {
  if (gTools) gTools->Run("__zeroIn({\"kind\":\"cdp\",\"tab\":" + std::to_string(tab) + ",\"method\":" + Json(@(method.c_str())) + "}," + params + ")");
}
// A content script's chrome.runtime.sendMessage, from the tools' world in a tab (its `zeroSend` binding, which the
// page's own scripts can't see): to the tools' onMessage, from that tab.
static void ToolsMessage(int tab, const void *params, size_t size) {
  NSDictionary *p = [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:params length:size] options:0 error:nil];
  if (![p[@"name"] isEqual:@"zeroSend"] || ![p[@"payload"] isKindOfClass:NSString.class]) return;
  id message = [NSJSONSerialization JSONObjectWithData:[p[@"payload"] dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
  if (message && gTools) gTools->Run("__zeroIn({\"kind\":\"message\",\"tab\":" + std::to_string(tab) + "}," + Json(message) + ")");
}
static void ToolsLine(NSData *line) {
  if (gTools) gTools->Run("__zeroIn({\"kind\":\"line\"}," + std::string((const char *)line.bytes, line.length) + ")");
}

static NSDictionary *TabInfo(Browser *b) {
  auto owner = gOwners.find(b->tab);
  return @{@"id": @(b->tab), @"url": @((b->address.empty() ? b->url : b->address).c_str()), @"title": @(b->title.c_str()),
           @"loading": @(b->loading), @"isolated": @(b->isolated), @"agent": @(b->agent),
           @"session": owner == gOwners.end() ? @"" : @(owner->second.c_str())};
}

// An agent's tab, shown in its task's side panel when Zero.app is connected (told again when it connects).
static void TellOwner(Browser *b) {
  auto owner = gOwners.find(b->tab);
  if (owner == gOwners.end()) return;
  ::Send(@{@"t": @"agent-tab", @"tab": @(b->tab), @"session": @(owner->second.c_str()), @"url": TabInfo(b)[@"url"],
           @"title": @(b->title.c_str())});
}

// A step of the tools in a tab's page, in the extension's own world there ("zero": apart from the page's own
// scripts, as an extension's content scripts are): made if the document doesn't have it yet, then the expression.
static void InWorld(Browser *b, NSString *expression, void (^done)(bool, NSString *)) {
  CefRefPtr<Browser> keep = b;
  if (!b->bound) {
    b->bound = true;
    b->Cdp(@"Runtime.addBinding", @{@"name": @"zeroSend", @"executionContextName": @"zero"}, ^(bool ok, NSString *json) {
      if (!ok) Log([NSString stringWithFormat:@"tab %d: no zeroSend: %@", keep->tab, json]);
    });
  }
  b->Cdp(@"Page.getFrameTree", @{}, ^(bool ok, NSString *json) {
    NSDictionary *tree = ok ? [NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil] : nil;
    NSString *frame = tree[@"frameTree"][@"frame"][@"id"];
    if (!frame) return done(false, @"\"The page isn't ready yet\"");
    keep->Cdp(@"Page.createIsolatedWorld", @{@"frameId": frame, @"worldName": @"zero"}, ^(bool ok, NSString *json) {
      NSDictionary *world = ok ? [NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil] : nil;
      if (!world[@"executionContextId"]) return done(false, @"\"The page isn't ready yet\"");
      keep->Cdp(@"Runtime.evaluate", @{@"expression": expression, @"contextId": world[@"executionContextId"], @"awaitPromise": @YES,
                                       @"returnByValue": @YES},
                ^(bool ok, NSString *json) {
                  NSDictionary *r = ok ? [NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil] : nil;
                  if (!r) return done(false, json ?: @"\"no answer\"");
                  if (r[@"exceptionDetails"]) {
                    NSString *why = r[@"exceptionDetails"][@"exception"][@"description"] ?: r[@"exceptionDetails"][@"text"] ?: @"failed";
                    return done(false, @(Json(why).c_str()));
                  }
                  id value = r[@"result"][@"value"];
                  done(true, value ? @(Json(value).c_str()) : @"null");
                });
    });
  });
}

static void ToolsOp(NSDictionary *m) {
  NSNumber *ask = m[@"id"];
  NSString *op = m[@"op"];
  if ([op isEqual:@"zerod"]) {
    NSData *line = [[m[@"line"] stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
    const char *p = (const char *)line.bytes;
    size_t left = line.length;
    while (left) {
      ssize_t n = write(0, p, left);
      if (n <= 0) return Reply(ask, false, "\"zerod is gone\"");
      p += n;
      left -= n;
    }
    return Reply(ask, true, "true");
  }
  // The tools' state (chrome.storage.local, groups), kept across restarts as Chrome keeps an extension's.
  if ([op isEqual:@"save"]) {
    [m[@"state"] ?: @"" writeToFile:gToolsState atomically:YES encoding:NSUTF8StringEncoding error:nil];
    return Reply(ask, true, "true");
  }
  if ([op isEqual:@"tabs"]) {
    NSMutableArray *all = [NSMutableArray array];
    for (auto &t : gTabs) [all addObject:TabInfo(t.second.get())];
    return Reply(ask, true, Json(all));
  }
  if ([op isEqual:@"open"]) {
    if (gQuitting) return Reply(ask, false, "\"Zero Browser is quitting\"");
    int tab = gNextAgentTab++;
    CefRefPtr<Browser> b = new Browser(tab, [m[@"isolated"] boolValue], true);
    b->width = 1280;
    b->height = 900;
    b->scale = 1;
    b->url = [m[@"url"] ?: @"about:blank" UTF8String];
    gTabs[tab] = b;
    b->Handle(@{@"t": @"size", @"w": @1280, @"h": @900, @"scale": @1});
    return Reply(ask, true, Json(TabInfo(b.get())));
  }
  auto it = gTabs.find([m[@"tab"] intValue]);
  if (it == gTabs.end()) return Reply(ask, false, Json([NSString stringWithFormat:@"No tab with id: %@.", m[@"tab"]]));
  Browser *b = it->second.get();
  if ([op isEqual:@"close"]) {
    if (b->browser) b->browser->GetHost()->CloseBrowser(true);
    return Reply(ask, true, "true");
  }
  if ([op isEqual:@"navigate"]) {
    b->Handle(@{@"t": @"load", @"url": m[@"url"] ?: @"about:blank"});
    return Reply(ask, true, "true");
  }
  if ([op isEqual:@"command"]) {
    b->Handle(@{@"t": @"cmd", @"name": m[@"name"] ?: @""});
    return Reply(ask, true, "true");
  }
  if ([op isEqual:@"attach"] || [op isEqual:@"detach"]) {
    if ([op isEqual:@"attach"]) gDebugged.insert(b->tab);
    else gDebugged.erase(b->tab);
    return Reply(ask, true, "true");
  }
  if ([op isEqual:@"owner"]) {
    gOwners[b->tab] = [m[@"session"] UTF8String] ?: "";
    TellOwner(b);
    return Reply(ask, true, "true");
  }
  if ([op isEqual:@"cdp"]) {
    if ([m[@"method"] isEqual:@"Page.handleJavaScriptDialog"] && b->dialog) {
      bool accept = [m[@"params"][@"accept"] boolValue];
      NSString *text = m[@"params"][@"promptText"] ?: @"";
      b->dialog->Continue(accept, text.UTF8String);
      b->dialog = nullptr;
      ToolsEvent(b->tab, "Page.javascriptDialogClosed", Json(@{@"result": @(accept), @"userInput": text}));
      return Reply(ask, true, "{}");
    }
    b->Cdp(m[@"method"], m[@"params"], ^(bool ok, NSString *json) {
      if (ok) return Reply(ask, true, json.UTF8String);
      NSDictionary *e = [NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
      Reply(ask, false, Json(e[@"message"] ?: json ?: @"failed"));
    });
    return;
  }
  if ([op isEqual:@"world"]) {
    InWorld(b, m[@"expression"] ?: @"undefined", ^(bool ok, NSString *json) { Reply(ask, ok, json.UTF8String); });
    return;
  }
  Reply(ask, false, Json([NSString stringWithFormat:@"No op %@", op]));
}

// Frames on the display's own clock: Chromium's off-screen timer alone gives 60 fps, on a 120 Hz screen too. The
// display's rate while a tab paints or input came in the last 0.5 s; a still process drops to 15 Hz (a timer, the
// display link paused), so what scripts change still shows, and the first paint or input brings the full rate back.
static void TickAll() {
  for (auto &tab : gTabs) tab.second->Tick();
}

static void StartTicking() {
  [gLink invalidate];
  gLink = nil;
  if (!gBeginFrames) return;
  NSScreen *screen = NSScreen.mainScreen;
  for (NSScreen *s in NSScreen.screens)
    if ([s.deviceDescription[@"NSScreenNumber"] unsignedIntValue] == gDisplay) screen = s;
  gTicker = [Ticker new];
  gTicker.tick = ^{
    TickAll();
    if (CACurrentMediaTime() - gLastActive > 0.5) Idle(true);
  };
  gLink = [screen displayLinkWithTarget:gTicker selector:@selector(fire:)];
  [gLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
  Log([NSString stringWithFormat:@"begin frames from display %u at %ld Hz", gDisplay, (long)screen.maximumFramesPerSecond]);
}

static void Idle(bool idle) {
  if (!gLink || gLink.paused == idle) return;
  gLink.paused = idle;
  [gSlow invalidate];
  gSlow = nil;
  if (!idle) return;
  gSlow = [NSTimer scheduledTimerWithTimeInterval:1.0 / 15 repeats:YES block:^(NSTimer *) {
    TickAll();
    if (CACurrentMediaTime() - gLastActive < 0.5) Idle(false);
  }];
}

// Quitting closes every tab first, so Chromium writes its cookies and storage out (CefShutdown after the loop).
static void QuitWhenClosed() {
  if (gQuitting && gTabs.empty()) CefQuitMessageLoop();
}

static void Quit() {
  if (gQuitting) return;
  gQuitting = true;
  Log(@"quitting: closing every tab");
  Send(@{@"t": @"quitting"});
  for (auto &tab : std::map<int, CefRefPtr<Browser>>(gTabs))
    if (tab.second->browser) tab.second->browser->GetHost()->CloseBrowser(true);
  if (gTools && gTools->browser) gTools->browser->GetHost()->CloseBrowser(true);
  QuitWhenClosed();
}

// One message from the host: for the process, or for a tab.
static void HandleMessage(NSDictionary *m) {
  NSString *t = m[@"t"];
  gLastActive = CACurrentMediaTime();
  Idle(false);
  // Never input: what the user types must not reach a log.
  if ([@[@"open", @"close", @"quit", @"load"] containsObject:t]) Log([NSString stringWithFormat:@"got %@ (tab %@)", t, m[@"tab"] ?: @"-"]);
  if ([t isEqual:@"options"]) {
    gBeginFrames = [m[@"beginFrames"] boolValue];
    return;
  }
  if ([t isEqual:@"outside"]) {
    NSArray *prefixes = m[@"prefixes"];
    gOutside = [prefixes isKindOfClass:NSArray.class] ? prefixes : @[];
    return;
  }
  if ([t isEqual:@"display"]) {
    uint32_t d = [m[@"id"] unsignedIntValue];
    if (d != gDisplay || !gLink) {
      gDisplay = d;
      StartTicking();
    }
    return;
  }
  if ([t isEqual:@"quit"]) return Quit();
  if ([t isEqual:@"answer"]) {
    auto it = gAsks.find([m[@"ask"] intValue]);
    if (it == gAsks.end()) return;
    auto answered = it->second;
    gAsks.erase(it);
    answered(m);
    return;
  }
  int tab = [m[@"tab"] intValue];
  if ([t isEqual:@"open"]) {
    if (gQuitting || gTabs.count(tab)) return;
    // An agent's tab Zero.app had (this app restarted): the agent's again, and later agents' tabs numbered after it.
    NSString *session = m[@"session"];
    bool agent = [session isKindOfClass:NSString.class] && session.length;
    CefRefPtr<Browser> b = new Browser(tab, [m[@"isolated"] boolValue], agent);
    if (agent) {
      gOwners[tab] = session.UTF8String;
      gNextAgentTab = MAX(gNextAgentTab, tab + 1);
    }
    gTabs[tab] = b;
    b->Handle(@{@"t": @"load", @"url": m[@"url"] ?: @"about:blank"});
    return;
  }
  auto it = gTabs.find(tab);
  if (it == gTabs.end()) return;
  if ([t isEqual:@"close"]) {
    if (it->second->browser) it->second->browser->GetHost()->CloseBrowser(true);
    return;
  }
  it->second->Handle(m);
}
// Kept for the life of the process: under ARC a dispatch source held only by a local is freed, and stops.
static dispatch_source_t gControlSource, gZerodSource, gMachSource, gTermSource;

// MARK: - The channels

// Lines from `fd` until it closes: each to `handle`, then `closed`.
static dispatch_source_t ReadLines(int fd, void (^handle)(NSData *), void (^closed)()) {
  auto buffer = std::make_shared<std::string>();
  dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, fd, 0, dispatch_get_main_queue());
  __block dispatch_source_t me = source;
  dispatch_source_set_event_handler(source, ^{
    char chunk[65536];
    ssize_t n = read(fd, chunk, sizeof chunk);
    if (n <= 0) {
      dispatch_source_cancel(me);
      me = nil;
      closed();
      return;
    }
    buffer->append(chunk, n);
    size_t nl;
    while ((nl = buffer->find('\n')) != std::string::npos) {
      NSData *line = [NSData dataWithBytes:buffer->data() length:nl];
      buffer->erase(0, nl + 1);
      if (line.length) handle(line);
    }
  });
  dispatch_resume(source);
  return source;
}

// The app showing the pages went: its tabs close (an agent's stay), and the next hello from Zero.app connects it again.
static void ControlClosed() {
  Log(@"control channel closed");
  if (gControl >= 0) close(gControl);
  gControl = -1;
  if (gHost) mach_port_deallocate(mach_task_self(), gHost);
  gHost = MACH_PORT_NULL;
  for (auto &tab : std::map<int, CefRefPtr<Browser>>(gTabs))
    if (!tab.second->agent && tab.second->browser) tab.second->browser->GetHost()->CloseBrowser(true);
}

static void ReadControl() {
  gControlSource = ReadLines(gControl, ^(NSData *line) {
    NSDictionary *m = [NSJSONSerialization JSONObjectWithData:line options:0 error:nil];
    if ([m isKindOfClass:NSDictionary.class]) HandleMessage(m);
  }, ^{ ControlClosed(); });
}

// A hello with the port frames go to, signed as the app this one belongs to. Zero.app may be any process so signed (it
// may have restarted since zerod started this app): it gets the control channel back on its port.
static void ListenForHello(mach_port_t service) {
  dispatch_source_t source = gMachSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_MACH_RECV, service, 0, dispatch_get_main_queue());
  dispatch_source_set_event_handler(source, ^{
    struct { HelloMsg m; mach_msg_audit_trailer_t trailer; } r = {};
    kern_return_t kr = mach_msg(&r.m.h, MACH_RCV_MSG | MACH_RCV_TIMEOUT | MACH_RCV_TRAILER_TYPE(MACH_MSG_TRAILER_FORMAT_0) |
                                MACH_RCV_TRAILER_ELEMENTS(MACH_RCV_TRAILER_AUDIT), 0, sizeof r, service, 0, MACH_PORT_NULL);
    if (kr != KERN_SUCCESS || r.m.h.msgh_id != kMsgHello) return;
    pid_t sender = (pid_t)r.trailer.msgh_audit.val[5];
    if (!Trusted(r.trailer.msgh_audit, AppRequirement().c_str())) {
      Log([NSString stringWithFormat:@"refused a hello from pid %d", sender]);
      mach_msg_destroy(&r.m.h);
      return;
    }
    {
      int fds[2];
      mach_port_t file = MACH_PORT_NULL;
      if (socketpair(AF_UNIX, SOCK_STREAM, 0, fds) != 0) return mach_msg_destroy(&r.m.h);
      if (fileport_makeport(fds[1], &file) != 0) {
        close(fds[0]);
        close(fds[1]);
        return mach_msg_destroy(&r.m.h);
      }
      close(fds[1]);
      ControlMsg c = {};
      c.h.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0) | MACH_MSGH_BITS_COMPLEX;
      c.h.msgh_remote_port = r.m.port.name;
      c.h.msgh_size = sizeof c;
      c.h.msgh_id = kMsgControl;
      c.body.msgh_descriptor_count = 1;
      c.port.name = file;
      c.port.disposition = MACH_MSG_TYPE_MOVE_SEND;
      c.port.type = MACH_MSG_PORT_DESCRIPTOR;
      if (mach_msg(&c.h, MACH_SEND_MSG | MACH_SEND_TIMEOUT, sizeof c, 0, MACH_PORT_NULL, 1000, MACH_PORT_NULL) != KERN_SUCCESS) {
        mach_port_deallocate(mach_task_self(), file);
        close(fds[0]);
        return mach_msg_destroy(&r.m.h);
      }
      if (gControl >= 0) {  // a second Zero.app: the first one's channel goes
        if (gControlSource) dispatch_source_cancel(gControlSource);
        ControlClosed();
      }
      gControl = fds[0];
      ReadControl();
    }
    if (gHost) mach_port_deallocate(mach_task_self(), gHost);
    gHost = r.m.port.name;
    Log([NSString stringWithFormat:@"frames: connected to pid %d", sender]);
    for (auto &tab : gTabs) TellOwner(tab.second.get());
    for (auto &tab : gTabs)
      if (tab.second->browser) tab.second->browser->GetHost()->Invalidate(PET_VIEW);
  });
  dispatch_resume(source);
}

// zerod's connection, for the tools page (agents' calls). zerod going (quit, restarting for an update): this app
// quits cleanly, and the next zerod starts it again when Zero.app asks.
static void ReadZerod() {
  gZerodSource = ReadLines(0, ^(NSData *line) { ToolsLine(line); }, ^{
    Log(@"zerod's socket closed");
    Quit();
  });
}

// A profile lock left by a process that's gone (killed, crashed) makes CefInitialize wait about 8.5 s: removed.
static void ClearStaleLock(NSString *profile) {
  NSString *lock = [profile stringByAppendingPathComponent:@"SingletonLock"];
  NSString *target = [NSFileManager.defaultManager destinationOfSymbolicLinkAtPath:lock error:nil];
  if (!target) return;
  pid_t pid = (pid_t)[[target componentsSeparatedByString:@"-"].lastObject intValue];
  if (pid > 0 && (kill(pid, 0) == 0 || errno != ESRCH)) return;
  for (NSString *name in @[@"SingletonLock", @"SingletonSocket", @"SingletonCookie"])
    [NSFileManager.defaultManager removeItemAtPath:[profile stringByAppendingPathComponent:name] error:nil];
  Log(@"removed a stale profile lock");
}

int main(int argc, char *argv[]) {
  @autoreleasepool {
    // The Keychain finds the user's default keychain through HOME, and a Keychain write with none shows "A keychain
    // cannot be found". Started by zerod, this app has zerod's environment, whose HOME a test zerod sets elsewhere:
    // the user database's home instead, as an app the system launches gets.
    if (struct passwd *pw = getpwuid(getuid())) setenv("HOME", pw->pw_dir, 1);
    // No default keychain, or one that can't be read: Chromium's key stays in memory rather than a write asking the
    // user to make one.
    // Zero Dev's keeps no Keychain item at all, and none of its Keychain calls may ask the user anything.
    bool dev = gDev = [NSBundle.mainBundle.bundleIdentifier hasSuffix:@".dev.browser"];
    SecKeychainRef keychain = nullptr;
    SecKeychainStatus status = 0;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    if (dev) SecKeychainSetUserInteractionAllowed(false);
    gNoKeychain = dev || SecKeychainCopyDefault(&keychain) != errSecSuccess || SecKeychainGetStatus(keychain, &status) != errSecSuccess;
#pragma clang diagnostic pop
    if (keychain) CFRelease(keychain);
    if (gNoKeychain) Log(@"no default keychain: Chromium's key stays in memory");
    // Only zerod may drive it: the maker of the inherited socket, by its signature.
    audit_token_t token;
    socklen_t len = sizeof token;
    if (getsockopt(0, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &len) != 0) {
      Log(@"fd 0 is not a socket; quitting");
      return 3;
    }
    if (!Trusted(token, SignedAs(@"zerod").UTF8String)) {
      Log(@"fd 0 is not a socket from zerod; quitting");
      return 3;
    }
    CefScopedLibraryLoader loader;
    if (!loader.LoadInMain()) return 1;
    [BrowserApplication sharedApplication];
    NSApp.activationPolicy = NSApplicationActivationPolicyProhibited;

    CefMainArgs args(argc, argv);
    CefSettings settings;
    settings.windowless_rendering_enabled = true;
    settings.command_line_args_disabled = true;
    // Cookies and saved data are encrypted with a key in the login keychain, in an item of this app's own (by its
    // name, Zero Browser): CEF's default, "Chromium Safe Storage", is any Chromium's, and reading
    // another app's item prompts.
    NSString *name = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleName"] ?: @"Zero Browser";
    CefString(&settings.keychain_service_name) = [name stringByAppendingString:@" Safe Storage"].UTF8String;
    CefString(&settings.keychain_account_name) = name.UTF8String;
    NSString *cache = [NSHomeDirectory() stringByAppendingPathComponent:
                                             [@"Library/Caches" stringByAppendingPathComponent:NSBundle.mainBundle.bundleIdentifier]];
    ClearStaleLock(cache);
    CefString(&settings.root_cache_path) = cache.UTF8String;
    gToolsState = [cache stringByAppendingPathComponent:@"zero-tools-state.json"];
    CefString(&settings.cache_path) = [cache stringByAppendingPathComponent:@"Default"].UTF8String;
    // Nested in Zero.app (Contents/Helpers), so say which bundle is ours: Chromium would otherwise look for the
    // outermost .app around it.
    NSBundle *me = NSBundle.mainBundle;
    CefString(&settings.main_bundle_path) = me.bundlePath.UTF8String;
    CefString(&settings.framework_dir_path) = [me.privateFrameworksPath stringByAppendingPathComponent:@"Chromium Embedded Framework.framework"].UTF8String;
    if (!CefInitialize(args, settings, new App(), nullptr)) return 2;

    mach_port_t service = MACH_PORT_NULL;
    std::string frames = std::string(NSBundle.mainBundle.bundleIdentifier.UTF8String) + ".frames." + std::to_string(getpid());
    kern_return_t kr = bootstrap_check_in(bootstrap_port, frames.c_str(), &service);
    if (kr != KERN_SUCCESS) {
      Log([NSString stringWithFormat:@"bootstrap_check_in failed: %d", kr]);
      return 4;
    }
    ListenForHello(service);
    // Quit as asked (zerod stopping it): cleanly, so cookies and storage are written out.
    signal(SIGTERM, SIG_IGN);
    gTermSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGTERM, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(gTermSource, ^{ Quit(); });
    dispatch_resume(gTermSource);
    ReadZerod();
    // The tools page, once the message loop runs.
    dispatch_async(dispatch_get_main_queue(), ^{
      gTools = new ToolsPage();
      gTools->Create();
    });
    // Handed the front (Zero.app does while a dialog shows): the dialog takes the keyboard, and stays with its tab.
    [NSNotificationCenter.defaultCenter addObserverForName:NSApplicationDidBecomeActiveNotification object:nil queue:nil
                                                usingBlock:^(NSNotification *) {
                                                  if (gDialogShown) DialogTakesKeyboard();
                                                  PlaceDialogs(nil);
                                                }];
    // Who has the keyboard while a dialog shows, for a log of any back and forth.
    for (NSNotificationName name in @[NSApplicationDidBecomeActiveNotification, NSApplicationDidResignActiveNotification])
      [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:nil usingBlock:^(NSNotification *note) {
        if (gDialogShown) Log([NSString stringWithFormat:@"tab %d: %@", gDialogTab, note.name]);
      }];
    // A window of this app coming or going is a dialog (the shield aside), asked for by its page or not: seen at once.
    // Chrome resizes its dialog from step to step, and moves it to where it thinks the tab is (it knows no screen
    // place for the page): centred on the tab again in the same turn, before a frame shows it elsewhere.
    for (NSNotificationName name in @[NSWindowDidChangeOcclusionStateNotification, NSWindowDidMoveNotification, NSWindowDidResizeNotification])
      [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:nil usingBlock:^(NSNotification *note) {
        if (note.object == gShield) return;
        if (gWatch || gDialogShown || Shown().count) CheckDialogs();
        if (gDialogShown) PlaceDialogs(nil);
      }];
    // Closed (and not merely ordered out, which its occlusion tells): gone once it is.
    [NSNotificationCenter.defaultCenter addObserverForName:NSWindowWillCloseNotification object:nil queue:nil
                                                usingBlock:^(NSNotification *note) {
                                                  if (note.object == gShield || !gDialogShown) return;
                                                  dispatch_async(dispatch_get_main_queue(), ^{ if (gDialogShown) CheckDialogs(); });
                                                }];
    Log(@"started by zerod; waiting for Zero.app's hello");
    CefRunMessageLoop();
    gTabs.clear();
    CefShutdown();
    Log(@"shut down cleanly");
  }
  return 0;
}
