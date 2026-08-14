import Foundation
import Security

/// Reports how this build is actually signed, so the UI can describe reality
/// instead of repeating an assumption that was baked in when the text was
/// written.
enum CodeSignature {
    /// `kSecCodeSignatureAdhoc` from <Security/SecCode.h>, which is not exposed
    /// to Swift. It is the same bit `codesign -dv` prints as `flags=0x...2(adhoc)`.
    private static let adhocFlag: UInt32 = 0x0000_0002

    /// An ad-hoc signature is just a hash of the binary, so it changes on every
    /// build and every permission granted against it is quietly invalidated.
    static let isAdHoc: Bool = {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &staticCode)
                == errSecSuccess,
              let staticCode
        else { return true }  // unsignable or unreadable: treat as the unstable case

        var info: CFDictionary?
        guard SecCodeCopySigningInformation(
                staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any]
        else { return true }

        guard let flags = dict[kSecCodeInfoFlags as String] as? UInt32 else { return true }
        return flags & adhocFlag != 0
    }()

    /// The directory the app was built from, stamped into Info.plist by the
    /// Makefile. Lets the UI name the exact command rather than gesturing at one.
    static var sourceRoot: String? {
        Bundle.main.object(forInfoDictionaryKey: "CBMSourceRoot") as? String
    }

    /// The full shell command that gives this build a stable signature.
    static var stableSignatureCommand: String? {
        guard let sourceRoot else { return nil }
        return "cd \(sourceRoot) && make cert"
    }
}
