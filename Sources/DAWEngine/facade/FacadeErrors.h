#pragma once
// daw::Error (core/Result.h) → FacadeError, the form errors take across the bridge (PROPOSED,
// 08). DAWModel's EngineClient maps FacadeError to DAWError.

#include "core/Result.h"
#include "daw/EngineFacade.h"

namespace daw {

// DW-050: a routing cycle becomes code `cycle` with its NodeIDs. GraphBuilder reports it as
// invalidArgument "cycle: <ids>" (MIX-002) until T-087 adds ErrorCode::cycle; the message is
// what's recognised, so either form maps the same way.
FacadeError toFacadeError(const Error& error);

FacadeError facadeError(FacadeErrorCode code, std::string message);

} // namespace daw
