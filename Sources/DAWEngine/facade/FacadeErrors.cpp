#include "facade/FacadeErrors.h"

#include <utility>

namespace daw {

FacadeError toFacadeError(const Error& error) {
    FacadeError out;
    out.message = error.message;
    switch (error.code) {
    case ErrorCode::invalidArgument: out.code = FacadeErrorCode::invalidArgument; break;
    case ErrorCode::outOfMemory: out.code = FacadeErrorCode::outOfMemory; break;
    case ErrorCode::notFound: out.code = FacadeErrorCode::notFound; break;
    case ErrorCode::unsupported: out.code = FacadeErrorCode::unsupported; break;
    case ErrorCode::io: out.code = FacadeErrorCode::io; break;
    case ErrorCode::internal: out.code = FacadeErrorCode::internal; break;
    case ErrorCode::cycle:  // DW-050, MIX-002
        out.code = FacadeErrorCode::cycle;
        out.cycle = error.nodes;
        break;
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
