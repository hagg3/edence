#include "EdenAppDelegate_web.h"

namespace eden_web {

void EdenAppDelegate::didFinishLaunching() {
    viewController.construct();
    viewController.startAnimation();
}

void EdenAppDelegate::onVisibilityHidden() {
    viewController.stopAnimation();
}

void EdenAppDelegate::onVisibilityVisible() {
    viewController.startAnimation();
}

void EdenAppDelegate::onPageHide() {
    // TODO P4/P7: World save-on-exit (audit C1, see header). Left as a stop-only no-op until
    // FileManager's web-facing save entry point exists — calling stopAnimation() at least
    // matches the original's applicationWillTerminate: -> [viewController stopAnimation]
    // (Classes/EdenAppDelegate.mm:51-54).
    viewController.stopAnimation();
}

} // namespace eden_web
