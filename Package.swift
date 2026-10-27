// swift-tools-version: 6.0
// Root manifest for macDAW (01-build-layout). The Xcode app in App/ links the products declared here.

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
    .unsafeFlags(["-Wall", "-Wextra", "-Werror", "-isystem", vst3Include]),
    .unsafeFlags(["-O3"], .when(configuration: .release)),
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
            cxxSettings: engineCxxSettings
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
        .executableTarget(
            name: "PluginScanner",
            dependencies: ["DAWEngine"],
            swiftSettings: cxxInterop
        ),

        // MARK: Tests

        .testTarget(
            name: "DAWEngineTests",
            dependencies: ["DAWEngine"],
            swiftSettings: cxxInterop
        ),
        .testTarget(
            name: "DAWModelTests",
            dependencies: ["DAWModel"],
            swiftSettings: cxxInterop
        ),
        .testTarget(
            name: "DAWControlTests",
            dependencies: ["DAWControl"],
            swiftSettings: cxxInterop
        ),
        .testTarget(
            name: "GoldenTests",
            dependencies: ["DAWModel", "DAWControl"],
            swiftSettings: cxxInterop
        ),
    ],
    cxxLanguageStandard: .cxx20
)
