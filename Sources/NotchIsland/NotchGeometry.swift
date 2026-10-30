import AppKit

/// Lo mínimo que hace falta saber de una pantalla para calcular la geometría de la isla.
/// Existe para poder probar la elección de pantalla y las medidas con pantallas inventadas.
struct ScreenInfo: Equatable {
    var frame: CGRect
    /// Margen superior seguro: mayor que cero solo en pantallas con notch.
    var safeAreaTop: CGFloat = 0
    /// Anchos de las franjas a cada lado del notch (de la barra de menús).
    var auxLeftWidth: CGFloat = 0
    var auxRightWidth: CGFloat = 0

    var hasNotch: Bool { safeAreaTop > 0 }

    init(frame: CGRect, safeAreaTop: CGFloat = 0, auxLeftWidth: CGFloat = 0, auxRightWidth: CGFloat = 0) {
        self.frame = frame
        self.safeAreaTop = safeAreaTop
        self.auxLeftWidth = auxLeftWidth
        self.auxRightWidth = auxRightWidth
    }

    init(_ screen: NSScreen) {
        self.init(
            frame: screen.frame,
            safeAreaTop: screen.safeAreaInsets.top,
            auxLeftWidth: screen.auxiliaryTopLeftArea?.width ?? 0,
            auxRightWidth: screen.auxiliaryTopRightArea?.width ?? 0
        )
    }
}

/// Medidas del notch de la pantalla (o una "píldora" falsa si no hay notch).
struct NotchGeometry {
    let screenFrame: NSRect
    let notchSize: CGSize
    let expandedSize: CGSize

    /// Notch inventado para pantallas sin notch (Mac sin notch, monitor externo, tapa cerrada):
    /// una píldora que cuelga del borde superior, centrada.
    static let fakeNotch = CGSize(width: 190, height: 32)

    static func detect() -> NotchGeometry {
        let screens = NSScreen.screens
        let main = NSScreen.main.flatMap { screens.firstIndex(of: $0) }
        return make(screens: screens.map(ScreenInfo.init), mouse: NSEvent.mouseLocation, mainIndex: main)
    }

    /// Versión pura de `detect`: elige la pantalla y calcula las medidas.
    /// Pantalla: la del notch si hay; si no, la que contiene el puntero; si no, la principal; si no, la primera.
    static func make(screens: [ScreenInfo], mouse: CGPoint, mainIndex: Int? = nil) -> NotchGeometry {
        let screen = pick(screens, mouse: mouse, mainIndex: mainIndex)
            ?? ScreenInfo(frame: CGRect(x: 0, y: 0, width: 1440, height: 900))

        var notch = fakeNotch
        if screen.hasNotch {
            if screen.auxLeftWidth > 0, screen.auxRightWidth > 0 {
                notch.width = screen.frame.width - screen.auxLeftWidth - screen.auxRightWidth
            }
            notch.height = screen.safeAreaTop
        }

        return NotchGeometry(
            screenFrame: screen.frame,
            notchSize: notch,
            expandedSize: CGSize(
                width: IslandVisualSize.normal.width,
                height: notch.height + IslandVisualSize.normal.extraHeight
            )
        )
    }

    private static func pick(_ screens: [ScreenInfo], mouse: CGPoint, mainIndex: Int?) -> ScreenInfo? {
        if let notched = screens.first(where: \.hasNotch) { return notched }
        // El borde superior pertenece a la pantalla aunque `contains` lo deje fuera (intervalo abierto).
        if let underMouse = screens.first(where: { $0.frame.insetBy(dx: -1, dy: -1).contains(mouse) }) { return underMouse }
        if let mainIndex, screens.indices.contains(mainIndex) { return screens[mainIndex] }
        return screens.first
    }
}
