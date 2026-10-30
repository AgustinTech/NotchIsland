import SwiftUI

/// Pestaña "Herramientas": temporizador / Pomodoro / cronómetro a la izquierda y acciones rápidas a la derecha.
struct ToolsTab: View {
    @ObservedObject var state: IslandState
    @ObservedObject var timer: TimerModel
    @ObservedObject var quick: QuickActions

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 10) {
                TimerPanel(model: timer)
                    .frame(width: min(262, max(220, geometry.size.width * 0.56)))
                QuickGrid(quick: quick, closeIsland: { state.close() })
            }
        }
        .onAppear { quick.refresh() }
    }
}

// MARK: - Temporizador

private struct TimerPanel: View {
    @ObservedObject var model: TimerModel

    var body: some View {
        VStack(spacing: 8) {
            modePicker

            HStack(spacing: 12) {
                clock
                controls
            }
            .frame(maxHeight: .infinity)
        }
        .padding(10)
        .frame(maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.07))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.6)
                )
        )
    }

    // MARK: Selector de modo

    private var modePicker: some View {
        let canChange = model.phase == .idle || model.phase == .finished
        return HStack(spacing: 2) {
            ForEach(TimerModel.Mode.allCases) { mode in
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { model.setMode(mode) }
                } label: {
                    Text(mode.title)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(model.mode == mode ? 1 : 0.5))
                        .frame(maxWidth: .infinity)
                        .frame(height: 20)
                        .background {
                            if model.mode == mode {
                                Capsule().fill(Color.white.opacity(0.18))
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(ScaleButtonStyle(pressed: 0.94))
                .disabled(!canChange)
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.black.opacity(0.25)))
        .opacity(canChange ? 1 : 0.6)
    }

    // MARK: Reloj

    private var clock: some View {
        TimerTicker(model: model) { reading in
            ZStack {
                Circle().stroke(Color.white.opacity(0.12), lineWidth: 5)
                Circle()
                    .trim(from: 0, to: model.phase == .finished ? 1 : max(0.005, reading.fraction))
                    .stroke(
                        model.phase == .finished ? Color.green : model.tint,
                        style: StrokeStyle(lineWidth: 5, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.9), value: reading.fraction)
                    .animation(.easeOut(duration: 0.3), value: model.phase == .finished)

                VStack(spacing: 0) {
                    if model.phase == .finished {
                        Image(systemName: "checkmark")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(Color.green)
                            .transition(.scale.combined(with: .opacity))
                    } else {
                        Text(TimerFormat.clock(reading.seconds))
                            .font(.system(size: reading.seconds >= 3600 ? 15 : 21, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(Color.white)
                            .contentTransition(.numericText())
                    }
                }
            }
            .frame(width: 80, height: 80)
        }
    }

    // MARK: Controles

    private var controls: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                Text(model.label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white)
                if model.mode == .pomodoro {
                    HStack(spacing: 3) {
                        ForEach(0..<TimerModel.cycle, id: \.self) { index in
                            Circle()
                                .fill(index < model.cycleProgress ? model.tint : Color.white.opacity(0.2))
                                .frame(width: 5, height: 5)
                        }
                    }
                }
            }
            .lineLimit(1)

            HStack(spacing: 8) {
                Button { model.toggle() } label: {
                    Image(systemName: model.phase == .running ? "pause.fill" : "play.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Color.black)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(Color.white))
                }
                .buttonStyle(ScaleButtonStyle(pressed: 0.9))

                if model.phase != .idle {
                    Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { model.reset() } } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.white)
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(Color.white.opacity(0.14)))
                    }
                    .buttonStyle(ScaleButtonStyle())
                    .transition(.scale.combined(with: .opacity))
                }
            }

            extras
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Temporizador parado: duraciones rápidas. En marcha: "+1 min". Cronómetro y Pomodoro: nada más.
    @ViewBuilder
    private var extras: some View {
        if model.mode == .timer {
            if model.phase == .idle {
                HStack(spacing: 4) {
                    ForEach(TimerModel.presets, id: \.self) { minutes in
                        chip("\(minutes)", selected: Int(model.duration / 60) == minutes) { model.setMinutes(minutes) }
                    }
                }
            } else if model.phase == .running || model.phase == .paused {
                chip("+1 min", selected: false, wide: true) { model.nudge(minutes: 1) }
            }
        } else if model.mode == .pomodoro {
            Text("25 min de enfoque · 5 de descanso")
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.45))
                .lineLimit(1)
        }
    }

    private func chip(_ title: String, selected: Bool, wide: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(selected ? Color.black : Color.white.opacity(0.85))
                .frame(width: wide ? 56 : 29, height: 22)
                .background(Capsule().fill(selected ? Color.white : Color.white.opacity(0.13)))
        }
        .buttonStyle(ScaleButtonStyle(pressed: 0.9))
    }
}

// MARK: - Acciones rápidas

private struct QuickGrid: View {
    @ObservedObject var quick: QuickActions
    var closeIsland: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                tile(.awake, symbol: "cup.and.saucer.fill", title: "Despierto", isOn: quick.awake) { quick.toggleAwake() }
                tile(.darkMode, symbol: quick.dark ? "moon.fill" : "sun.max.fill", title: quick.dark ? "Oscuro" : "Claro", isOn: quick.dark) { quick.toggleDarkMode() }
                tile(.dock, symbol: "dock.rectangle", title: "Dock", isOn: quick.dockHidden, subtitle: quick.dockHidden ? "Oculto" : nil) { quick.toggleDock() }
            }
            HStack(spacing: 6) {
                tile(.screenshot, symbol: "camera.viewfinder", title: "Captura", isOn: false) { quick.captureScreen(closeIsland: closeIsland) }
                trashTile
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func tile(
        _ kind: QuickActions.Kind, symbol: String, title: String, isOn: Bool, subtitle: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        let denied = quick.denied.contains(kind)
        return ToolTile(
            symbol: denied ? "lock.fill" : symbol,
            title: denied ? "Permiso" : title,
            subtitle: denied ? "Automatización" : subtitle,
            isOn: isOn && !denied,
            tint: .white,
            action: { denied ? quick.openAutomationSettings(for: kind) : action() }
        )
    }

    private var trashTile: some View {
        let denied = quick.denied.contains(.trash)
        let (symbol, title, tint, on): (String, String, Color, Bool) = {
            if denied { return ("lock.fill", "Permiso", .white, false) }
            switch quick.trash {
            case .idle: return ("trash", "Papelera", .white, false)
            case .armed: return ("trash.fill", "¿Vaciar?", Color(red: 1, green: 0.35, blue: 0.32), true)
            case .working: return ("trash.fill", "Vaciando…", .white, true)
            case .done: return ("checkmark", "Vacía", Color.green, true)
            }
        }()
        return ToolTile(
            symbol: symbol,
            title: title,
            subtitle: denied ? "Automatización" : (quick.trash == .armed ? "Pulsa otra vez" : nil),
            isOn: on,
            tint: tint,
            action: { denied ? quick.openAutomationSettings(for: .trash) : quick.tapTrash() }
        )
    }
}

private struct ToolTile: View {
    var symbol: String
    var title: String
    var subtitle: String?
    var isOn: Bool
    var tint: Color
    var action: () -> Void

    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 8.5, weight: .medium))
                        .opacity(0.65)
                        .lineLimit(1)
                }
            }
            .foregroundStyle(isOn ? Color.black : Color.white.opacity(0.9))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isOn ? tint : Color.white.opacity(hover ? 0.13 : 0.08))
            )
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(ScaleButtonStyle(pressed: 0.94))
        .onHover { hover = $0 }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isOn)
        .animation(.easeOut(duration: 0.15), value: hover)
    }
}
