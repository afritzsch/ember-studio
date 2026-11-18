#pragma once
// T-094 checks for hosted plugins' discrete params and display strings (DW-213, 08/10 "Contract
// delta (T-094)"), run from Tests/DAWEngineTests/PluginInfoTests.swift through an offline
// EngineFacade: pluginInfoJSON's per-param "steps", "labels" and "display", and paramDisplay.

#include "Checks.h"

namespace daw::testing {

// DW-213, VST3 (the SDK's `again`, scripts/build-test-vst3.sh): gain is continuous (steps 0) and
// its display is again's own dB string ("0.00" at 1.0); paramDisplay names other values ("-6.02"
// at 0.5, "-oo" at 0); bypass is a switch (steps 1, labels Off/On); an unknown index or slot gives
// "".
CheckResult vst3ParamDisplayStrings();

// DW-213, AU (Apple's AUNBandEQ): a Boolean param is a switch (steps 1); an Indexed one with
// valueStrings has steps max − min and those labels, and its display and paramDisplay name the
// value; AUDelay's params have no strings (no "display", paramDisplay ""), and a param without a
// unitName gets its unit's symbol ("Secs" stays, Hz…).
CheckResult auParamDisplayStrings();

} // namespace daw::testing
