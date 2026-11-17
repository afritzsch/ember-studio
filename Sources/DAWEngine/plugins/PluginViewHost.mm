// PLUG-017 (T-063): plugin editors (see PluginViewHost.h).
//
// ARC (SwiftPM compiles Objective-C++ with -fobjc-arc): an Editor's strong members own the
// container view and the AU view controller.

#include "plugins/PluginViewHost.h"

#import <AppKit/AppKit.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreAudioKit/CoreAudioKit.h>
#include <dispatch/dispatch.h>
#include <pthread.h>

#include <algorithm>
#include <atomic>

#include "plugins/AUInstance.h"
#include "plugins/PluginJSON.h"
#include "plugins/VST3Instance.h"

#include "pluginterfaces/base/funknownimpl.h"
#include "pluginterfaces/gui/iplugview.h"
#include "pluginterfaces/vst/ivsteditcontroller.h"

namespace daw {
namespace {

using namespace Steinberg;

constexpr double kPlaceholderWidth = 400, kPlaceholderHeight = 300;
// An AU that never answers requestViewController (it should, with nil when it has no view) gets
// the generic view after this long.
constexpr double kViewControllerTimeoutSeconds = 2.0;
constexpr uint64_t kSyncIntervalNanos = NSEC_PER_SEC / 30;

bool onMainThread() { return pthread_main_np() != 0; }

} // namespace
} // namespace daw

@class DAWPluginContainerView;

namespace daw {

class PlugFrame;

struct PluginViewHost::Editor {
    NodeID slot = 0;
    std::shared_ptr<AUInstance> au;
    std::shared_ptr<VST3Instance> vst3;
    std::string title;
    std::string kind;  // "au", "auGeneric", "vst3" (main thread; json copies under the host mutex)
    std::atomic<bool> ready{false};
    std::atomic<bool> resizable{false};
    std::atomic<double> width{kPlaceholderWidth}, height{kPlaceholderHeight};
    bool closed = false;

    // Main thread only.
    DAWPluginContainerView* container = nil;
    NSViewController* viewController = nil;  // AU
    IPtr<IPlugView> plugView;               // VST3
    IPtr<PlugFrame> plugFrame;
    bool inResize = false;

    const void* instance() const {
        return au ? static_cast<const void*>(au.get()) : static_cast<const void*>(vst3.get());
    }

    void containerResized();
    void embedAU(NSViewController* controller, AUAudioUnit* unit);
    void close();
};

// PLUG-017: the VST3 view's IPlugFrame. Calls come on the main thread (the view's UI thread).
class PlugFrame final : public U::Implements<U::Directly<IPlugFrame>> {
public:
    explicit PlugFrame(PluginViewHost::Editor* editor) : editor_(editor) {}
    void detach() { editor_ = nullptr; }

    // The plugin asks for a new size: the container (and with it the host's window) takes it, then
    // the view is told (onSize), as the VST3 resize protocol has it.
    tresult PLUGIN_API resizeView(IPlugView* view, ViewRect* newSize) override;

private:
    PluginViewHost::Editor* editor_;
};

} // namespace daw

// The container the host shows. A resize from outside (the window) reaches a VST3 view.
@interface DAWPluginContainerView : NSView {
@public
    daw::PluginViewHost::Editor* editor;  // cleared when the editor closes
}
@end

@implementation DAWPluginContainerView
- (BOOL)isFlipped {
    return YES;  // VST3 views and most AU views lay out from the top left
}
- (void)setFrameSize:(NSSize)size {
    [super setFrameSize:size];
    if (editor != nullptr) editor->containerResized();
}
@end

namespace daw {

tresult PLUGIN_API PlugFrame::resizeView(IPlugView* view, ViewRect* newSize) {
    if (editor_ == nullptr || newSize == nullptr || view != editor_->plugView.get()) return kInvalidArgument;
    if (newSize->getWidth() <= 0 || newSize->getHeight() <= 0) return kInvalidArgument;
    editor_->inResize = true;
    [editor_->container setFrameSize:NSMakeSize(newSize->getWidth(), newSize->getHeight())];
    editor_->inResize = false;
    view->onSize(newSize);
    return kResultTrue;
}

void PluginViewHost::Editor::containerResized() {
    const NSSize size = container.frame.size;
    width.store(size.width, std::memory_order_relaxed);
    height.store(size.height, std::memory_order_relaxed);
    if (!plugView || inResize) return;
    // Resized from outside: a resizable view may adjust the size it takes, then is told.
    if (plugView->canResize() != kResultTrue) return;
    ViewRect rect(0, 0, static_cast<int32>(size.width), static_cast<int32>(size.height));
    plugView->checkSizeConstraint(&rect);
    plugView->onSize(&rect);
}

void PluginViewHost::Editor::embedAU(NSViewController* controller, AUAudioUnit* unit) {
    if (closed || ready.load()) return;
    if (controller == nil) {
        // PLUG-017: no view of its own: CoreAudioKit's generic one, built from the parameter tree.
        AUGenericViewController* generic = [[AUGenericViewController alloc] init];
        generic.auAudioUnit = unit;
        controller = generic;
        kind = "auGeneric";
    }
    viewController = controller;
    NSView* view = controller.view;
    NSSize size = controller.preferredContentSize;
    if (size.width < 1 || size.height < 1) size = view.frame.size;
    if (size.width < 1 || size.height < 1) size = view.fittingSize;
    if (size.width < 1 || size.height < 1) size = NSMakeSize(kPlaceholderWidth, kPlaceholderHeight);
    view.frame = NSMakeRect(0, 0, size.width, size.height);
    view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [container addSubview:view];
    [container setFrameSize:size];
    resizable.store(true);
    ready.store(true);
}

void PluginViewHost::Editor::close() {
    if (closed) return;
    closed = true;
    if (plugView) {
        plugView->removed();
        plugView->setFrame(nullptr);
        plugView = nullptr;
    }
    if (plugFrame) {
        plugFrame->detach();
        plugFrame = nullptr;
    }
    if (viewController != nil) {
        [viewController.view removeFromSuperview];
        viewController = nil;
    }
    if (container != nil) {
        container->editor = nullptr;
        container = nil;
    }
}

PluginViewHost::PluginViewHost() : shared_(std::make_shared<Shared>()) {}

PluginViewHost::~PluginViewHost() {
    std::vector<std::shared_ptr<Editor>> editors;
    {
        std::lock_guard lock(shared_->mutex);
        editors.swap(shared_->editors);
    }
    dispatch_source_t timer = syncTimer_ != nullptr ? (__bridge_transfer dispatch_source_t)syncTimer_ : nil;
    syncTimer_ = nullptr;
    auto finish = [editors, timer] {
        @autoreleasepool {
            for (const auto& e : editors) e->close();
        }
        if (timer != nil) dispatch_source_cancel(timer);
    };
    if (onMainThread()) {
        finish();
    } else {
        // The views are main-thread objects; the editors keep their instances until then.
        dispatch_async(dispatch_get_main_queue(), ^{
            finish();
        });
    }
}

void* PluginViewHost::open(NodeID slot, const std::shared_ptr<AUInstance>& au, const std::shared_ptr<VST3Instance>& vst3) {
    if (!onMainThread() || (!au && !vst3)) return nullptr;
    @autoreleasepool {
        const void* instance = au ? static_cast<const void*>(au.get()) : static_cast<const void*>(vst3.get());
        {
            std::lock_guard lock(shared_->mutex);
            for (const auto& e : shared_->editors)
                if (e->slot == slot && e->instance() == instance) return (__bridge void*)e->container;
        }
        close(slot);  // a stale editor (another instance) goes first

        auto editor = std::make_shared<Editor>();
        editor->slot = slot;
        editor->au = au;
        editor->vst3 = vst3;
        editor->container = [[DAWPluginContainerView alloc]
            initWithFrame:NSMakeRect(0, 0, kPlaceholderWidth, kPlaceholderHeight)];
        editor->container->editor = editor.get();
        editor->container.postsFrameChangedNotifications = YES;

        if (vst3) {
            editor->title = vst3->name();
            editor->kind = "vst3";
            Vst::IEditController* controller = vst3->editController();
            if (controller == nullptr) return nullptr;
            IPtr<IPlugView> view = owned(controller->createView(Vst::ViewType::kEditor));
            if (!view || view->isPlatformTypeSupported(kPlatformTypeNSView) != kResultTrue) {
                editor->close();
                return nullptr;
            }
            ViewRect rect;
            if (view->getSize(&rect) != kResultOk || rect.getWidth() <= 0 || rect.getHeight() <= 0)
                rect = ViewRect(0, 0, static_cast<int32>(kPlaceholderWidth), static_cast<int32>(kPlaceholderHeight));
            editor->plugView = view;
            editor->plugFrame = owned(new PlugFrame(editor.get()));
            view->setFrame(editor->plugFrame);
            editor->inResize = true;
            [editor->container setFrameSize:NSMakeSize(rect.getWidth(), rect.getHeight())];
            editor->inResize = false;
            if (view->attached((__bridge void*)editor->container, kPlatformTypeNSView) != kResultOk) {
                editor->close();
                return nullptr;
            }
            editor->resizable.store(view->canResize() == kResultTrue);
            editor->ready.store(true);
        } else {
            editor->title = au->name();
            editor->kind = "au";
            AUAudioUnit* unit = (__bridge AUAudioUnit*)au->audioUnit();
            if (unit == nil) return nullptr;
            std::weak_ptr<Editor> weak = editor;
            [unit requestViewControllerWithCompletionHandler:^(AUViewControllerBase* controller) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (auto e = weak.lock()) e->embedAU(controller, unit);
                });
            }];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, static_cast<int64_t>(kViewControllerTimeoutSeconds * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                               if (auto e = weak.lock()) e->embedAU(nil, unit);
                           });
        }

        void* view = (__bridge void*)editor->container;
        {
            std::lock_guard lock(shared_->mutex);
            shared_->editors.push_back(editor);
        }
        if (vst3) startSyncTimer();
        return view;
    }
}

void PluginViewHost::close(NodeID slot) {
    if (!onMainThread()) return;
    std::shared_ptr<Editor> editor;
    {
        std::lock_guard lock(shared_->mutex);
        auto it = std::find_if(shared_->editors.begin(), shared_->editors.end(), [slot](const auto& e) { return e->slot == slot; });
        if (it == shared_->editors.end()) return;
        editor = *it;
        shared_->editors.erase(it);
    }
    @autoreleasepool {
        editor->close();
    }
    stopSyncTimerIfIdle();
}

void PluginViewHost::closeAll() {
    for (NodeID slot : openSlots()) close(slot);
}

const void* PluginViewHost::instanceOf(NodeID slot) const {
    std::lock_guard lock(shared_->mutex);
    for (const auto& e : shared_->editors)
        if (e->slot == slot) return e->instance();
    return nullptr;
}

std::string PluginViewHost::json(NodeID slot, bool stale) const {
    std::lock_guard lock(shared_->mutex);
    for (const auto& e : shared_->editors) {
        if (e->slot != slot) continue;
        return "{\"slot\":" + std::to_string(slot) + ",\"open\":true,\"ready\":" + (e->ready.load() ? "true" : "false") +
               ",\"kind\":" + pluginJSONString(e->kind) + ",\"title\":" + pluginJSONString(e->title) +
               ",\"width\":" + pluginJSONNumber(e->width.load()) + ",\"height\":" + pluginJSONNumber(e->height.load()) +
               ",\"resizable\":" + (e->resizable.load() ? "true" : "false") + ",\"stale\":" + (stale ? "true" : "false") + "}";
    }
    return "{\"slot\":" + std::to_string(slot) + ",\"open\":false}";
}

std::vector<NodeID> PluginViewHost::openSlots() const {
    std::lock_guard lock(shared_->mutex);
    std::vector<NodeID> slots;
    for (const auto& e : shared_->editors) slots.push_back(e->slot);
    std::sort(slots.begin(), slots.end());
    return slots;
}

// DW-204: open VST3 editors follow the model (VST3Instance::syncEditor), on the main queue.
void PluginViewHost::startSyncTimer() {
    if (syncTimer_ != nullptr) return;
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, static_cast<int64_t>(kSyncIntervalNanos)),
                              kSyncIntervalNanos, kSyncIntervalNanos / 4);
    std::weak_ptr<Shared> weak = shared_;
    dispatch_source_set_event_handler(timer, ^{
        auto state = weak.lock();
        if (!state) return;
        std::vector<std::shared_ptr<VST3Instance>> instances;
        {
            std::lock_guard lock(state->mutex);
            for (const auto& e : state->editors)
                if (e->vst3 && e->ready.load()) instances.push_back(e->vst3);
        }
        for (const auto& instance : instances) instance->syncEditor();
    });
    dispatch_resume(timer);
    syncTimer_ = (__bridge_retained void*)timer;
}

void PluginViewHost::stopSyncTimerIfIdle() {
    if (syncTimer_ == nullptr) return;
    {
        std::lock_guard lock(shared_->mutex);
        for (const auto& e : shared_->editors)
            if (e->vst3) return;
    }
    dispatch_source_t timer = (__bridge_transfer dispatch_source_t)syncTimer_;
    syncTimer_ = nullptr;
    dispatch_source_cancel(timer);
}

} // namespace daw
