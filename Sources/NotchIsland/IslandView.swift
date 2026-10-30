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
        p.addCurve(
            to: CGPoint(x: rect.minX + t, y: rect.minY + t),
            control1: CGPoint(x: rect.minX + t * 0.72, y: rect.minY),
            control2: CGPoint(x: rect.minX + t, y: rect.minY + t * 0.28)
        )
        p.addLine(to: CGPoint(x: rect.minX + t, y: rect.maxY - b))
        p.addCurve(
            to: CGPoint(x: rect.minX + t + b, y: rect.maxY),
            control1: CGPoint(x: rect.minX + t, y: rect.maxY - b * 0.45),
            control2: CGPoint(x: rect.minX + t + b * 0.45, y: rect.maxY)
        )
        p.addLine(to: CGPoint(x: rect.maxX - t - b, y: rect.maxY))
        p.addCurve(
            to: CGPoint(x: rect.maxX - t, y: rect.maxY - b),
            control1: CGPoint(x: rect.maxX - t - b * 0.45, y: rect.maxY),
            control2: CGPoint(x: rect.maxX - t, y: rect.maxY - b * 0.45)
        )
        p.addLine(to: CGPoint(x: rect.maxX - t, y: rect.minY + t))
        p.addCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control1: CGPoint(x: rect.maxX - t, y: rect.minY + t * 0.28),
            control2: CGPoint(x: rect.maxX - t * 0.72, y: rect.minY)
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

    private let openSpring = Animation.spring(response: 0.52, dampingFraction: 0.88)
    private let closeSpring = Animation.spring(response: 0.44, dampingFraction: 0.92)
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
            IslandBackdrop(expanded: expanded)

            if state.contentMounted {
                Group {
                    ExpandedContent(state: state, player: player, power: power, services: services)
                        .frame(width: open.width, height: open.height)
                        .scaleEffect(expanded ? 1 : 0.985, anchor: .top)
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
        .clipShape(shape)
        .overlay {
            shape.stroke(Color.white.opacity(expanded ? 0.10 : 0), lineWidth: 0.75)
                .allowsHitTesting(false)
        }
        .shadow(color: Color.black.opacity(expanded ? 0.42 : 0), radius: 14, y: 7)
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

// MARK: - Cristal translúcido (aspecto Siri)

/// Fondo de la isla. Cerrada: negro puro, para fundirse con el notch del hardware.
/// Abierta: se transparenta (material desenfocado del sistema) con un velo negro más
/// claro abajo, un brillo de cristal arriba y la franja del notch siempre en negro.
private struct IslandBackdrop: View {
    var expanded: Bool

    var body: some View {
        ZStack {
            // Negro opaco solo cerrada; abierta, el cristal deja ver lo de detrás.
            Color.black
                .opacity(expanded ? 0 : 1)

            Rectangle().fill(.ultraThinMaterial)
                .opacity(expanded ? 1 : 0)

            // Velo: negro sólido arriba (como el panel de Siri) y fundido a cristal abajo.
            LinearGradient(
                stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black, location: 0.42),
                    .init(color: .black.opacity(0.55), location: 0.75),
                    .init(color: .black.opacity(0.32), location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .opacity(expanded ? 1 : 0)

            // Reflejo del cristal en la parte alta.
            LinearGradient(
                stops: [
                    .init(color: .white.opacity(0.05), location: 0),
                    .init(color: .white.opacity(0), location: 0.3)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .opacity(expanded ? 1 : 0)
        }
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
            .padding(.top, 8)
            .padding(.bottom, 8)
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

    /// El notch físico determina cuántos controles caben a cada lado.
    private var sideWidth: CGFloat {
        max(24, (state.expandedSize.width - state.notchSize.width) / 2 - 16)
    }

    private var tabSlots: Int { max(1, Int(sideWidth / 24)) }

    private var primaryTabs: [IslandTab] {
        let tabs = state.visibleTabs
        guard tabs.count > tabSlots else { return tabs }
        var shown = Array(tabs.prefix(max(0, tabSlots - 1)))
        if !shown.isEmpty, !shown.contains(state.tab) { shown[shown.count - 1] = state.tab }
        return shown
    }

    private var overflowTabs: [IslandTab] {
        state.visibleTabs.filter { !primaryTabs.contains($0) }
    }

    private var tabWidth: CGFloat {
        let count = primaryTabs.count + (overflowTabs.isEmpty ? 0 : 1)
        return min(25, floor(sideWidth / CGFloat(max(count, 1))))
    }

    private func select(_ tab: IslandTab) {
        withAnimation(systemReduceMotion || state.reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.78).speed(state.animationSpeed)) {
            state.tab = tab
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(primaryTabs) { tab in
                    Button { select(tab) } label: {
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

                if !overflowTabs.isEmpty {
                    Menu {
                        ForEach(overflowTabs) { tab in
                            Button { select(tab) } label: {
                                Label(tab.title, systemImage: tab.symbol)
                            }
                        }
                    } label: {
                        Image(systemName: primaryTabs.isEmpty ? state.tab.symbol : "ellipsis")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.72))
                            .frame(width: tabWidth, height: 23)
                            .contentShape(Capsule())
                    }
                    .menuStyle(.borderlessButton)
                    .accessibilityLabel("Más pestañas")
                    .help("Más pestañas")
                }
            }

            Spacer(minLength: state.notchSize.width)

            HStack(spacing: 8) {
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
                    if sideWidth < 108 {
                        BatteryGlyph(percent: power.percent, charging: power.onAC)
                            .accessibilityLabel("Batería: \(power.percent) por ciento")
                    } else {
                        BatteryBadge(power: power)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
    }
}
