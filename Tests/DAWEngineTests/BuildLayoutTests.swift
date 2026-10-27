import DAWEngine
import Testing

// BUILD-002: this file compiling is the check. A Swift target imports the C++ DAWEngine module
// through the module map in Sources/DAWEngine/include, with C++ interop enabled.
@Test("BUILD-002: Swift imports DAWEngine with C++ interop")
func swiftImportsEngine() {}
