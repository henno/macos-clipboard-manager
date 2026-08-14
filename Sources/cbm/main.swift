import AppKit

// Tests run in-process and exit before any UI exists; see SelfTest.swift for
// why they live in the app binary rather than an XCTest bundle.
if CommandLine.arguments.contains("--self-test") {
    exit(SelfTest.run())
}

// Diagnostics, printed without starting the app. Run it on the *installed*
// binary -- permissions are tied to the bundle, so asking the one in .build
// would answer a different question.
if CommandLine.arguments.contains("--status") {
    print("bundle          \(Bundle.main.bundlePath)")
    print("signature       \(CodeSignature.isAdHoc ? "ad-hoc (permissions break on every rebuild)" : "certificate (stable)")")
    print("accessibility   \(Paster.isTrusted ? "granted" : "not granted")")
    print("built from      \(CodeSignature.sourceRoot ?? "unknown")")
    print("data            \(Paths.root.path)")
    exit(0)
}

// LSUIElement is set in Info.plist, but set the policy explicitly too so that a
// bare binary run out of .build behaves the same as the installed bundle.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let delegate = AppDelegate()
app.delegate = delegate
app.run()
