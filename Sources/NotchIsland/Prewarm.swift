import AppKit
import Combine
import SwiftUI

/// Calienta la isla abierta poco después de arrancar, para que la primera apertura no dé tirones.
///
/// El contenido de la isla abierta se crea al abrir por primera vez (SwiftUI instancia la jerarquía
/// de vistas, resuelve tipos genéricos, carga fuentes y símbolos, compila los efectos de dibujo…) y
/// eso costaba ~50 ms justo cuando empieza la animación. Aquí se monta una vez ese contenido,
/// invisible, se maqueta y se dibuja un instante, y se desmonta. No queda nada en marcha: el
/// contenido montado no abre la cámara ni el portapapeles (solo lo hace con la isla abierta), y al
/// desmontarlo se detienen sus temporizadores.
///
/// La vista con una canción (carátula, letra, progreso) no es la de "Nada sonando", así que, si al
/// arrancar no sonaba nada, se vuelve a calentar una vez cuando aparece la primera canción.
enum IslandPrewarm {
    private static var warmedWithTrack = false
    private static var firstTrack: AnyCancellable?

    static func start(state: IslandState, host: NSView, player: NowPlayingModel) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            warm(state: state, host: host, player: player)
        }
        firstTrack = player.$title
            .removeDuplicates()
            .filter { !$0.isEmpty }
            .first()
            .sink { _ in
                // Da tiempo a que lleguen la carátula y la letra.
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    if !warmedWithTrack, player.hasTrack { warm(state: state, host: host, player: player) }
                }
            }
    }

    private static func warm(state: IslandState, host: NSView, player: NowPlayingModel) {
        // Solo con la isla en reposo: si se está abriendo o cerrando, el contenido ya existe.
        guard !state.expanded, !state.contentMounted else { return }
        warmedWithTrack = player.hasTrack

        state.contentMounted = true
        host.layoutSubtreeIfNeeded()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            // Si entretanto se abrió, `close()` se encargará de desmontar.
            if !state.expanded { state.contentMounted = false }
        }
    }
}
