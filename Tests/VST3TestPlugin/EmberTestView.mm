// T-063 (PLUG-017, DW-208): EmberTest's own minimal IPlugView, so editor tests don't need vstgui4.
// A plain NSView child of the host's container, 400 × 300 to start, resizable down to 200 × 150.
// It draws a dark background with an orange bar as wide as the controller's normalized gain, so a
// snapshot shows the parameter. Exported knobs (dlsym'd by the tests) read its state and make it
// ask the host for a new size through IPlugFrame::resizeView, as a real editor does.

#import <AppKit/AppKit.h>

#include <atomic>
#include <cstring>

#include "pluginterfaces/gui/iplugview.h"
#include "public.sdk/source/common/pluginview.h"
#include "public.sdk/source/vst/vsteditcontroller.h"

using namespace Steinberg;
using namespace Steinberg::Vst;

@interface EmberTestEditorView : NSView {
@public
    EditController* controller;  // owned by the IPlugView, which outlives this view's use
}
@end

@implementation EmberTestEditorView
- (BOOL)isFlipped {
    return YES;
}
- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    [[NSColor colorWithCalibratedRed:0.12 green:0.12 blue:0.14 alpha:1] setFill];
    NSRectFill(self.bounds);
    const double gain = controller != nullptr ? controller->getParamNormalized(0) : 0;
    [[NSColor colorWithCalibratedRed:0.95 green:0.45 blue:0.1 alpha:1] setFill];
    NSRectFill(NSMakeRect(20, 20, (self.bounds.size.width - 40) * gain, 40));
    [@"Ember Test" drawAtPoint:NSMakePoint(20, 80)
                withAttributes:@{NSForegroundColorAttributeName: NSColor.whiteColor,
                                 NSFontAttributeName: [NSFont systemFontOfSize:18]}];
}
@end

namespace {

class EmberPlugView;
std::atomic<EmberPlugView*> gLastView{nullptr};
std::atomic<int32_t> gLiveViews{0};

class EmberPlugView final : public CPluginView {
public:
    explicit EmberPlugView(EditController* controller) : CPluginView(&kDefaultSize), controller_(controller) {
        controller_->addRef();
        gLiveViews.fetch_add(1);
        gLastView.store(this);
    }
    ~EmberPlugView() override {
        EmberPlugView* self = this;
        gLastView.compare_exchange_strong(self, nullptr);
        gLiveViews.fetch_sub(1);
        controller_->release();
    }

    tresult PLUGIN_API isPlatformTypeSupported(FIDString type) SMTG_OVERRIDE {
        return std::strcmp(type, kPlatformTypeNSView) == 0 ? kResultTrue : kResultFalse;
    }
    void attachedToParent() SMTG_OVERRIDE {
        NSView* parent = (__bridge NSView*)systemWindow;
        view_ = [[EmberTestEditorView alloc] initWithFrame:NSMakeRect(0, 0, rect.getWidth(), rect.getHeight())];
        view_->controller = controller_;
        [parent addSubview:view_];
    }
    void removedFromParent() SMTG_OVERRIDE {
        view_->controller = nullptr;
        [view_ removeFromSuperview];
        view_ = nil;
    }
    tresult PLUGIN_API onSize(ViewRect* newSize) SMTG_OVERRIDE {
        CPluginView::onSize(newSize);
        if (view_ != nil) view_.frame = NSMakeRect(0, 0, rect.getWidth(), rect.getHeight());
        return kResultTrue;
    }
    tresult PLUGIN_API canResize() SMTG_OVERRIDE { return kResultTrue; }
    tresult PLUGIN_API checkSizeConstraint(ViewRect* r) SMTG_OVERRIDE {
        if (r->getWidth() < 200) r->right = r->left + 200;
        if (r->getHeight() < 150) r->bottom = r->top + 150;
        return kResultTrue;
    }

    tresult requestResize(int32 width, int32 height) {
        if (!plugFrame) return kResultFalse;
        ViewRect r(0, 0, width, height);
        return plugFrame->resizeView(this, &r);
    }
    bool attachedNow() const { return isAttached() && view_ != nil; }
    void redraw() { [view_ setNeedsDisplay:YES]; }

private:
    static inline const ViewRect kDefaultSize{0, 0, 400, 300};
    EditController* controller_;
    EmberTestEditorView* view_ = nil;
};

} // namespace

// EmberTestPlugin.cpp's controller makes its editor here.
IPlugView* emberCreateEditorView(EditController* controller) { return new EmberPlugView(controller); }
void emberRedrawEditor() {
    if (EmberPlugView* view = gLastView.load()) view->redraw();
}

extern "C" {

// The newest editor: how many are alive, whether it is attached, its size (as the host set it).
__attribute__((visibility("default"))) void ember_test_view_info(int32_t* live, int32_t* attached, int32_t* width,
                                                                 int32_t* height) {
    EmberPlugView* view = gLastView.load();
    *live = gLiveViews.load();
    *attached = view != nullptr && view->attachedNow() ? 1 : 0;
    *width = view != nullptr ? view->getRect().getWidth() : 0;
    *height = view != nullptr ? view->getRect().getHeight() : 0;
}

// The newest editor asks its host for width × height (IPlugFrame::resizeView). Main thread.
__attribute__((visibility("default"))) int32_t ember_test_view_request_resize(int32_t width, int32_t height) {
    EmberPlugView* view = gLastView.load();
    return view != nullptr ? view->requestResize(width, height) : kResultFalse;
}

} // extern "C"
