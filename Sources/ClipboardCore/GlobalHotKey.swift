import Carbon.HIToolbox
import Foundation

/// A system-wide keyboard shortcut via Carbon's RegisterEventHotKey.
/// Unlike event taps, this needs no Accessibility permission.
@MainActor
public final class GlobalHotKey {
    public struct Modifiers: OptionSet, Sendable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }
        public static let command = Modifiers(rawValue: UInt32(cmdKey))
        public static let option = Modifiers(rawValue: UInt32(optionKey))
        public static let control = Modifiers(rawValue: UInt32(controlKey))
        public static let shift = Modifiers(rawValue: UInt32(shiftKey))
    }

    public static let keyV = UInt32(kVK_ANSI_V)

    private static var handlers: [UInt32: () -> Void] = [:]
    private static var nextID: UInt32 = 1
    private static var eventHandler: EventHandlerRef?

    private var hotKeyRef: EventHotKeyRef?
    private let id: UInt32

    /// Registers the shortcut. Throws if another app already owns it.
    public init(keyCode: UInt32, modifiers: Modifiers, action: @escaping () -> Void) throws {
        Self.installDispatcherIfNeeded()
        id = Self.nextID
        Self.nextID += 1
        let hotKeyID = EventHotKeyID(signature: OSType(0x4D4F4E49) /* 'MONI' */, id: id)
        let status = RegisterEventHotKey(keyCode, modifiers.rawValue, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        guard status == noErr else { throw HotKeyError.registrationFailed(status) }
        Self.handlers[id] = action
    }

    public func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        Self.handlers[id] = nil
    }

    private static func installDispatcherIfNeeded() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr else { return status }
            // Carbon delivers hot key events on the main thread.
            MainActor.assumeIsolated { GlobalHotKey.handlers[hotKeyID.id]?() }
            return noErr
        }, 1, &spec, nil, &eventHandler)
    }
}

public enum HotKeyError: Error, LocalizedError {
    case registrationFailed(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .registrationFailed(let status):
            "The shortcut is already used by another app (error \(status))."
        }
    }
}
