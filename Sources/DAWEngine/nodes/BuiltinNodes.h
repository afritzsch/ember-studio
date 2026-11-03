#pragma once
// Registers the node kinds that live in nodes/ (06-dsp-builtins) with a NodeRegistry. Whoever
// builds the GraphCompiler's registry (the facade, T-014; tests) calls it after
// NodeRegistry::withBuiltins(). Non-RT.
//
//   audioClipPlayer  DSP-001; clips are fixed at creation (DW-051, see AudioClipPlayer.h), assets
//                    come from `lookup`
//   midiClipPlayer   DSP-003; MIDI only (no audio output), notes are fixed at creation (DW-051,
//                    see MidiClipPlayer.h)
//   sampler          DSP-020..023; zones from configJSON, fixed at creation (DW-051, see
//                    Sampler.h), assets from `lookup`; params beyond numParams use defaults
//   channelStrip     DSP-010 / MIX-005 gain, pan, mute, phase; needs numParams >=
//                    ChannelStrip::kNumParams (invalidArgument otherwise). Meters into
//                    `telemetry` (the engine's) with the MeterID GraphBuilder assigns (DW-048,
//                    GraphBuilder::meterOf); a null `telemetry` means no metering.
//   gain             MIX-007 send (GainNode): level and mute, numParams GainNode::kNumParams; a
//                    plain gain with numParams 1 has no mute; 0 is invalidArgument.
//   metronome        TIME-010 / DSP-011 click (Metronome): params on, level, accent; slots
//                    beyond numParams use their defaults (see Metronome.h).
//   compressor       DSP-031 feed-forward compressor (Compressor), keyed by the node's sidechain
//                    input when one is routed (MIX-008); 7 params, slots beyond numParams use
//                    their defaults; meters its gain reduction into `telemetry` (see Compressor.h).
//   reverb           DSP-033 8-line FDN reverb (Reverb): params size, decay, damping, predelay,
//                    mix; slots beyond numParams use their defaults (see Reverb.h).

#include "core/Result.h"
#include "core/Telemetry.h"
#include "graph/NodeRegistry.h"
#include "nodes/AssetLookup.h"

namespace daw {

Result<void> registerBuiltinNodes(NodeRegistry& registry, AssetLookup lookup,
                                  Telemetry* telemetry = nullptr);

} // namespace daw
