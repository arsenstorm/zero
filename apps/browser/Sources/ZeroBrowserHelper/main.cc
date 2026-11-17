// Chromium's sub-processes (renderer, GPU, network, ...): the sandbox first, then the framework found relative to
// this helper (../../../Chromium Embedded Framework.framework), wherever the helpers and framework sit together.
#include "include/cef_app.h"
#include "include/cef_sandbox_mac.h"
#include "include/wrapper/cef_library_loader.h"

#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#include <pwd.h>
#include <stdlib.h>
#include <unistd.h>

// The user's real home: zerod's may be a test one, where the Keychain finds no keychain and a write asks the user to
// reset theirs.
static void KeychainSafe() {
  if (struct passwd* pw = getpwuid(getuid())) setenv("HOME", pw->pw_dir, 1);
  // Zero Dev's (com.arsen.zero.dev.browser.helper...): no Keychain prompt at all, whatever process of Chromium's asks.
  CFStringRef id = CFBundleGetIdentifier(CFBundleGetMainBundle());
  if (id && CFStringFind(id, CFSTR(".dev.browser."), 0).location != kCFNotFound) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    SecKeychainSetUserInteractionAllowed(false);
#pragma clang diagnostic pop
  }
}

int main(int argc, char* argv[]) {
  KeychainSafe();
  CefScopedSandboxContext sandbox;
  if (!sandbox.Initialize(argc, argv)) return 1;
  CefScopedLibraryLoader loader;
  if (!loader.LoadInHelper()) return 1;
  CefMainArgs args(argc, argv);
  return CefExecuteProcess(args, nullptr, nullptr);
}
