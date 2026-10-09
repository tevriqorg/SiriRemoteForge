import Foundation

/// Immutable command-line boundary for visual QC, snapshots and diagnostic launch modes.
/// Production startup no longer reaches directly into global CommandLine state throughout the
/// composition root; execution stays beside the AppKit surfaces it drives.
struct DeveloperCommandRouter: Sendable {
    let arguments: [String]

    init(arguments: [String]) {
        self.arguments = arguments
    }

    func has(_ flag: String) -> Bool {
        arguments.contains(flag)
    }

    func value(after flag: String) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
            return nil
        }
        return arguments[index + 1]
    }

    var isDeveloperLaunch: Bool {
        arguments.dropFirst().contains { argument in
            argument.hasPrefix("--test-")
                || argument.hasPrefix("--snapshot-")
                || argument == "--preview-hold-animations"
                || argument == "--dump-gatt"
        }
    }
}
