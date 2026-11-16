#include "plugins/PluginEditQueue.h"

namespace daw {

// DW-204: see PluginEditQueue.h.
void PluginEditQueue::push(const PluginParamEdit& edit) {
    std::lock_guard lock(mutex_);
    // A newer value of the same parameter replaces one not yet taken, unless a begin or end of that
    // parameter sits after it (the gesture's shape must survive).
    if (edit.phase == PluginEditKind::value) {
        for (auto it = edits_.rbegin(); it != edits_.rend(); ++it) {
            if (it->slot != edit.slot || it->index != edit.index) continue;
            if (it->phase == PluginEditKind::value) {
                it->value = edit.value;
                return;
            }
            break;
        }
    }
    if (edits_.size() >= kCapacity) {
        edits_.pop_front();
        ++dropped_;
    }
    edits_.push_back(edit);
}

std::vector<PluginParamEdit> PluginEditQueue::take() {
    std::lock_guard lock(mutex_);
    std::vector<PluginParamEdit> out(edits_.begin(), edits_.end());
    edits_.clear();
    return out;
}

uint64_t PluginEditQueue::dropped() const {
    std::lock_guard lock(mutex_);
    return dropped_;
}

} // namespace daw
