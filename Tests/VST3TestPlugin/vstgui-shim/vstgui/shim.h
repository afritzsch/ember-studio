#pragma once
// T-062 test plugins only: just enough of VSTGUI's API for the SDK's `again` sample (controller
// and UI message controller) to compile unmodified against a checkout without vstgui4, which
// bootstrap doesn't fetch (BUILD-006). The editor it declares is an empty view, so these test
// bundles have no real UI; hosting an actual editor is T-063's.

#include <string>

#include "pluginterfaces/gui/iplugview.h"
#include "public.sdk/source/common/pluginview.h"

namespace VSTGUI {

using UTF8StringPtr = const char*;

class UTF8String {
public:
    UTF8String() = default;
    UTF8String(const char* s) : s_(s ? s : "") {}
    UTF8String(std::string s) : s_(std::move(s)) {}
    const char* data() const { return s_.c_str(); }
    const std::string& getString() const { return s_; }

private:
    std::string s_;
};

class UTF8StringView {
public:
    explicit UTF8StringView(const char* s) : s_(s ? s : "") {}
    bool operator==(const char* other) const { return s_ == (other ? other : ""); }

private:
    std::string s_;
};

struct UIAttributes {};
class IUIDescription;

class CView {
public:
    virtual ~CView() = default;
};

class CControl : public CView {
public:
    int getTag() const { return 0; }
    float getValueNormalized() const { return 0.0f; }
    void setValue(float) {}
    void invalid() {}
};

class IViewListener;

class CTextEdit : public CView {
public:
    void setText(const UTF8String& text) { text_ = text; }
    const UTF8String& getText() const { return text_; }
    void registerViewListener(IViewListener*) {}
    void unregisterViewListener(IViewListener*) {}

private:
    UTF8String text_;
};

class IViewListener {
public:
    virtual ~IViewListener() = default;
    virtual void viewWillDelete(CView*) {}
    virtual void viewLostFocus(CView*) {}
};
using ViewListenerAdapter = IViewListener;

class IController {
public:
    virtual ~IController() = default;
    virtual void valueChanged(CControl*) = 0;
    virtual void controlBeginEdit(CControl*) {}
    virtual void controlEndEdit(CControl*) {}
    virtual CView* verifyView(CView* view, const UIAttributes&, const IUIDescription*) { return view; }
};

class VST3Editor : public Steinberg::CPluginView {
public:
    VST3Editor(void*, const char*, const char*) {}
};

class VST3EditorDelegate {
public:
    virtual ~VST3EditorDelegate() = default;
    virtual IController* createSubController(UTF8StringPtr, const IUIDescription*, VST3Editor*) { return nullptr; }
};

} // namespace VSTGUI
