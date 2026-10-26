import SwiftUI
import UniformTypeIdentifiers

// MARK: - Forma del notch
// Esquinas inferiores redondeadas y "orejas" cóncavas arriba, para que parezca
// que el notch se funde con la barra de menús (como en la Dynamic Island).

struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set {
            topRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let t = max(0, min(topRadius, rect.width / 4, rect.height / 2))
        let b = max(0, min(bottomRadius, (rect.width - 2 * t) / 2, rect.height - t))

        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(
            to: CGPoint(x: rect.minX + t, y: rect.minY + t),
            control: CGPoint(x: rect.minX + t, y: rect.minY)
        )
        p.addLine(to: CGPoint(x: rect.minX + t, y: rect.maxY - b))
        p.addQuadCurve(
            to: CGPoint(x: rect.minX + t + b, y: rect.maxY),
            control: CGPoint(x: rect.minX + t, y: rect.maxY)
        )
        p.addLine(to: CGPoint(x: rect.maxX - t - b, y: rect.maxY))
        p.addQuadCurve(
            to: CGPoint(x: rect.maxX - t, y: rect.maxY - b),
            control: CGPoint(x: rect.maxX - t, y: rect.maxY)
        )
        p.addLine(to: CGPoint(x: rect.maxX - t, y: rect.minY + t))
        p.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - t, y: rect.minY)
        )
        p.closeSubpath()
        return p
    }
}

// MARK: - Vista raíz

struct IslandView: View {
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @ObservedObject var state: IslandState
    @ObservedObject var player: NowPlayingModel
    @ObservedObject var power: PowerModel
    let services: Services

    private let openSpring = Animation.spring(response: 0.45, dampingFraction: 0.82)
    private let closeSpring = Animation.spring(response: 0.38, dampingFraction: 0.92)
    private let liveSpring = Animation.spring(response: 0.45, dampingFraction: 0.72)
    private let hoverSpring = Animation.spring(response: 0.28, dampingFraction: 0.58)

    private var reduceAnimations: Bool { systemReduceMotion || state.reduceMotion }
    private func tuned(_ animation: Animation) -> Animation? {
        reduceAnimations ? nil : animation.speed(state.animationSpeed)
    }

    var body: some View {
        let size = state.bodySize
        let ear = state.earRadius
        let shape = NotchShape(topRadius: ear, bottomRadius: state.bottomRadius)
        let open = state.expandedSize
        let resting = state.restingSize
        let expanded = state.expanded

        // La forma negra es lo único que cambia de tamaño. Todo el contenido se queda a su tamaño
        // final y la forma lo va descubriendo; solo cambia su opacidad (con tiempos distintos al
        // abrir y al cerrar) para que nada salte ni aparezca fantasma dentro de la caja.
        ZStack(alignment: .top) {
            Color.black

            if state.contentMounted {
                Group {
                    if state.tab == .music && player.hasTrack {
                        MusicBackdrop(player: player, reduceMotionSetting: state.reduceMotion)
                            .frame(width: open.width + 40, height: open.height)
                    }
                    ExpandedContent(state: state, player: player, power: power, services: services)
                        .frame(width: open.width, height: open.height)
                        .scaleEffect(expanded ? 1 : 0.97, anchor: .top)
                }
                .opacity(expanded ? 1 : 0)
                .allowsHitTesting(expanded)
                .animation(tuned(expanded ? openFade : closeFade), value: expanded)
                .transition(
                    (reduceAnimations ? AnyTransition.opacity : AnyTransition.opacity
                        .combined(with: .scale(scale: 0.96, anchor: .top))
                    ).animation(tuned(openFade))
                )
            }

            if state.isLive {
                CollapsedContent(state: state, player: player, power: power, activity: state.activity, timer: state.timer)
                    .frame(width: resting.width, height: resting.height)
                    .opacity(expanded ? 0 : 1)
                    .allowsHitTesting(!expanded)
                    .animation(tuned(expanded ? Animation.easeIn(duration: 0.1) : Animation.easeOut(duration: 0.2).delay(0.2)), value: expanded)
                    .transition(.opacity.animation(tuned(.easeOut(duration: 0.2).delay(0.15))))
            } else if !expanded {
                Button {
                    state.open()
                } label: {
                    Color.clear
                        .frame(width: resting.width, height: resting.height)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Abrir NotchIsland")
            }
        }
        .frame(width: size.width + ear * 2, height: size.height, alignment: .top)
        .overlay(
            shape.stroke(
                LinearGradient(
                    stops: [
                        .init(color: Color.white.opacity(0), location: 0),
                        .init(color: Color.white.opacity(0.16), location: 0.55),
                        .init(color: Color.white.opacity(0.06), location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                lineWidth: 1
            )
            .opacity(expanded ? 1 : 0)
        )
        .clipShape(shape)
        .shadow(color: Color.black.opacity(expanded ? 0.45 : 0), radius: 16, y: 8)
        // Con la isla abierta el HUD de volumen/brillo sale como una pastilla DEBAJO de la isla (no tapa nada).
        .overlay(alignment: .bottom) {
            if expanded, let kind = state.hudKind {
                HUDPill(kind: kind)
                    .offset(y: 46)
                    .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .top)))
            }
        }
        .animation(tuned(.spring(response: 0.32, dampingFraction: 0.82)), value: state.hudKind != nil)
        .onDrop(of: [UTType.fileURL], isTargeted: $state.dropTargeted) { providers in
            let accepted = state.ingest(providers)
            if accepted { state.tab = .tray }
            return accepted
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(tuned(expanded ? openSpring : closeSpring), value: expanded)
        .animation(tuned(liveSpring), value: state.liveSide)
        .animation(tuned(liveSpring), value: state.peekHeight)
        .animation(tuned(hoverSpring), value: state.hovering)
        .animation(tuned(.easeInOut(duration: 0.5)), value: player.accent)
        .ignoresSafeArea()
    }

    private let openFade = Animation.easeOut(duration: 0.28).delay(0.08)
    private let closeFade = Animation.easeIn(duration: 0.2)
}

// MARK: - Fondo con el color de la carátula

struct MusicBackdrop: View {
    @ObservedObject var player: NowPlayingModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let reduceMotionSetting: Bool

    var body: some View {
        ZStack {
            Color(white: 0.05)

            if let image = player.backdrop {
                // Dos capas de la propia carátula, ampliadas y girando despacio en sentidos
                // contrarios (solo se mueven mientras suena), como el fondo de Apple Music.
                TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: !player.isPlaying || reduceMotion || reduceMotionSetting)) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    ZStack {
                        layer(image, size: 800, degrees: t * 5, x: 60 * sin(t * 0.17), y: 22 * cos(t * 0.13))
                            .opacity(0.95)
                        layer(image, size: 760, degrees: 50 - t * 4, x: -70 * cos(t * 0.14), y: 26 * sin(t * 0.2))
                            .opacity(0.4)
                            .blendMode(.plusLighter)
                    }
                }
                .transition(.opacity)
            }

            // Un velo uniforme y otro hacia abajo para que texto y controles se lean bien.
            Color.black.opacity(0.22 + 0.38 * player.backdropLuma)
            LinearGradient(
                colors: [Color.black.opacity(0), Color.black.opacity(0.45)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .clipped()
        .animation(.easeInOut(duration: 0.8), value: player.backdrop == nil)
    }

    private func layer(_ image: NSImage, size: CGFloat, degrees: Double, x: Double, y: Double) -> some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fill)
            .frame(width: size, height: size)
            .rotationEffect(.degrees(degrees))
            .offset(x: x, y: y)
    }
}

// MARK: - Notch cerrado con actividad

struct CollapsedContent: View {
    @ObservedObject var state: IslandState
    @ObservedObject var player: NowPlayingModel
    @ObservedObject var power: PowerModel
    @ObservedObject var activity: ActivityCenter
    @ObservedObject var timer: TimerModel

    /// Descarga en curso (si no hay un aviso encima) o recién terminada. Prioridad: avisos > descargas > música.
    private var download: (summary: DownloadSummary?, done: Bool)? {
        if case .downloadDone? = state.transient { return (nil, true) }
        if state.transient == nil, let summary = activity.downloads { return (summary, false) }
        return nil
    }

    var body: some View {
        Button {
            state.open()
        } label: {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    leading
                        .frame(width: state.liveSide)
                    Spacer(minLength: 0)
                    trailing
                        .frame(width: state.liveSide)
                }
                .frame(height: state.notchSize.height)

                if state.peekHeight > 0 {
                    peekLine
                        .frame(height: state.peekHeight)
                        .padding(.horizontal, 18)
                        .transition(.opacity.combined(with: .offset(y: -6)))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Abrir NotchIsland")
    }

    // MARK: Lado izquierdo

    @ViewBuilder
    private var leading: some View {
        switch state.transient {
        case .charging?:
            Image(systemName: "bolt.fill")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Color.green)
                .symbolEffect(.pulse)
        case .lowBattery?:
            Image(systemName: "battery.25percent")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.red)
                .symbolEffect(.pulse)
        case .device(_, let icon, _)?:
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.white)
        case .airdrop?:
            AirDropGlyph()
        case .timerDone?:
            TimerDoneGlyph()
        case .meeting(let alert)?:
            MeetingGlyph(alert: alert)
        case .volume(let level, let muted)?:
            HUDGlyph(kind: .volume(level: level, muted: muted))
        case .brightness(let level)?:
            HUDGlyph(kind: .brightness(level: level))
        default:
            if let download {
                ActivityRing(fraction: download.done ? 1 : download.summary?.fraction, done: download.done)
            } else if timer.showsLive {
                TimerGlyph(timer: timer)
            } else if let image = player.artwork {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 22, height: 22)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .scaleEffect(player.isPlaying ? 1 : 0.88)
                    .animation(.spring(response: 0.35, dampingFraction: 0.7), value: player.isPlaying)
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(player.accent)
            }
        }
    }

    // MARK: Lado derecho

    @ViewBuilder
    private var trailing: some View {
        switch state.transient {
        case .charging?:
            Text("\(power.percent)%")
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Color.green)
        case .lowBattery?:
            Text("\(power.percent)%")
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Color.red)
        case .device(_, _, let percent)?:
            if let percent {
                Text("\(percent)%")
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Color.white)
            } else {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.green)
            }
        case .airdrop?, .downloadDone?:
            ActivityThumbnail(image: activity.image)
        case .timerDone?:
            Text("Listo")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.orange)
        case .meeting(let alert)?:
            MeetingCountdown(alert: alert)
        case .volume(let level, let muted)?:
            HUDPercent(level: muted ? 0 : level)
        case .brightness(let level)?:
            HUDPercent(level: level)
        default:
            if let summary = download?.summary {
                DownloadTrailing(summary: summary)
            } else if timer.showsLive {
                TimerTrailing(timer: timer)
            } else {
                Visualizer(color: player.accent, active: player.isPlaying)
            }
        }
    }

    // MARK: Línea de abajo (canción nueva, dispositivo conectado)

    @ViewBuilder
    private var peekLine: some View {
        switch state.transient {
        case .device(let name, _, _)?:
            Text("\(name) conectado")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.85))
                .lineLimit(1)
        case .track?:
            HStack(spacing: 6) {
                Text(player.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .lineLimit(1)
                Text(player.artist)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.55))
                    .lineLimit(1)
            }
        case .airdrop(let count, let name)?:
            AirDropPeek(count: count, name: name)
        case .meeting(let alert)?:
            MeetingPeek(alert: alert)
        case .downloadDone(let count, let name)?:
            DownloadDonePeek(count: count, name: name)
        case .timerDone(let title)?:
            TimerDonePeek(title: title)
        case .volume(let level, let muted)?:
            HUDBar(level: muted ? 0 : level)
        case .brightness(let level)?:
            HUDBar(level: level)
        default:
            if let summary = download?.summary {
                DownloadPeek(summary: summary)
            } else if timer.showsLive {
                TimerPeek(timer: timer)
            }
        }
    }
}

// MARK: - Notch abierto

struct ExpandedContent: View {
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @ObservedObject var state: IslandState
    @ObservedObject var player: NowPlayingModel
    @ObservedObject var power: PowerModel
    let services: Services

    var body: some View {
        VStack(spacing: 0) {
            TopBar(state: state, power: power)
                .frame(height: state.notchSize.height + 8)

            Group {
                switch state.tab {
                case .music:
                    MusicTab(player: player)
                case .tray:
                    TrayTab(state: state)
                case .today:
                    TodayTab(
                        calendar: services.calendar,
                        weather: services.weather,
                        devices: services.devices
                    )
                case .clipboard:
                    ClipboardTab(model: services.clipboard, expanded: state.expanded)
                case .tools:
                    ToolsTab(state: state, timer: state.timer, quick: services.quick)
                case .mirror:
                    MirrorTab(expanded: state.expanded)
                }
            }
            .id(state.tab)
            .transition(state.tabTransition)
            .padding(.horizontal, 22)
            .padding(.top, 10)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .animation(systemReduceMotion || state.reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.86).speed(state.animationSpeed), value: state.tab)
    }
}

/// Franja a la altura del notch: pestañas a la izquierda, ajustes y batería a la derecha.
struct TopBar: View {
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @ObservedObject var state: IslandState
    @ObservedObject var power: PowerModel
    @Namespace private var tabSpace

    /// Reserva a cada lado el espacio físico del notch, también con seis pestañas visibles.
    private var tabWidth: CGFloat {
        let side = (state.expandedSize.width - state.notchSize.width) / 2 - 18
        return min(25, max(18, floor(side / CGFloat(max(state.visibleTabs.count, 1)))))
    }

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(state.visibleTabs) { tab in
                    Button {
                        withAnimation(systemReduceMotion || state.reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.78).speed(state.animationSpeed)) {
                            state.tab = tab
                        }
                    } label: {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(state.tab == tab ? 1 : 0.45))
                            .frame(width: tabWidth, height: 23)
                            .background {
                                if state.tab == tab {
                                    Capsule()
                                        .fill(Color.white.opacity(0.18))
                                        .matchedGeometryEffect(id: "tab", in: tabSpace)
                                }
                            }
                            .contentShape(Capsule())
                    }
                    .buttonStyle(ScaleButtonStyle())
                    .accessibilityLabel(tab.title)
                    .accessibilityAddTraits(state.tab == tab ? .isSelected : [])
                    .help(tab.title)
                }
            }

            Spacer(minLength: state.notchSize.width + 8)

            HStack(spacing: 12) {
                Button {
                    state.showMenu()
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.5))
                        .frame(width: 24, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(ScaleButtonStyle())
                .accessibilityLabel("Ajustes")
                .help("Ajustes")

                if power.hasBattery {
                    BatteryBadge(power: power)
                }
            }
        }
        .padding(.horizontal, 18)
    }
}
