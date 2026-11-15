import Carbon.HIToolbox
import Foundation

/// A system-wide shortcut via Carbon `RegisterEventHotKey` (no Accessibility permission needed).
/// `init?` returns nil when the system refuses (another app owns the combination).
final class GlobalHotKey {
    private static let signature: OSType = 0x5154_4B59 // 'QTKY'
    private static var nextId: UInt32 = 1
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var eventHandlerInstalled = false

    private var hotKeyRef: EventHotKeyRef?
    private let id: UInt32

    init?(spec: HotKeySpec, handler: @escaping () -> Void) {
        Self.installEventHandlerIfNeeded()
        id = Self.nextId
        Self.nextId += 1
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            spec.keyCode,
            spec.modifiers,
            EventHotKeyID(signature: Self.signature, id: id),
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else {
            trayLog("Quick Ask hotkey registration failed (OSStatus \(status)); another app may own it")
            return nil
        }
        hotKeyRef = ref
        Self.handlers[id] = handler
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        Self.handlers[id] = nil
    }

    private static func installEventHandlerIfNeeded() {
        guard !eventHandlerInstalled else { return }
        eventHandlerInstalled = true
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard status == noErr, hotKeyID.signature == GlobalHotKey.signature else {
                return OSStatus(eventNotHandledErr)
            }
            GlobalHotKey.handlers[hotKeyID.id]?()
            return noErr
        }, 1, &eventType, nil, nil)
    }
}

/// The `QuickAskHotkey` user default: missing -> default combination, "" -> disabled, unparsable -> disabled (logged).
enum QuickAskHotkeySetting {
    static let defaultsKey = "QuickAskHotkey"

    /// `string` is what the user configured (nil = disabled); `spec` is nil when disabled or unparsable.
    static func resolve(defaults: UserDefaults = .standard) -> (string: String?, spec: HotKeySpec?) {
        let configured = defaults.object(forKey: defaultsKey) as? String ?? HotKeySpec.defaultString
        let trimmed = configured.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return (nil, nil) }
        guard let spec = HotKeySpec.parse(trimmed) else {
            trayLog("Quick Ask hotkey \"\(trimmed)\" is not valid; hotkey disabled")
            return (nil, nil)
        }
        return (trimmed, spec)
    }
}
