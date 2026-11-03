// IO-033 (T-056): see AssetReloader.h.

#include "facade/AssetReloader.h"

#include <algorithm>
#include <utility>

namespace daw {

uint64_t AssetReloader::recordLoad(uint64_t assetID, Source source) {
    Known& known = sources_[assetID];
    known.source = std::move(source);
    known.serial = nextSerial_++;
    return known.serial;
}

std::vector<AssetReloader::Request> AssetReloader::beginPass(double previousRate, double rate) {
    ++pass_;
    staged_.clear();
    std::vector<Request> requests;
    requests.reserve(sources_.size());
    for (const auto& [id, known] : sources_) requests.push_back(Request{id, known.source, pass_, known.serial});
    std::sort(requests.begin(), requests.end(),
              [](const Request& a, const Request& b) { return a.assetID < b.assetID; });
    progress_ = Progress{};
    progress_.previousRate = previousRate;
    progress_.rate = rate;
    progress_.total = static_cast<uint32_t>(requests.size());
    progress_.active = !requests.empty();
    return requests;
}

AssetReloader::Outcome AssetReloader::complete(const Request& request, Staged staged) {
    if (!progress_.active || request.pass != pass_) return Outcome::stale;
    ++progress_.done;
    auto known = sources_.find(request.assetID);
    const bool superseded = known == sources_.end() || known->second.serial != request.serial;
    if (!superseded) {
        if (!staged.asset) ++progress_.failed;
        staged.assetID = request.assetID;
        staged_.push_back(std::move(staged));
    }
    return progress_.done >= progress_.total ? Outcome::finished : Outcome::progress;
}

std::vector<AssetReloader::Staged> AssetReloader::takeStaged() {
    std::vector<Staged> out = std::move(staged_);
    staged_.clear();
    std::sort(out.begin(), out.end(), [](const Staged& a, const Staged& b) { return a.assetID < b.assetID; });
    progress_.active = false;
    return out;
}

} // namespace daw
