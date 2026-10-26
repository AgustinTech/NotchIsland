import AppKit

/// Decide cuándo el puntero puede volver a abrir el notch.
///
/// Si el notch se cierra con el puntero todavía encima (por ejemplo con el gesto de dos dedos hacia
/// arriba), el siguiente movimiento volvería a armar el hover y la isla se reabriría a medio cerrar.
/// Después de cualquier cierre así, el hover queda en pausa hasta que el puntero salga de la zona.
struct HoverGuard {
    private(set) var waitingForExit = false

    /// Se llama al cerrar el notch. `pointerInside`: el puntero sigue sobre la zona de hover.
    mutating func closed(pointerInside: Bool) {
        waitingForExit = pointerInside
    }

    /// Se llama con cada movimiento con el notch cerrado. Devuelve si el hover puede armarse.
    mutating func pointerMoved(inside: Bool) -> Bool {
        guard waitingForExit else { return true }
        if inside { return false }
        waitingForExit = false
        return true
    }
}

/// Distingue un arrastre de archivos de cualquier otro arrastre con el botón pulsado.
///
/// La pasteboard de arrastre conserva el último contenido arrastrado, así que mirar solo si hay una URL
/// de archivo daría falsos positivos (selección de texto, deslizadores…). Se anota su `changeCount` al
/// pulsar el botón: solo hay arrastre de archivos si cambió desde entonces y lleva archivos.
enum FileDragProbe {
    /// `baseline`: `changeCount` al pulsar el botón (`nil` si no se vio la pulsación).
    static func isFileDrag(baseline: Int?, current: Int, types: [NSPasteboard.PasteboardType]?) -> Bool {
        guard let baseline, current != baseline else { return false }
        return types?.contains(.fileURL) ?? false
    }
}
