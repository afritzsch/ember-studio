@testable import DAWModel
import Foundation
import Testing

// T-062 (PLUG-011/016): a `.vst3` device slot's configJSON, the shape plugins/VST3PluginConfig.h
// parses. Sorted keys, so equal slots give equal strings (MODEL-021 compares graphs).

@Suite("VST3 device slots")
struct VST3SlotModelTests {
    @Test("PLUG-011: a .vst3 slot emits {identifier, state} configJSON, keys sorted, state base64")
    func configJSON() {
        var slot = DeviceSlot(id: 7, kind: .vst3(VST3Descriptor(identifier: "/x.vst3#84E8DE5F92554F5396FAE4133C935A18", name: "AGain")))
        #expect(slot.configJSON == #"{"identifier":"/x.vst3#84E8DE5F92554F5396FAE4133C935A18"}"#)
        slot.pluginState = Data([0x45, 0x56])
        #expect(slot.configJSON == #"{"identifier":"/x.vst3#84E8DE5F92554F5396FAE4133C935A18","state":"RVY="}"#)
    }
}
