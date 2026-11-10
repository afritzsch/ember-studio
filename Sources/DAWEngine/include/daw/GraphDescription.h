#pragma once
// 05-mixer-routing-pdc Interfaces (contract): the plain-data description of a session's routing
// that DAWModel produces (MODEL-020) and GraphBuilder compiles into a RenderGraph (MIX-001).
//
// This header is on the public include path that Swift sees through the facade (01 Interfaces),
// so it includes only the standard library. NodeID, ParamID and Tick repeat the engine's
// aliases (core/Node.h, core/ParamSlotTable.h, time/TempoMap.h); redeclaring an alias to the
// same type is legal, and a mismatch would fail to compile wherever both are included.

#include <cstdint>
#include <string>
#include <vector>

namespace daw {

using NodeID = uint64_t;
using ParamID = uint32_t;
using Tick = int64_t;

enum class NodeKind : uint16_t { audioClipPlayer, midiClipPlayer, sampler, channelStrip, gain, eq, compressor,
                                 delay, reverb, metronome, auPlugin, vst3Plugin, master, bus };

// PLUG-018 (T-064, additive, see specs/10 "Contract delta (T-064)"): `bypassParam` is the param
// slot of the node's host-side bypass, kNoBypassParam for none. A node with one stays in the graph
// whether or not it is bypassed: while the slot is >= 0.5 GraphBuilder's BypassNode passes its
// main input through, delayed by the node's latency, so PDC never changes, and toggling it is a
// slot write, never a rebuild. It isn't part of [firstParam, firstParam + numParams).
inline constexpr ParamID kNoBypassParam = 0xFFFF'FFFFu;

struct NodeDesc { NodeID id; NodeKind kind; uint32_t configVersion; /* bump → re-prepare */
                  ParamID firstParam; uint32_t numParams; std::string configJSON; /* kind-specific, non-RT */
                  ParamID bypassParam = kNoBypassParam; /* T-064 */ };

enum class EdgeKind : uint8_t { audio, midi, sidechain };

// MIX-004: toPort is 0 in v1. Audio edges feed the node's main input, sidechain edges its
// sidechain input; edges into one port are summed.
struct EdgeDesc { uint64_t edgeID; NodeID from; NodeID to; EdgeKind kind; uint8_t toPort; };

struct ClipDesc { NodeID player; uint64_t clipID; Tick start; Tick length; uint64_t assetID;
                  int64_t sourceOffsetSamples; float gain; Tick fadeIn, fadeOut; /* audio */ };

struct NoteDesc { NodeID player; Tick start; Tick length; uint8_t pitch, velocity, channel; };

// TIME model (03): step tempo changes and time signatures, each list starting at tick 0. No
// sample rate: GraphBuilder builds the TempoMap at the rate it prepares nodes at.
struct TempoPointDesc { Tick tick; double bpm; };              // mirrors daw::TempoEvent (03)
struct TimeSigDesc    { Tick tick; int32_t num; int32_t den; }; // mirrors daw::TimeSigEvent (03)
struct TempoMapDesc   { std::vector<TempoPointDesc> tempos; std::vector<TimeSigDesc> timeSigs; };

// REC-020..022 (T-054, 09 "Contract delta (T-054)"): an audio track's input monitoring. `player`
// is the track's audioClipPlayer. While monitoring is active (REC-020, evaluated per block from
// the value in `modeSlot`, a MonitoringMode, and the transport), device input channels
// 2·inputPair and 2·inputPair + 1 replace the player's output into the track's chain (REC-021).
// `armed` and `inputPair` are structural (changing them rebuilds); the mode is a slot (no rebuild).
struct MonitorDesc { NodeID player; ParamID modeSlot; uint32_t inputPair; bool armed; };

struct GraphDescription { uint64_t version; std::vector<NodeDesc> nodes; std::vector<EdgeDesc> edges;
                          std::vector<ClipDesc> audioClips; std::vector<NoteDesc> notes;
                          TempoMapDesc tempo; NodeID master;
                          std::vector<MonitorDesc> monitors = {};  // T-054, additive
                        };

} // namespace daw
