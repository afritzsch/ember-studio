// T-001 build checks for DAWEngine; scripts/test.sh inspects the resulting object file.

// BUILD-003: SDK headers resolve from DAWEngine, and the SDK version is the one we pinned.
#include "pluginterfaces/vst/vsttypes.h"
#include "public.sdk/source/vst/hosting/module.h"

static_assert(kVstVersionMajor == 3, "BUILD-003: unexpected VST3 SDK");

// BUILD-005: this symbol exists only when the RT trap is compiled in (Debug).
#if DAW_RT_TRAP
extern "C" const int daw_build_rt_trap_enabled = 1;
#endif
