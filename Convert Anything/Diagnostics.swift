import Foundation
import OSLog

/// What a bug report needs to know about this copy of the app and this Mac, and the one place
/// loggers get their subsystem, so a report can find every entry the app wrote.
nonisolated enum Diagnostics {
    /// The release bundle identifier. Test builds add a suffix (".e2e"), so readers match on this prefix.
    static let subsystem = "io.github.jaybirdzhang.ConvertAnything"

    /// A logger under the app's subsystem, e.g. `Diagnostics.logger("transcription")`.
    static func logger(_ category: String) -> Logger {
        Logger(subsystem: Bundle.main.bundleIdentifier ?? subsystem, category: category)
    }

    /// "1.5 (6)"
    static var appVersion: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        return (info["CFBundleVersion"] as? String).map { "\(version) (\($0))" } ?? version
    }

    /// "14.6.1 (23G93)"
    static var macOSVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let number = "\(v.majorVersion).\(v.minorVersion)" + (v.patchVersion > 0 ? ".\(v.patchVersion)" : "")
        return number + (sysctl("kern.osversion").map { " (\($0))" } ?? "")
    }

    /// "Mac16,12": the model identifier, which says the chip without saying anything about the person.
    static var macModel: String {
        sysctl("hw.model") ?? "?"
    }

    private static func sysctl(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else { return nil }
        return String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }
}
