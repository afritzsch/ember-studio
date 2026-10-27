#pragma once
// T-010 checks for AudioAsset, AudioFileLoader, PeakMipmap and AudioImporter (io/), run from
// Tests/DAWEngineTests/AudioFileLoaderTests.swift. They're C++ because the engine types are
// move-only or ref-counted handles behind daw::Result, the loader has its own thread, the RT
// checks need RtScope, and test files are written with AudioToolbox.

#include "Checks.h"

#include <cstdint>

namespace daw::testing {

// IO-032
CheckResult assetContractLayout();
CheckResult assetRefCounting();
CheckResult assetRetireThroughHook();
CheckResult assetConcurrentRelease();
CheckResult assetBuilder();
// CONV §5.3: retains and releases (including the last one, into a queue hook) inside an RtScope.
uint64_t assetRetainReleaseViolations();
// IO-032 with T-004's Engine (ENG-012..014; AssetReclaimChecks.cpp): a node's last reference,
// dropped in process(), is freed by daw.reclaim; a reference that isn't the last only
// decrements; a graph-held reference dies on daw.reclaim; a full RetireQueue keeps the reference.
CheckResult assetRetiredOnReclaim();
CheckResult assetRetireNotLast();
CheckResult assetGraphReferenceDiesOnReclaim();
CheckResult assetRetireQueueFull();

// IO-031
// 48k → 44.1k → 48k through files and the loader; the residual vs the original in dB, or +inf
// if a step failed.
double resampleRoundTripResidualDb();
// One file format (TestAudio.h names), decoded at its own rate and resampled.
CheckResult decodeFormat(const char* formatName);
CheckResult decodeChannelCounts();
CheckResult loadErrors();
CheckResult loaderThread();

// IO-034
CheckResult peaksMatchBruteForce();
CheckResult peakFileFormat();
CheckResult peakFileRejectsCorrupt();
CheckResult loaderPeakCache();

// IO-030
CheckResult importCopiesUnchanged();
CheckResult importNameCollision();
CheckResult importReference();
CheckResult importRejectsNonAudio();

} // namespace daw::testing
