// Global hotkey via Carbon's RegisterEventHotKey. Consumes the chord
// (vs. NSEvent global monitor, which doesn't) and works without AX
// trust — useful on a fresh install before the user grants it.
//
// Dispatch needs NSApp.run (see runForeground); registers on the
// event dispatcher target so events bypass the application queue.

import Carbon.HIToolbox
import Cocoa

// MARK: - HotkeyWatcher

@MainActor
final class HotkeyWatcher {
    struct Chord {
        let keyCode: UInt32
        let modifiers: UInt32
    }

    /// ⌃⌥⌘M — three modifiers keeps it clear of app bindings
    /// (⌘M is "minimize", ⌥⌘M is "minimize all").
    static let defaultChord = Chord(
        keyCode: UInt32(kVK_ANSI_M),
        modifiers: UInt32(controlKey | optionKey | cmdKey),
    )

    private static let signature: OSType = 0x686F_7564 // 'houd'
    private static let id: UInt32 = 1

    private let onPress: @MainActor () -> Void
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    init(onPress: @escaping @MainActor () -> Void) {
        self.onPress = onPress
    }

    // MARK: Lifecycle

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
            GetEventDispatcherTarget(),
            callback,
            1, &spec,
            refcon, &handlerRef,
        )
        guard installErr == noErr else {
            warn("hotkey: InstallEventHandler failed — \(Self.describe(installErr))")
            return false
        }

        let hkID = EventHotKeyID(signature: Self.signature, id: Self.id)
        let regErr = RegisterEventHotKey(
            chord.keyCode, chord.modifiers, hkID,
            GetEventDispatcherTarget(), 0, &hotKeyRef,
        )
        guard regErr == noErr else {
            warn("hotkey: RegisterEventHotKey failed — \(Self.describe(regErr))")
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

    // MARK: Helpers

    private static func describe(_ status: OSStatus) -> String {
        switch Int(status) {
        case eventHotKeyExistsErr: "chord already registered by another app (status \(status))"
        case eventHotKeyInvalidErr: "invalid chord (status \(status))"
        case paramErr: "invalid parameter (status \(status))"
        default: "status \(status)"
        }
    }
}

// MARK: - HotkeyState (on-disk handoff for `houdini status`)

/// Persists the hotkey-registration result to a small file under
/// Application Support so the `status` subcommand (running in a
/// separate process) can report it. Cleared on graceful daemon
/// shutdown so a stale value doesn't outlive the daemon.
enum HotkeyState {
    private static func url() -> URL? {
        guard let appSupport = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false,
        ) else { return nil }
        return appSupport
            .appendingPathComponent(Log.subsystem, isDirectory: true)
            .appendingPathComponent("hotkey.state")
    }

    static func write(_ state: String) {
        guard let url = url() else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
        )
        try? state.write(to: url, atomically: true, encoding: .utf8)
    }

    static func read() -> String? {
        guard let url = url() else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func clear() {
        guard let url = url() else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
