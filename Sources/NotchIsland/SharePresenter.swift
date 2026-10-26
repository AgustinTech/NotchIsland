import AppKit

/// Muestra el selector de "Compartir" de macOS y mantiene la isla abierta mientras siga en pantalla.
///
/// Antes la isla se desanclaba a los 0,6 s y podía cerrarse justo debajo del selector. Ahora se
/// desancla cuando el selector se cierra sin elegir nada o cuando el servicio elegido termina
/// (con un tope por si macOS no avisara).
final class SharePresenter: NSObject, NSSharingServicePickerDelegate, NSSharingServiceDelegate {
    /// Solo hay un selector a la vez. Guardarlo aquí lo mantiene vivo (el delegado del selector no se retiene).
    private static var current: SharePresenter?
    /// Tiempo máximo con la isla anclada si no llega ningún aviso de que el selector se cerró.
    private static let failsafe: TimeInterval = 90

    private let state: IslandState
    private var timeout: DispatchWorkItem?

    private init(state: IslandState) {
        self.state = state
    }

    /// Abre el selector junto al puntero (donde se pulsó "Compartir"). El panel de la isla no es la
    /// ventana clave (ver `NotchPanel`), por eso se busca directamente.
    static func present(_ items: [Any], state: IslandState) {
        guard !items.isEmpty,
              let window = NSApp.windows.first(where: { $0 is NotchPanel }),
              let content = window.contentView else { return }

        current?.finish()
        let presenter = SharePresenter(state: state)
        current = presenter
        state.pinned = true

        var anchor = content.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        anchor.x = min(max(anchor.x, content.bounds.minX + 1), content.bounds.maxX - 1)
        anchor.y = min(max(anchor.y, content.bounds.minY + 1), content.bounds.maxY - 1)

        let picker = NSSharingServicePicker(items: items)
        picker.delegate = presenter
        picker.show(relativeTo: NSRect(x: anchor.x - 1, y: anchor.y - 1, width: 2, height: 2), of: content, preferredEdge: .minY)

        let work = DispatchWorkItem { [weak presenter] in presenter?.finish() }
        presenter.timeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + failsafe, execute: work)
    }

    /// Suelta el ancla. Solo hace algo si este es el selector actual (uno viejo no puede soltar el de otro).
    private func finish() {
        timeout?.cancel()
        timeout = nil
        guard Self.current === self else { return }
        Self.current = nil
        state.pinned = false
    }

    // MARK: NSSharingServicePickerDelegate

    func sharingServicePicker(_ picker: NSSharingServicePicker, didChoose service: NSSharingService?) {
        // Sin servicio = se cerró el selector sin elegir. Con servicio, se espera a que termine.
        if service == nil { finish() }
    }

    func sharingServicePicker(_ picker: NSSharingServicePicker, delegateFor sharingService: NSSharingService) -> NSSharingServiceDelegate? {
        self
    }

    // MARK: NSSharingServiceDelegate

    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        finish()
    }

    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
        finish()
    }
}
