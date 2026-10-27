#pragma once
// C++-only ways to create an EngineFacade (Swift uses EngineFacade::create). They inject what
// the default facade picks for itself: the device driver (realtime mode) and extra node kinds.
// The app and tools never need them; later tasks (a driver in T-011, test nodes in TEST-004) do.

#include <functional>
#include <memory>

#include "core/Result.h"
#include "daw/EngineFacade.h"
#include "facade/DriverAdapter.h"
#include "graph/NodeRegistry.h"

namespace daw {

struct FacadeOptions {
    // Realtime mode only. Null: run without a device (until T-011, the default).
    std::unique_ptr<DriverAdapter> driver;
    // Runs on the facade's registry after the built-in kinds are in; may add or replace kinds.
    std::function<Result<void>(NodeRegistry&)> registerNodes;
};

class EngineFacadeAccess {
public:
    // Like EngineFacade::create (one reference, for releaseFacade), with `options`.
    static EngineFacade* create(EngineMode mode, const DriverConfig& config, FacadeOptions options);
};

} // namespace daw
