import SwiftUI

struct MusicTab: View {
    @ObservedObject var player: NowPlayingModel
    @AppStorage("showLyrics") private var showLyrics = true

    var body: some View {
        Group {
            if player.hasTrack {
                playing
            } else {
                idle
            }
        }
        .onAppear {
            player.refreshVolume()
            player.recheckPermissions()
        }
    }

    // MARK: - Sonando

    private var playing: some View {
        HStack(spacing: 16) {
            artwork

            VStack(alignment: .leading, spacing: 0) {
                header

                lyricsBlock
                    .frame(height: 36, alignment: .topLeading)
                    .padding(.top, 6)
                    .clipped()

                Spacer(minLength: 0)

                ProgressRow(player: player)

                PlayerControls(player: player)
                    .padding(.top, 2)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(player.title)
                    .font(.system(size: 15.5, weight: .bold))
                    .foregroundStyle(Color.white)
                    .lineLimit(1)
                    .contentTransition(.opacity)
                Text(player.artist)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.62))
                    .lineLimit(1)
                    .contentTransition(.opacity)
            }
            Spacer(minLength: 0)
            Visualizer(color: Color.white.opacity(0.85), active: player.isPlaying, bars: 4, maxHeight: 15, barWidth: 2.6)
                .padding(.top, 3)
        }
        .animation(.easeInOut(duration: 0.35), value: player.title)
    }

    private var artwork: some View {
        HoverArtwork(player: player)
    }

    @ViewBuilder
    private var lyricsBlock: some View {
        if showLyrics && player.lyricsState == .found {
            LyricsView(player: player)
        } else if showLyrics && player.lyricsState == .loading {
            Text("Buscando letra…")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.4))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        } else {
            Text(player.album)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.45))
                .lineLimit(2)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }

    // MARK: - Nada sonando

    private var idle: some View {
        HStack(spacing: 18) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.1), lineWidth: 0.6)
                )
                .frame(width: 92, height: 92)
                .overlay(
                    Image(systemName: "music.note")
                        .font(.system(size: 28))
                        .foregroundStyle(Color.white.opacity(0.4))
                )

            VStack(alignment: .leading, spacing: 6) {
                Text("Nada sonando")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Color.white)
                Text(player.detectedPlayer == .spotify ? "Spotify detectado; reproduce una canción" :
                     player.detectedPlayer == .music ? "Música detectada; reproduce una canción" :
                     "Reproduce algo en Música o Spotify")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.5))

                HStack(spacing: 8) {
                    openButton("Música", symbol: "music.note", player: .music)
                    openButton("Spotify", symbol: "dot.radiowaves.left.and.right", player: .spotify)
                }
                .padding(.top, 6)
            }
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity)
    }

    private func openButton(_ title: String, symbol: String, player: Player) -> some View {
        Button {
            player.open()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                Text(title)
            }
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(Color.white.opacity(0.92))
            .padding(.horizontal, 12)
            .frame(height: 27)
            .background(Capsule().fill(Color.white.opacity(0.13)))
        }
        .buttonStyle(ScaleButtonStyle())
    }
}

// MARK: - Carátula con inclinación 3D al pasar el cursor

/// Vista aparte para que el estado del hover (que cambia decenas de veces por segundo)
/// solo re-renderice la carátula y no la pestaña entera.
private struct HoverArtwork: View {
    @ObservedObject var player: NowPlayingModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var hover = false
    @State private var point: CGPoint = .zero

    private var tiltX: CGFloat {
        guard hover, !reduceMotion else { return 0 }
        return -(point.y / 104 - 0.5) * 2 * 6
    }

    private var tiltY: CGFloat {
        guard hover, !reduceMotion else { return 0 }
        return (point.x / 104 - 0.5) * 2 * 9
    }

    var body: some View {
        Button {
            player.openSource()
        } label: {
            Group {
                if let image = player.artwork {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .transition(.opacity)
                } else {
                    Rectangle()
                        .fill(Color.white.opacity(0.1))
                        .overlay(
                            Image(systemName: "music.note")
                                .font(.system(size: 28))
                                .foregroundStyle(Color.white.opacity(0.5))
                        )
                }
            }
            .frame(width: 104, height: 104)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.white.opacity(hover ? 0.22 : 0.14), lineWidth: 0.6)
            )
            .shadow(color: Color.black.opacity(hover ? 0.6 : 0.5), radius: hover ? 18 : 14, y: 8)
            .shadow(color: player.accent.opacity(player.isPlaying ? 0.35 : 0.1), radius: 18, y: 4)
            .rotation3DEffect(.degrees(tiltY), axis: (0, 1, 0), perspective: 0.6)
            .rotation3DEffect(.degrees(tiltX), axis: (1, 0, 0), perspective: 0.6)
            .scaleEffect(hover ? 1.04 : (player.isPlaying ? 1 : 0.9))
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: hover)
            .animation(.spring(response: 0.5, dampingFraction: 0.62), value: player.isPlaying)
            .animation(.easeInOut(duration: 0.4), value: player.artwork == nil)
            .animation(.spring(response: 0.22, dampingFraction: 0.85), value: point)
        }
        .buttonStyle(ScaleButtonStyle(pressed: 0.95))
        .accessibilityLabel("Abrir \(player.sourceName)")
        .help("Abrir \(player.sourceName)")
        .onHover { entering in
            hover = entering
            if !entering { point = .zero }
        }
        .onContinuousHover { phase in
            switch phase {
            case .active(let location): point = location
            case .ended: point = .zero
            @unknown default: break
            }
        }
    }
}

// MARK: - Controles (sin círculo, como Apple Music; aparece un fondo suave al pasar el ratón)

struct GlyphButton: View {
    let symbol: String
    let title: String
    var size: CGFloat = 18
    var frame: CGFloat = 38
    var action: () -> Void

    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(Color.white)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: frame, height: frame)
                .background(
                    Circle().fill(Color.white.opacity(hover ? 0.16 : 0))
                )
                .contentShape(Circle())
        }
        .buttonStyle(ScaleButtonStyle(pressed: 0.84))
        .accessibilityLabel(title)
        .help(title)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.15), value: hover)
    }
}

struct PlayerControls: View {
    @ObservedObject var player: NowPlayingModel
    @State private var prevTick = 0
    @State private var nextTick = 0

    var body: some View {
        HStack(spacing: 0) {
            Button {
                player.openSource()
            } label: {
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.5))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(ScaleButtonStyle())
            .accessibilityLabel("Abrir \(player.sourceName)")
            .help("Abrir \(player.sourceName)")

            Spacer(minLength: 6)

            HStack(spacing: 14) {
                GlyphButton(symbol: "backward.fill", title: "Pista anterior", size: 17) {
                    prevTick += 1
                    player.previous()
                }
                .symbolEffect(.bounce.down, value: prevTick)

                GlyphButton(symbol: player.isPlaying ? "pause.fill" : "play.fill", title: player.isPlaying ? "Pausar" : "Reproducir", size: 24, frame: 44) {
                    player.playPause()
                }

                GlyphButton(symbol: "forward.fill", title: "Pista siguiente", size: 17) {
                    nextTick += 1
                    player.next()
                }
                .symbolEffect(.bounce.down, value: nextTick)
            }
            .disabled(!player.canControl)

            Spacer(minLength: 6)

            HStack(spacing: 6) {
                Image(systemName: "speaker.wave.3.fill", variableValue: player.volume)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.55))
                    .frame(width: 18)
                MiniSlider(
                    value: Binding(
                        get: { player.volume },
                        set: { player.setVolume($0) }
                    ),
                    tint: Color.white.opacity(0.9),
                    onEnd: { player.commitVolume() }
                )
                .frame(width: 58)
            }
        }
        .frame(height: 44)
    }
}

// MARK: - Letra sincronizada (línea actual grande; toca una para saltar a ese punto)

struct LyricsView: View {
    @ObservedObject var player: NowPlayingModel

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 0.2)) { context in
            let time = player.position(at: context.date)
            let lines = player.lyrics
            let current = lines.lastIndex(where: { $0.time <= time + 0.15 }) ?? -1

            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(current...(current + 1)), id: \.self) { k in
                    row(k, current: current, lines: lines)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(.spring(response: 0.5, dampingFraction: 0.86), value: current)
        }
    }

    @ViewBuilder
    private func row(_ k: Int, current: Int, lines: [LyricLine]) -> some View {
        let valid = lines.indices.contains(k)
        let raw = valid ? lines[k].text : ""
        let text = valid ? (raw.isEmpty ? "♪" : raw) : " "
        let isCurrent = k == current

        // La línea actual, si no cabe, se desplaza en horizontal; la siguiente se difumina por el borde.
        MarqueeText(
            text: text,
            font: .system(size: isCurrent ? 14.5 : 12.5, weight: .bold),
            color: Color.white.opacity(isCurrent ? 1 : 0.38),
            scrolls: isCurrent
        )
            .blur(radius: isCurrent ? 0 : 0.5)
            .frame(maxWidth: .infinity, minHeight: 17, maxHeight: 17, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                if valid { player.seek(to: lines[k].time) }
            }
            .transition(.opacity)
    }
}

// MARK: - Barra de progreso (se puede arrastrar para saltar); tiempos debajo

struct ProgressRow: View {
    @ObservedObject var player: NowPlayingModel
    @State private var scrub: Double?
    @State private var hover = false

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 0.25)) { context in
            let duration = max(player.duration, 1)
            let position = scrub ?? player.position(at: context.date)
            let fraction = CGFloat(min(max(position / duration, 0), 1))
            let active = hover || scrub != nil
            let thickness: CGFloat = active ? 7 : 4

            VStack(spacing: 1) {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.2))
                            .frame(height: thickness)
                        Capsule()
                            .fill(Color.white.opacity(active ? 1 : 0.85))
                            .frame(width: max(thickness, geometry.size.width * fraction), height: thickness)
                    }
                    .frame(height: geometry.size.height)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                scrub = target(value.location.x, width: geometry.size.width, duration: duration)
                            }
                            .onEnded { value in
                                let time = target(value.location.x, width: geometry.size.width, duration: duration)
                                player.seek(to: time)
                                scrub = nil
                            }
                    )
                    .allowsHitTesting(player.canControl)
                }
                .frame(height: 12)
                .onHover { hover = $0 }
                .animation(.spring(response: 0.25, dampingFraction: 0.75), value: active)
                .focusable(player.canControl)
                .onMoveCommand { direction in
                    switch direction {
                    case .left: player.seek(to: max(0, position - 5))
                    case .right: player.seek(to: min(duration, position + 5))
                    default: break
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Posición de la canción")
                .accessibilityValue("\(format(position)) de \(format(duration))")
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: player.seek(to: min(duration, position + 5))
                    case .decrement: player.seek(to: max(0, position - 5))
                    @unknown default: break
                    }
                }

                HStack {
                    Text(format(position))
                    Spacer(minLength: 0)
                    Text("-" + format(max(duration - position, 0)))
                }
                .font(.system(size: 10, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Color.white.opacity(0.5))
            }
        }
    }

    private func target(_ x: CGFloat, width: CGFloat, duration: Double) -> Double {
        guard width > 0 else { return 0 }
        return Double(min(max(x / width, 0), 1)) * duration
    }

    private func format(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
