import AppKit
import Carbon.HIToolbox

/// Atajo de teclado global para abrir y cerrar la isla desde cualquier app.
///
/// Usa `RegisterEventHotKey` (Carbon): es API pública, no pide ningún permiso y no consume CPU
/// mientras no se pulsa. ⌃⌥N no choca con los atajos del sistema ni con los habituales de otras
/// apps (⌥Espacio, por ejemplo, lo usan lanzadores como Raycast o Alfred y las apps de ChatGPT o Claude).
///
/// Mientras la isla está abierta por el atajo se registra también Esc, para poder cerrarla sin
/// quitarle el foco a la app en la que estés escribiendo. Se libera en cuanto la isla se cierra.
final class GlobalHotkey {
    struct Combo {
        let keyCode: UInt32
        let modifiers: UInt32
        let label: String
    }

    static let toggle = Combo(keyCode: UInt32(kVK_ANSI_N), modifiers: UInt32(controlKey | optionKey), label: "⌃⌥N")
    private static let escape = Combo(keyCode: UInt32(kVK_Escape), modifiers: 0, label: "⎋")

    private enum Slot: UInt32 {
        case toggle = 1
        case escape = 2
    }

    var onToggle: () -> Void = {}
    var onEscape: () -> Void = {}

    private var handler: EventHandlerRef?
    private var refs: [Slot: EventHotKeyRef] = [:]

    deinit {
        for ref in refs.values { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
    }

    // MARK: - API

    /// Activa o desactiva el atajo principal (idempotente).
    func setEnabled(_ enabled: Bool) {
        if enabled {
            register(.toggle, Self.toggle)
        } else {
            unregister(.toggle)
            unregister(.escape)
        }
    }

    /// Esc cierra la isla solo mientras esté abierta con el atajo.
    func setEscapeArmed(_ armed: Bool) {
        guard refs[.toggle] != nil else { return }
        if armed {
            register(.escape, Self.escape)
        } else {
            unregister(.escape)
        }
    }

    // MARK: - Carbon

    private func register(_ slot: Slot, _ combo: Combo) {
        guard refs[slot] == nil else { return }
        installHandlerIfNeeded()

        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x4E49_5348), id: slot.rawValue)   // 'NISH'
        let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, id, GetApplicationEventTarget(), 0, &ref)
        // Si otra app ya tiene esta combinación el sistema la rechaza: el atajo simplemente no estará.
        if status == noErr, let ref { refs[slot] = ref }
    }

    private func unregister(_ slot: Slot) {
        if let ref = refs.removeValue(forKey: slot) { UnregisterEventHotKey(ref) }
    }

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var id = EventHotKeyID()
                let status = GetEventParameter(
                    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                    nil, MemoryLayout<EventHotKeyID>.size, nil, &id
                )
                guard status == noErr else { return status }
                Unmanaged<GlobalHotkey>.fromOpaque(userData).takeUnretainedValue().fire(id.id)
                return noErr
            },
            1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler
        )
    }

    fileprivate func fire(_ id: UInt32) {
        guard let slot = Slot(rawValue: id) else { return }
        DispatchQueue.main.async { [weak self] in
            switch slot {
            case .toggle: self?.onToggle()
            case .escape: self?.onEscape()
            }
        }
    }
}
