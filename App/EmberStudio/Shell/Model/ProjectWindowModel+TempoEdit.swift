import DAWModel
import Foundation

/// DW-180 (T-095, docs/autobuild/DECISIONS.md "T-095 app decisions"): the toolbar's tempo and time
/// signature are editable. A committed edit sets bar 1's value (`SetTempoEvent` / `SetTimeSignature`
/// at tick 0): one undo entry per commit, none when the value doesn't change. Input that doesn't
/// parse, or that the tempo map refuses (TempoMap's ranges), changes nothing and the field shows the
/// project's value again. The fields show the value in force at the playhead, as the readouts did;
/// with one tempo and one signature (most projects) that is bar 1's.
///
/// For `ui.perform` (UI-052): the fields are text-field controls (`transport.tempo`,
/// `transport.signature`), which `setText` commits through `commitTempo`/`commitSignature` as typing
/// does (DW-297, T-100); and `transport.tempo.up|down` (±1 BPM at bar 1) and the signature menu's
/// `transport.signature.<numerator>.<denominator>` toggles (bar 1's is on).
extension ProjectWindowModel {
    /// The signatures the toolbar's menu offers.
    static let signaturePresets: [(numerator: Int, denominator: Int)] = [
        (2, 4), (3, 4), (4, 4), (5, 4), (6, 8), (7, 8), (9, 8), (12, 8),
    ]

    /// Bar 1's tempo (the first tempo event, at tick 0).
    var tempoAtBar1: Double { store.project.tempoMap.tempoEvents.first?.bpm ?? 120 }

    /// Bar 1's time signature.
    var signatureAtBar1: (numerator: Int, denominator: Int) {
        let first = store.project.tempoMap.timeSignatures.first
        return (first?.numerator ?? 4, first?.denominator ?? 4)
    }

    /// The tempo field's text: the tempo at the playhead, "120" or "92.5" (up to two decimals).
    var tempoFieldText: String { Self.formatTempo(tempo) }

    static func formatTempo(_ bpm: Double) -> String {
        var text = String(format: "%.2f", bpm)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    /// "128", "128.5", "128,5" or "128 BPM" → 128.5; nil for anything else or outside TempoMap's range.
    static func parseTempo(_ text: String) -> Double? {
        var t = text.trimmingCharacters(in: .whitespaces).lowercased()
        if t.hasSuffix("bpm") { t = String(t.dropLast(3)).trimmingCharacters(in: .whitespaces) }
        t = t.replacingOccurrences(of: ",", with: ".")
        guard !t.isEmpty, t.allSatisfy({ $0.isNumber || $0 == "." }), let bpm = Double(t), bpm.isFinite,
              bpm >= TempoMap.minBPM, bpm <= TempoMap.maxBPM
        else { return nil }
        return bpm
    }

    /// "7/8" (spaces allowed) → (7, 8); nil unless TempoMap accepts it (numerator 1…64, a power-of-two
    /// denominator 1…64).
    static func parseSignature(_ text: String) -> (numerator: Int, denominator: Int)? {
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, let n = Int(parts[0]), let d = Int(parts[1]),
              (1...TempoMap.maxTimeSignatureNumerator).contains(n),
              (1...TempoMap.maxTimeSignatureDenominator).contains(d), d & (d - 1) == 0
        else { return nil }
        return (n, d)
    }

    /// Commits the tempo field. Returns false when `text` isn't a tempo (the field reverts).
    @discardableResult
    func commitTempo(_ text: String) -> Bool {
        guard let bpm = Self.parseTempo(text) else { return false }
        setTempoAtBar1(bpm)
        return true
    }

    /// Commits the signature field. Returns false when `text` isn't a signature (the field reverts).
    @discardableResult
    func commitSignature(_ text: String) -> Bool {
        guard let sig = Self.parseSignature(text) else { return false }
        setSignatureAtBar1(sig.numerator, sig.denominator)
        return true
    }

    /// One undo entry ("Set Tempo"), none when bar 1 already has `bpm`.
    func setTempoAtBar1(_ bpm: Double) {
        let bpm = min(max(bpm, TempoMap.minBPM), TempoMap.maxBPM)
        guard bpm != tempoAtBar1 else { return }
        perform(SetTempoEvent(tick: Tick(0), bpm: bpm))
    }

    /// One undo entry ("Set Time Signature"), none when bar 1 already has it.
    func setSignatureAtBar1(_ numerator: Int, _ denominator: Int) {
        guard (numerator, denominator) != signatureAtBar1 else { return }
        perform(SetTimeSignature(tick: Tick(0), numerator: numerator, denominator: denominator))
    }

    /// UI-052: the tempo nudges and the signature menu's items.
    var tempoSignatureControls: [UIControl] {
        let bpm = tempoAtBar1
        var controls: [UIControl] = [
            // DW-297: the toolbar's fields; the view commits through these, so typing and setText match.
            .textField("transport.tempo", "Tempo at Bar 1 (BPM)", text: tempoFieldText) { [weak self] in
                self?.commitTempo($0) ?? false
            },
            .textField("transport.signature", "Time Signature at Bar 1", text: signature) { [weak self] in
                self?.commitSignature($0) ?? false
            },
            .button("transport.tempo.up", "Tempo +1 BPM", enabled: bpm < TempoMap.maxBPM) { [weak self] in
                self?.setTempoAtBar1(bpm + 1)
            },
            .button("transport.tempo.down", "Tempo −1 BPM", enabled: bpm > TempoMap.minBPM) { [weak self] in
                self?.setTempoAtBar1(bpm - 1)
            },
        ]
        let current = signatureAtBar1
        controls += Self.signaturePresets.map { preset in
            .toggle("transport.signature.\(preset.numerator).\(preset.denominator)", "\(preset.numerator)/\(preset.denominator)",
                    isOn: preset == current) { [weak self] in
                self?.setSignatureAtBar1(preset.numerator, preset.denominator)
            }
        }
        return controls
    }
}
