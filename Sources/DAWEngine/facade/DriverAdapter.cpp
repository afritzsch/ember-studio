#include "facade/DriverAdapter.h"

namespace daw {

// T-011 wraps CoreAudioDriver in a DriverAdapter and returns it here.
std::unique_ptr<DriverAdapter> makeDefaultDriverAdapter() { return nullptr; }

} // namespace daw
