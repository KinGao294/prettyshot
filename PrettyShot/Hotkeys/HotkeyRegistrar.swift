import Carbon.HIToolbox
import Foundation

enum HotkeyCarbon {
    /// 'PSht'
    static let signature: OSType = 0x5053_6874
    static let escapeID: UInt32 = 0xE5C
    /// External actions start here so they never overlap built-in ids 1...6.
    static let externalBase: UInt32 = 1000
}

/// Carbon registration, split out so tests can fake `eventHotKeyExistsErr`.
@MainActor
protocol HotkeyRegistrar: AnyObject {
    func register(_ shortcut: Shortcut, carbonID: UInt32) -> Result<EventHotKeyRef, OSStatus>
    func unregister(_ ref: EventHotKeyRef)
}

@MainActor
final class CarbonHotkeyRegistrar: HotkeyRegistrar {
    func register(_ shortcut: Shortcut, carbonID: UInt32) -> Result<EventHotKeyRef, OSStatus> {
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: HotkeyCarbon.signature, id: carbonID)
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.modifiers,
            id,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if status == noErr, let ref {
            return .success(ref)
        }
        return .failure(status == noErr ? OSStatus(eventInternalErr) : status)
    }

    func unregister(_ ref: EventHotKeyRef) {
        UnregisterEventHotKey(ref)
    }
}
