#include "facade/FacadeErrors.h"

#include <cstdlib>
#include <string_view>
#include <utility>

namespace daw {

namespace {

constexpr std::string_view kCyclePrefix = "cycle:";

FacadeErrorCode mapCode(ErrorCode code) {
    switch (code) {
    case ErrorCode::invalidArgument: return FacadeErrorCode::invalidArgument;
    case ErrorCode::outOfMemory: return FacadeErrorCode::outOfMemory;
    case ErrorCode::notFound: return FacadeErrorCode::notFound;
    case ErrorCode::unsupported: return FacadeErrorCode::unsupported;
    case ErrorCode::io: return FacadeErrorCode::io;
    case ErrorCode::internal: return FacadeErrorCode::internal;
    // DW-050: T-087 adds ErrorCode::cycle; map it to FacadeErrorCode::cycle here.
    default: return FacadeErrorCode::internal;
    }
}

// "cycle: 3 7 9" (MIX-002, GraphBuilder) → {3, 7, 9}. Separators other than digits are skipped,
// so "3, 7, 9" parses the same.
std::vector<NodeID> parseCycle(std::string_view text) {
    std::vector<NodeID> ids;
    std::size_t i = 0;
    while (i < text.size()) {
        if (text[i] < '0' || text[i] > '9') {
            ++i;
            continue;
        }
        NodeID id = 0;
        while (i < text.size() && text[i] >= '0' && text[i] <= '9') id = id * 10 + NodeID(text[i++] - '0');
        ids.push_back(id);
    }
    return ids;
}

} // namespace

FacadeError toFacadeError(const Error& error) {
    FacadeError out;
    out.message = error.message;
    const std::string_view message = error.message;
    if (message.substr(0, kCyclePrefix.size()) == kCyclePrefix) {
        out.code = FacadeErrorCode::cycle;
        out.cycle = parseCycle(message.substr(kCyclePrefix.size()));
    } else {
        out.code = mapCode(error.code);
    }
    return out;
}

FacadeError facadeError(FacadeErrorCode code, std::string message) {
    FacadeError out;
    out.code = code;
    out.message = std::move(message);
    return out;
}

} // namespace daw
