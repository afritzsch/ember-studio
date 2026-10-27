#pragma once
// daw::Error (core/Result.h) → FacadeError, the form errors take across the bridge (PROPOSED,
// 08). DAWModel's EngineClient maps FacadeError to DAWError.

#include "core/Result.h"
#include "daw/EngineFacade.h"

namespace daw {

// Code for code. DW-050: ErrorCode::cycle (MIX-002) carries the cycle's NodeIDs in
// Error::nodes; they cross as FacadeError::cycle.
FacadeError toFacadeError(const Error& error);

FacadeError facadeError(FacadeErrorCode code, std::string message);

} // namespace daw
