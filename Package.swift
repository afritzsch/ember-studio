// swift-tools-version: 6.0
// Root manifest for Ember Studio (01-build-layout). The Xcode app in App/ links the products declared here.

import PackageDescription

// BUILD-003: the VST3 SDK is a pinned submodule. Only the hosting side is compiled.
let vst3Include: String = Context.packageDirectory + "/Vendor/vst3sdk"

// The VST3 SDK selects its debug machinery with DEVELOPMENT / RELEASE. Every target that
// includes its headers must agree, so the defines are shared.
let vst3Defines: [CXXSetting] = [
    .define("DEVELOPMENT", to: "1", .when(configuration: .debug)),
    .define("RELEASE", to: "1", .when(configuration: .release)),
]

// Hosting sources only (BUILD-003), mirroring the SDK's sdk_common + sdk_hosting CMake targets.
let vst3Sources: [String] = [
    "vst3sdk/pluginterfaces/base",
    "vst3sdk/base/source",
    "vst3sdk/base/thread/source",
    "vst3sdk/public.sdk/source/common/commoniids.cpp",
    "vst3sdk/public.sdk/source/common/commonstringconvert.cpp",
    "vst3sdk/public.sdk/source/common/memorystream.cpp",
    "vst3sdk/public.sdk/source/common/readfile.cpp",
    "vst3sdk/public.sdk/source/common/threadchecker_mac.mm",
    "vst3sdk/public.sdk/source/vst/hosting/connectionproxy.cpp",
    "vst3sdk/public.sdk/source/vst/hosting/eventlist.cpp",
    "vst3sdk/public.sdk/source/vst/hosting/hostclasses.cpp",
    "vst3sdk/public.sdk/source/vst/hosting/module.cpp",
    "vst3sdk/public.sdk/source/vst/hosting/module_mac.mm",
    "vst3sdk/public.sdk/source/vst/hosting/parameterchanges.cpp",
    "vst3sdk/public.sdk/source/vst/hosting/pluginterfacesupport.cpp",
    "vst3sdk/public.sdk/source/vst/hosting/plugprovider.cpp",
    "vst3sdk/public.sdk/source/vst/hosting/processdata.cpp",
    "vst3sdk/public.sdk/source/vst/utility/stringconvert.cpp",
    "vst3sdk/public.sdk/source/vst/vstinitiids.cpp",
    "vst3sdk/public.sdk/source/vst/vstpresetfile.cpp",
]

// SwiftPM scans the whole target path for resources, so everything outside the hosting
// sources is excluded explicitly (samples, wrappers, docs, VSTGUI…).
let vst3Excludes: [String] = [
    "vst3sdk/CMakeLists.txt",
    "vst3sdk/LICENSE.txt",
    "vst3sdk/README.md",
    "vst3sdk/VST3_Usage_Guidelines.pdf",
    "vst3sdk/index.html",
    "vst3sdk/cmake",
    "vst3sdk/doc",
    "vst3sdk/tutorials",
    "vst3sdk/vstgui4",
    "vst3sdk/base/LICENSE.txt",
    "vst3sdk/base/README.md",
    "vst3sdk/pluginterfaces/LICENSE.txt",
    "vst3sdk/pluginterfaces/README.md",
    "vst3sdk/public.sdk/LICENSE.txt",
    "vst3sdk/public.sdk/README.md",
    "vst3sdk/public.sdk/samples",
    "vst3sdk/public.sdk/source/main",
    "vst3sdk/public.sdk/source/vst/aaxwrapper",
    "vst3sdk/public.sdk/source/vst/auv3wrapper",
    "vst3sdk/public.sdk/source/vst/auwrapper",
    "vst3sdk/public.sdk/source/vst/basewrapper",
    "vst3sdk/public.sdk/source/vst/interappaudio",
    "vst3sdk/public.sdk/source/vst/moduleinfo",
    "vst3sdk/public.sdk/source/vst/testsuite",
    "vst3sdk/public.sdk/source/vst/hosting/test",
]

let vst3CxxSettings: [CXXSetting] = vst3Defines + [
    .headerSearchPath("vst3sdk"),
    // Third-party code: its warnings must not fail or clutter our build (CONV §5.1).
    // module_mac.mm requires ARC.
    .unsafeFlags(["-w", "-fobjc-arc"]),
]

let engineCxxSettings: [CXXSetting] = vst3Defines + [
    // BUILD-005: the RT trap exists only in Debug.
    .define("DAW_RT_TRAP", to: "1", .when(configuration: .debug)),
    .define("DAW_RT_TRAP", to: "0", .when(configuration: .release)),
    // CONV §1. The SDK is a system include so its headers don't trip -Werror.
    // CONV-RT-06: -Wfunction-effects makes clang check DAW_RT ([[clang::nonblocking]]) bodies.
    .unsafeFlags(["-Wall", "-Wextra", "-Werror", "-Wfunction-effects", "-isystem", vst3Include]),
    .unsafeFlags(["-O3"], .when(configuration: .release)),
]

// DW-007: engine code includes engine headers rooted at Sources/DAWEngine ("core/RtTrap.h",
// "time/TempoMap.h"), from any folder. Test code that reaches engine internals needs the same root.
let engineSourceRoot: String = Context.packageDirectory + "/Sources/DAWEngine"

// 10-plugin-hosting: the scanner's VST3 probe is C++ that includes the SDK, held to CONV §1 like
// the engine. It has no RT code, so it carries no RT trap defines.
let scannerCxxSettings: [CXXSetting] = vst3Defines + [
    .unsafeFlags(["-Wall", "-Wextra", "-Werror", "-isystem", vst3Include]),
]

// BUILD-002: Swift targets that see DAWEngine (directly or through DAWModel) need C++ interop.
let cxxInterop: [SwiftSetting] = [
    .interoperabilityMode(.Cxx),
]

let package = Package(
    name: "macDAW",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "DAWEngine", targets: ["DAWEngine"]),
        .library(name: "DAWModel", targets: ["DAWModel"]),
        .library(name: "DAWControl", targets: ["DAWControl"]),
        .executable(name: "dawctl", targets: ["dawctl"]),
        .executable(name: "dawmcp", targets: ["dawmcp"]),
        .executable(name: "PluginScanner", targets: ["PluginScanner"]),
    ],
    targets: [
        // MARK: Vendor

        .target(
            name: "VST3SDK",
            path: "Vendor",
            exclude: vst3Excludes,
            sources: vst3Sources,
            // Swift never imports the SDK; this header root only exists because SwiftPM needs one.
            publicHeadersPath: "VST3SDKSupport/include",
            cxxSettings: vst3CxxSettings,
            linkerSettings: [
                .linkedFramework("CoreFoundation"),
                .linkedFramework("Foundation"),
            ]
        ),

        // MARK: Engine (C++20)

        .target(
            name: "DAWEngine",
            dependencies: ["VST3SDK"],
            cxxSettings: engineCxxSettings + [.headerSearchPath(".")],
            linkerSettings: [
                // IO-031: ExtAudioFile decoding and AudioConverter resampling (io/).
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreFoundation"),
                // IO-001..005: HAL device properties and the AUHAL output unit (io/CoreAudioDriver).
                .linkedFramework("CoreAudio"),
            ]
        ),

        // MARK: Swift

        .target(
            name: "DAWModel",
            dependencies: ["DAWEngine"],
            swiftSettings: cxxInterop
        ),
        .target(
            name: "DAWControl",
            dependencies: ["DAWModel"],
            swiftSettings: cxxInterop
        ),
        .executableTarget(
            name: "dawctl",
            dependencies: ["DAWModel", "DAWControl"],
            swiftSettings: cxxInterop
        ),
        .executableTarget(
            name: "dawmcp",
            dependencies: ["DAWModel", "DAWControl"],
            swiftSettings: cxxInterop
        ),

        // MARK: Plugin scanning (10-plugin-hosting, PLUG-001..004)

        // Discovery, the plugins.json cache and the scanner launcher. Plain Swift (no engine), so
        // DAWModel/DAWControl or the app can use it without loading any plugin code in-process.
        .target(
            name: "PluginCatalog",
            path: "Sources/PluginScanner/Catalog"
        ),
        // VST3 module probe (PLUG-003). C++ because it talks to the SDK hosting classes.
        .target(
            name: "PluginScannerVST3",
            dependencies: ["VST3SDK"],
            path: "Sources/PluginScanner/VST3Probe",
            cxxSettings: scannerCxxSettings
        ),
        // PLUG-001: the out-of-process helper. Plugin code is only ever loaded here.
        .executableTarget(
            name: "PluginScanner",
            dependencies: ["PluginCatalog", "PluginScannerVST3"],
            path: "Sources/PluginScanner/Tool",
            swiftSettings: cxxInterop
        ),

        // MARK: Tests

        // C++ test support for engine tests (specs/14-testing.md, "C++ unit tests"). Its module map
        // (include/module.modulemap) is the test-only view of engine headers the DAWEngine module
        // map hides; its sources hold C++ test code (checks, deliberate RT violations) so none of
        // it ships in DAWEngine. Built with the engine's flags, so DAW_RT bodies are checked and
        // DAW_RT_TRAP matches. Only test targets may depend on it.
        .target(
            name: "DAWEngineTestSupport",
            dependencies: ["DAWEngine"],
            path: "Tests/DAWEngineTestSupport",
            cxxSettings: engineCxxSettings + [.unsafeFlags(["-I", engineSourceRoot])],
            // No Swift sources. Listed for scripts/test.sh's BUILD-002 check, which expects every
            // target that reaches DAWEngine to declare C++ interop.
            swiftSettings: cxxInterop
        ),
        .testTarget(
            name: "DAWEngineTests",
            dependencies: ["DAWEngine", "DAWEngineTestSupport"],
            swiftSettings: cxxInterop + [
                // The clang importer parses engine headers (via DAWEngineTestSupport's module map)
                // with these flags, not the engine's, so it needs the same include root and the
                // same DAW_RT_TRAP (BUILD-005); otherwise it sees the no-op Release RtTrap.
                .unsafeFlags(["-Xcc", "-I" + engineSourceRoot]),
                .unsafeFlags(["-Xcc", "-DDAW_RT_TRAP=1"], .when(configuration: .debug)),
                .unsafeFlags(["-Xcc", "-DDAW_RT_TRAP=0"], .when(configuration: .release)),
            ]
        ),
        .testTarget(
            name: "DAWModelTests",
            // ProjectSaveCrashHelper is listed so `swift test` builds the binary the tests kill (MODEL-041).
            dependencies: ["DAWModel", "ProjectSaveCrashHelper"],
            swiftSettings: cxxInterop
        ),
        // MODEL-041/044/045: a process that saves or autosaves until the persistence tests kill it.
        .executableTarget(
            name: "ProjectSaveCrashHelper",
            dependencies: ["DAWModel"],
            path: "Tests/ProjectSaveCrashHelper",
            swiftSettings: cxxInterop
        ),
        .testTarget(
            name: "DAWControlTests",
            // dawctl is listed so `swift test` builds the binary the CLI tests launch (CTL-010/012).
            dependencies: ["DAWControl", "dawctl"],
            swiftSettings: cxxInterop
        ),
        .testTarget(
            name: "PluginScannerTests",
            // PluginScanner is listed so `swift test` builds the binary the tests launch.
            dependencies: ["PluginCatalog", "PluginScanner"],
            // Fixtures are C++ sources the tests compile into fake plugin bundles.
            exclude: ["Fixtures"]
        ),
        .testTarget(
            name: "GoldenTests",
            dependencies: ["DAWModel", "DAWControl"],
            swiftSettings: cxxInterop
        ),
    ],
    cxxLanguageStandard: .cxx20
)
