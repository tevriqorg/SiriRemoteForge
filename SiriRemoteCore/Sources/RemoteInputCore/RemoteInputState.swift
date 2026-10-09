import Foundation

public enum NativeDictationPressRoute: Equatable {
    case native
    case busyConsumed
    case external
    case ordinary
}

public enum VoiceModeChordRoute: Equatable {
    case passthrough
    case consume
    case cycle
}

public enum SharedButtonTransition: Equatable {
    case duplicate
    case sourceOnly
    case globalDown
    case globalUp
}

/// Pure ownership state for logical buttons shared by several HID interfaces/remotes.
public struct MultiRemoteButtonState<Source: Hashable, Button: Hashable> {
    private var heldBySource: [Source: Set<Button>] = [:]

    public init() {}

    public var heldButtons: Set<Button> {
        heldBySource.values.reduce(into: Set<Button>()) { $0.formUnion($1) }
    }

    public func isPressed(_ button: Button) -> Bool {
        heldBySource.values.contains { $0.contains(button) }
    }

    public mutating func update(source: Source, button: Button,
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

    public mutating func removeSource(_ source: Source) -> Set<Button> {
        guard let removed = heldBySource.removeValue(forKey: source) else { return [] }
        return Set(removed.filter { !isPressed($0) })
    }

    public mutating func removeAll() { heldBySource.removeAll() }
}

/// Pure two-button chord state. Once Mute+Side is recognized it owns both releases.
public struct VoiceModeChordState {
    public private(set) var ownsMute = false
    public private(set) var ownsSide = false

    public init() {}

    public mutating func route(buttonName: String, pressed: Bool,
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

    public mutating func reset() {
        ownsMute = false
        ownsSide = false
    }
}

public enum RemoteHoldSelection: Equatable {
    case tap
    case stage(index: Int)
    case cancel
}

public struct RemoteHoldStage: Equatable {
    public let key: String
    public let delay: TimeInterval
    public let ordinal: Int

    public init(key: String, delay: TimeInterval, ordinal: Int) {
        self.key = key
        self.delay = delay
        self.ordinal = ordinal
    }
}

/// Immutable snapshot captured on physical press. Config reloads cannot move its thresholds.
public struct RemoteHoldGesture: Equatable {
    public let startedAt: TimeInterval
    public let stages: [RemoteHoldStage]
    public let cancelAt: TimeInterval?

    public init(startedAt: TimeInterval, stages: [RemoteHoldStage], cancelAt: TimeInterval?) {
        self.startedAt = startedAt
        self.stages = stages
        self.cancelAt = cancelAt
    }

    public func selection(at now: TimeInterval) -> RemoteHoldSelection {
        let elapsed = max(0, now - startedAt)
        if let cancelAt, elapsed >= cancelAt { return .cancel }
        let reached = stages.reduce(into: 0) { count, stage in
            if elapsed >= stage.delay { count += 1 }
        }
        return reached > 0 ? .stage(index: reached - 1) : .tap
    }
}

/// Pure storage/ownership for press-scoped hold gestures. Timers and action dispatch stay in App.
public struct RemoteHoldState<Button: Hashable> {
    private var values: [Button: RemoteHoldGesture] = [:]

    public init() {}

    public subscript(button: Button) -> RemoteHoldGesture? {
        get { values[button] }
        set { values[button] = newValue }
    }

    @discardableResult
    public mutating func removeValue(forKey button: Button) -> RemoteHoldGesture? {
        values.removeValue(forKey: button)
    }

    public mutating func removeAll() { values.removeAll() }
}

/// Count-only multi-tap reducer. Scheduling and action dispatch remain in App.
public struct RemoteTapRunState<Button: Hashable> {
    private var counts: [Button: Int] = [:]

    public init() {}

    public subscript(button: Button) -> Int? {
        get { counts[button] }
        set { counts[button] = newValue }
    }

    @discardableResult
    public mutating func advance(_ button: Button) -> Int {
        let next = (counts[button] ?? 0) + 1
        counts[button] = next
        return next
    }

    @discardableResult
    public mutating func removeValue(forKey button: Button) -> Int? {
        counts.removeValue(forKey: button)
    }

    public mutating func removeAll() { counts.removeAll() }
}

public enum RemoteLayerGesture: Equatable {
    case direct(String)
    case cycle(String?)

    public var target: String? {
        switch self {
        case .direct(let name): return name
        case .cycle(let name): return name
        }
    }

    public var displayID: String { target ?? "BASE" }
}

/// Pure layer-gesture ownership. Controller push/pop and HUD callbacks stay in App.
public struct RemoteLayerState<Button: Hashable> {
    public var button: Button?
    public var gesture: RemoteLayerGesture?
    public var used = false
    public var stickyLayer: String?
    public var stickyButton: Button?

    public init() {}

    public mutating func engage(button: Button, gesture: RemoteLayerGesture) {
        self.button = button
        self.gesture = gesture
        used = false
    }

    public mutating func markUsed() {
        if button != nil { used = true }
    }

    public mutating func resetMomentary() {
        button = nil
        gesture = nil
        used = false
    }
}

/// Pure record of which presses crossed the held-repeat onset. Timer/key side effects stay in App.
public struct RemoteRepeatEngagementState<Button: Hashable> {
    private var engaged: Set<Button> = []

    public init() {}

    @discardableResult
    public mutating func insert(_ button: Button) -> (inserted: Bool, memberAfterInsert: Button) {
        engaged.insert(button)
    }

    @discardableResult
    public mutating func remove(_ button: Button) -> Button? {
        engaged.remove(button)
    }

    public func contains(_ button: Button) -> Bool { engaged.contains(button) }
    public mutating func removeAll() { engaged.removeAll() }
}
