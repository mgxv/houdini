// Global hotkey via Carbon's RegisterEventHotKey. Consumes the chord
// (vs. NSEvent global monitor, which doesn't) and works without AX
// trust — useful on a fresh install before the user grants it.

import Carbon.HIToolbox
import Cocoa

@MainActor
final class HotkeyWatcher {
    struct Chord {
        let keyCode: UInt32
        let modifiers: UInt32
    }

    /// Cmd+Ctrl+Option+H — three modifiers keeps it clear of app
    /// bindings (Cmd+H is "hide app", Cmd+Option+H is "hide others").
    static let defaultChord = Chord(
        keyCode: UInt32(kVK_ANSI_H),
        modifiers: UInt32(controlKey | cmdKey | optionKey),
    )

    private let onPress: @MainActor () -> Void
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    private static let signature: OSType = 0x686F_7564 // 'houd'
    private static let id: UInt32 = 1

    init(onPress: @escaping @MainActor () -> Void) {
        self.onPress = onPress
    }

    /// Returns false if the chord is already taken; non-fatal — the
    /// daemon's automatic control still works without it.
    func start(chord: Chord = defaultChord) -> Bool {
        guard handlerRef == nil else { return true }

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed),
        )
        // Inline so the closure inherits @MainActor isolation that
        // Swift 6's sending-data-race check needs on `refcon`.
        let callback: EventHandlerUPP = { _, event, refcon -> OSStatus in
            guard let event, let refcon else { return noErr }
            var hkID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hkID,
            )
            guard status == noErr, hkID.signature == HotkeyWatcher.signature else {
                return status
            }
            MainActor.assumeIsolated {
                let me = Unmanaged<HotkeyWatcher>.fromOpaque(refcon).takeUnretainedValue()
                me.onPress()
            }
            return noErr
        }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let installErr = InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            1, &spec,
            refcon, &handlerRef,
        )
        guard installErr == noErr else {
            warn("hotkey: InstallEventHandler failed (status \(installErr))")
            return false
        }

        let hkID = EventHotKeyID(signature: Self.signature, id: Self.id)
        let regErr = RegisterEventHotKey(
            chord.keyCode, chord.modifiers, hkID,
            GetApplicationEventTarget(), 0, &hotKeyRef,
        )
        guard regErr == noErr else {
            warn("hotkey: RegisterEventHotKey failed (status \(regErr))")
            if let h = handlerRef {
                RemoveEventHandler(h)
                handlerRef = nil
            }
            return false
        }
        return true
    }

    func stop() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        if let h = handlerRef {
            RemoveEventHandler(h)
            handlerRef = nil
        }
    }
}
