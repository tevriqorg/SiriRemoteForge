// Pure input routing state extracted from the HID adapter. No AppKit or IOKit dependencies.
import Foundation

enum NativeDictationPressRoute: Equatable {
    case native
    case busyConsumed
    case external
    case ordinary
}

enum VoiceModeChordRoute: Equatable {
    case passthrough
    case consume
    case cycle
}

enum SharedButtonTransition: Equatable {
    case duplicate
    case sourceOnly
    case globalDown
    case globalUp
}

/// Collapses mirrored HID interfaces within one physical remote while allowing several remotes to
/// contribute to the same logical button. If A hands a held button to B, A's later release is only
/// a source transition; the app-level button stays down until B releases it.
struct MultiRemoteButtonState<Source: Hashable, Button: Hashable> {
    private var heldBySource: [Source: Set<Button>] = [:]

    var heldButtons: Set<Button> {
        heldBySource.values.reduce(into: Set<Button>()) { $0.formUnion($1) }
    }

    func isPressed(_ button: Button) -> Bool {
        heldBySource.values.contains { $0.contains(button) }
    }

    mutating func update(source: Source, button: Button,
                         pressed: Bool) -> SharedButtonTransition {
        let sourceWasPressed = heldBySource[source]?.contains(button) == true
        guard sourceWasPressed != pressed else { return .duplicate }
        let wasGloballyPressed = isPressed(button)
        if pressed {
            heldBySource[source, default: []].insert(button)
        } else {
            heldBySource[source]?.remove(button)
            if heldBySource[source]?.isEmpty == true { heldBySource[source] = nil }
        }
        let isGloballyPressed = isPressed(button)
        guard wasGloballyPressed != isGloballyPressed else { return .sourceOnly }
        return isGloballyPressed ? .globalDown : .globalUp
    }

    /// Removes a physical remote and returns only buttons that no remaining remote still holds.
    mutating func removeSource(_ source: Source) -> Set<Button> {
        guard let removed = heldBySource.removeValue(forKey: source) else { return [] }
        return Set(removed.filter { !isPressed($0) })
    }

    mutating func removeAll() { heldBySource.removeAll() }
}

/// Pure two-button chord state. It owns both releases after Mute+Side is recognized, which is what
/// prevents either the configured Mute action or a Voice opener from leaking out of the gesture.
/// No timer is involved: ordinary side-button latency is completely unchanged.
struct VoiceModeChordState {
    private(set) var ownsMute = false
    private(set) var ownsSide = false

    mutating func route(buttonName: String, pressed: Bool,
                        muteIsDown: Bool, enabled: Bool) -> VoiceModeChordRoute {
        if buttonName == "siri" {
            if !pressed, ownsSide {
                ownsSide = false
                return .consume
            }
            if pressed, enabled, muteIsDown {
                ownsMute = true
                ownsSide = true
                return .cycle
            }
        }
        if buttonName == "mute", !pressed, ownsMute {
            ownsMute = false
            return .consume
        }
        return .passthrough
    }

    mutating func reset() {
        ownsMute = false
        ownsSide = false
    }
}
