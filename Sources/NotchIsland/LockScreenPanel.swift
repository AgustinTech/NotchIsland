import AppKit
import Combine
import SwiftUI

/// Música en la pantalla de bloqueo, con la estética de cristal de la isla.
///
/// macOS no ofrece API para dibujar sobre la pantalla de bloqueo, pero una ventana por
/// encima del nivel de "shielding" del sistema se muestra (mismo truco que usan otras
/// utilidades). Si alguna versión de macOS lo impide, simplemente no se ve nada: el
/// resto de la app no se entera. Aparece al bloquear con algo sonando y desaparece al
/// desbloquear (o al parar la música).
final class LockScreenPresenter {
    private let player: NowPlayingModel
    private var panel: LockPanel?
    private var locked = false
    private var tokens: [NSObjectProtocol] = []

    init(player: NowPlayingModel) {
        self.player = player

        let center = DistributedNotificationCenter.default()
        tokens.append(center.addObserver(
            forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { [weak self] _ in
            self?.locked = true
            self?.sync()
        })
        tokens.append(center.addObserver(
            forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { [weak self] _ in
            self?.locked = false
            self?.sync()
        })
        // Si la música empieza (o se para) con el Mac bloqueado, el panel la sigue.
        player.$title
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.sync() }
            .store(in: &observers)
    }

    private var observers = Set<AnyCancellable>()

    deinit {
        let center = DistributedNotificationCenter.default()
        for token in tokens { center.removeObserver(token) }
    }

    private func sync() {
        guard locked, player.hasTrack else {
            panel?.orderOut(nil)
            return
        }
        if panel == nil { panel = LockPanel(player: player) }
        panel?.show()
    }
}

/// Panel sin bordes al nivel de la pantalla de bloqueo, centrado bajo el notch.
final class LockPanel: NSPanel {
    static let size = NSSize(width: 392, height: 128)

    init(player: NowPlayingModel) {
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        // Por encima del escudo de la pantalla de bloqueo.
        level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        let host = NSHostingView(
            rootView: LockMusicCard(player: player)
                .frame(width: Self.size.width, height: Self.size.height)
        )
        host.sizingOptions = []
        contentView = host
    }

    func show() {
        guard let screen = NSScreen.main else { return }
        let frame = screen.frame
        let x = frame.midX - Self.size.width / 2
        // Justo debajo del notch (o del borde superior en pantallas sin él).
        let y = frame.maxY - screen.safeAreaInsets.top - Self.size.height - 10
        setFrameOrigin(NSPoint(x: x, y: y))
        orderFrontRegardless()
    }
}

// MARK: - Tarjeta de música (liquid glass)

private struct LockMusicCard: View {
    @ObservedObject var player: NowPlayingModel

    var body: some View {
        HStack(spacing: 14) {
            artwork

            VStack(alignment: .leading, spacing: 0) {
                MarqueeText(
                    text: player.title,
                    font: .system(size: 14, weight: .semibold),
                    color: .white,
                    scrolls: player.isPlaying
                )
                .frame(height: 18)

                Text(player.artist)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.6))
                    .lineLimit(1)
                    .frame(height: 16, alignment: .leading)
                    .padding(.top, 2)

                Spacer(minLength: 0)

                LockProgress(player: player)
                    .padding(.bottom, 8)

                controls
            }
        }
        .padding(18)
        .frame(width: 392, height: 128, alignment: .leading)
        .background(LiquidGlass())
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.75)
        )
        .shadow(color: Color.black.opacity(0.40), radius: 18, y: 8)
        .preferredColorScheme(.dark)
    }

    private var artwork: some View {
        Group {
            if let image = player.artwork {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Rectangle().fill(Color.white.opacity(0.08))
                    Image(systemName: "music.note")
                        .font(.system(size: 24))
                        .foregroundStyle(Color.white.opacity(0.45))
                }
            }
        }
        .frame(width: 92, height: 92)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.6)
        )
    }

    private var controls: some View {
        HStack(spacing: 26) {
            Button { player.previous() } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 14, weight: .semibold))
            }
            Button { player.playPause() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 18, weight: .bold))
            }
            Button { player.next() } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 14, weight: .semibold))
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.white)
        .opacity(player.canControl ? 1 : 0.35)
        .disabled(!player.canControl)
        .frame(maxWidth: .infinity)
    }
}

/// Barra de progreso (solo lectura, un refresco por segundo mientras se ve).
private struct LockProgress: View {
    @ObservedObject var player: NowPlayingModel

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 1)) { context in
            let duration = max(player.duration, 1)
            let fraction = CGFloat(min(max(player.position(at: context.date) / duration, 0), 1))
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.18))
                    Capsule()
                        .fill(Color.white.opacity(0.9))
                        .frame(width: max(3, geo.size.width * fraction))
                }
            }
            .frame(height: 4)
        }
    }
}

/// Fondo de cristal: material del sistema, velo negro y brillo arriba.
private struct LiquidGlass: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.62), location: 0),
                    .init(color: .black.opacity(0.30), location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            LinearGradient(
                stops: [
                    .init(color: .white.opacity(0.10), location: 0),
                    .init(color: .white.opacity(0), location: 0.4)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }
}
