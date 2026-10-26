import AppKit
import SwiftUI

/// Cambio de pestaña con un deslizamiento (gesto horizontal de dos dedos sobre la isla abierta):
/// el contenido nuevo entra por el lado hacia el que apunta el gesto y el anterior sale por el contrario.
/// Los toques en la barra de arriba siguen usando el fundido de siempre.
extension IslandState {
    /// Pestaña siguiente (+1) o anterior (-1) entre las pestañas visibles. No da la vuelta.
    @discardableResult
    func shiftTab(_ delta: Int) -> Bool {
        let all = visibleTabs
        guard let index = all.firstIndex(of: tab), all.indices.contains(index + delta) else { return false }
        slideTo(all[index + delta], direction: delta > 0 ? 1 : -1)
        if UserDefaults.standard.bool(forKey: "haptics") {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        return true
    }

    private func slideTo(_ newTab: IslandTab, direction: Int) {
        let change = { withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) { self.tab = newTab } }

        if direction == tabDirection {
            change()
        } else {
            // La transición de salida se queda con lo que la vista saliente tenía la última vez que se
            // dibujó: primero se actualiza la dirección y, en el siguiente turno, la pestaña.
            tabDirection = direction
            DispatchQueue.main.async(execute: change)
        }

        // Pasado el deslizamiento, los cambios de pestaña vuelven al fundido normal.
        tabDirectionReset?.cancel()
        let reset = DispatchWorkItem { [weak self] in self?.tabDirection = 0 }
        tabDirectionReset = reset
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: reset)
    }

    /// Entra por un lado y sale por el otro; sin dirección (0) se mantiene el fundido con escala de siempre.
    var tabTransition: AnyTransition {
        guard tabDirection != 0 else {
            return .opacity.combined(with: .scale(scale: 0.96, anchor: .top))
        }
        let sign: CGFloat = tabDirection > 0 ? 1 : -1
        return .asymmetric(
            insertion: .modifier(active: TabSlide(x: sign * 64), identity: TabSlide(x: 0)).combined(with: .opacity),
            removal: .modifier(active: TabSlide(x: -sign * 64), identity: TabSlide(x: 0)).combined(with: .opacity)
        )
    }
}

struct TabSlide: ViewModifier {
    var x: CGFloat

    func body(content: Content) -> some View {
        content.offset(x: x)
    }
}
