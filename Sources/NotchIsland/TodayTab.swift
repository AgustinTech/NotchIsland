import AppKit
import SwiftUI

/// Pestaña "Hoy": a la izquierda la agenda y los recordatorios (que se alternan), a la derecha el tiempo
/// y, solo si hay alguno conectado, la batería de los dispositivos Bluetooth.
struct TodayTab: View {
    @ObservedObject var calendar: CalendarModel
    @ObservedObject var weather: WeatherModel
    @ObservedObject var devices: DevicesModel

    var body: some View {
        let hasDevices = !devices.devices.isEmpty

        HStack(spacing: 8) {
            AgendaPanel(model: calendar)

            VStack(spacing: 8) {
                WeatherCard(model: weather, compact: hasDevices)

                if hasDevices {
                    DevicesCard(model: devices)
                        .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .bottom)))
                }
            }
            .frame(width: 176)
        }
        .animation(.spring(response: 0.42, dampingFraction: 0.86), value: hasDevices)
    }
}

// MARK: - Superficie de las tarjetas (igual que `Card`)

extension View {
    /// Fondo de tarjeta: relleno blanco al 7 %, esquinas continuas de 16 pt y filete de luz arriba.
    func todaySurface() -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white.opacity(0.07))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [Color.white.opacity(0.12), Color.white.opacity(0.02)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                ),
                                lineWidth: 0.8
                            )
                    )
            )
    }
}

// MARK: - Estado vacío / permisos

/// Icono, título y explicación centrados, con un botón opcional. Sirve para "Día libre",
/// "Todo al día", permisos denegados, etc.
struct TodayEmptyState: View {
    let symbol: String
    var tint: Color = .white
    let title: String
    var message: String?
    var actionTitle: String?
    var action: () -> Void = {}

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: symbol)
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 23, weight: .medium))
                .foregroundStyle(tint)
                .padding(.bottom, 2)

            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.9))
                .multilineTextAlignment(.center)

            if let message {
                Text(message)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.white.opacity(0.45))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }

            if let actionTitle {
                Button(action: action) {
                    Text(actionTitle)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.92))
                        .padding(.horizontal, 10)
                        .frame(height: 20)
                        .background(Capsule().fill(Color.white.opacity(0.14)))
                }
                .buttonStyle(ScaleButtonStyle())
                .padding(.top, 3)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

enum TodaySettings {
    /// Abre un panel de "Privacidad y seguridad" (Calendarios, Recordatorios, Localización…).
    static func openPrivacy(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }

    static func openApp(_ bundleID: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}

// MARK: - Tiempo

struct WeatherCard: View {
    @ObservedObject var model: WeatherModel
    /// Con dispositivos conectados la tarjeta se queda en lo esencial (sin título ni horas).
    var compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !compact {
                header
                    .transition(.opacity)
            }

            if let temperature = model.temperature {
                current(temperature)
                if !compact, !slots.isEmpty {
                    hourly
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            } else if model.denied {
                message(
                    symbol: "location.slash.fill",
                    text: "Ubicación desactivada",
                    action: "Abrir Ajustes"
                ) { TodaySettings.openPrivacy("Privacy_LocationServices") }
            } else if model.failed {
                message(symbol: "cloud.slash.fill", text: "Sin datos del tiempo", action: "Reintentar") { model.retry() }
            } else {
                skeleton
            }

            Spacer(minLength: 0)
        }
        .padding(compact ? 10 : 11)
        .todaySurface()
        .animation(.spring(response: 0.42, dampingFraction: 0.86), value: compact)
        .animation(.easeInOut(duration: 0.3), value: model.temperature)
    }

    // MARK: Cabecera

    private var header: some View {
        HStack(spacing: 5) {
            Image(systemName: "cloud.sun.fill")
                .foregroundStyle(Color.cyan)
            Text((model.place.isEmpty ? "Tiempo" : model.place).uppercased())
                .foregroundStyle(Color.white.opacity(0.45))
                .lineLimit(1)
        }
        .font(.system(size: 9.5, weight: .bold))
        .tracking(0.4)
    }

    // MARK: Ahora

    private func current(_ temperature: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: model.symbol)
                .symbolRenderingMode(.multicolor)
                .font(.system(size: compact ? 23 : 26))
                .frame(width: compact ? 28 : 31)

            Text("\(temperature)°")
                .font(.system(size: compact ? 24 : 26, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Color.white)
                .contentTransition(.numericText())
                .fixedSize()

            VStack(alignment: .leading, spacing: 2) {
                Text(compact && !model.place.isEmpty ? model.place : model.summary)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.7))
                    .lineLimit(1)
                highLow
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var highLow: some View {
        if let high = model.high, let low = model.low {
            HStack(spacing: 2) {
                Image(systemName: "arrow.up")
                Text("\(high)°")
                Image(systemName: "arrow.down")
                    .padding(.leading, 3)
                Text("\(low)°")
            }
            .font(.system(size: 9.5, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(Color.white.opacity(0.45))
            .lineLimit(1)
            .fixedSize()
        }
    }

    // MARK: Próximas horas

    /// Cuatro horas, cada tres, empezando por la actual.
    private var slots: [HourForecast] {
        let calendar = Calendar.current
        guard let start = calendar.dateInterval(of: .hour, for: Date())?.start else { return [] }
        let upcoming = model.hours.filter { $0.date >= start }
        return stride(from: 0, to: upcoming.count, by: 3).prefix(4).map { upcoming[$0] }
    }

    private var hourly: some View {
        VStack(spacing: 6) {
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 0.5)

            HStack(spacing: 0) {
                ForEach(Array(slots.enumerated()), id: \.element.id) { index, slot in
                    VStack(spacing: 3) {
                        Text(index == 0 ? "Ahora" : slot.date.formatted(.dateTime.hour()))
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(index == 0 ? 0.7 : 0.4))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        Image(systemName: slot.symbol)
                            .symbolRenderingMode(.multicolor)
                            .font(.system(size: 13))
                            .frame(height: 15)
                        Text("\(slot.temperature)°")
                            .font(.system(size: 10.5, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(Color.white.opacity(0.88))
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    // MARK: Cargando y errores

    private var skeleton: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.white.opacity(0.09))
                .frame(width: compact ? 26 : 30, height: compact ? 26 : 30)
            VStack(alignment: .leading, spacing: 5) {
                Capsule().fill(Color.white.opacity(0.1)).frame(width: 52, height: 10)
                Capsule().fill(Color.white.opacity(0.06)).frame(width: 82, height: 8)
            }
        }
        .frame(maxHeight: .infinity, alignment: .center)
    }

    private func message(symbol: String, text: String, action: String, run: @escaping () -> Void) -> some View {
        TodayEmptyState(symbol: symbol, tint: Color.white.opacity(0.6), title: text, actionTitle: action, action: run)
            .lineLimit(1)
    }
}

// MARK: - Dispositivos

/// Anillos de batería al estilo del widget de Baterías. Solo existe cuando hay algún dispositivo.
struct DevicesCard: View {
    @ObservedObject var model: DevicesModel

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            ForEach(Array(model.devices.prefix(4))) { device in
                DeviceRing(device: device)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .frame(height: 62)
        .todaySurface()
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: model.devices.map { $0.id })
    }
}

struct DeviceRing: View {
    let device: BTDevice
    @State private var appeared = false
    @State private var hover = false

    /// Para unos auriculares, el más bajo de los dos (el estuche no cuenta); para el resto, su batería.
    private var percent: Int {
        let main = device.parts.filter { $0.label != "Estuche" }
        return (main.isEmpty ? device.parts : main).map { $0.percent }.min() ?? 0
    }

    private var tint: Color {
        percent <= 20 ? Color.red : Color.green
    }

    private var detail: String {
        let parts = device.parts.map { $0.label.isEmpty ? "\($0.percent) %" : "\($0.label) \($0.percent) %" }
        return device.name + " · " + parts.joined(separator: "  ")
    }

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.14), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: appeared ? max(0.02, CGFloat(percent) / 100) : 0.001)
                    .stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: device.icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.92))
            }
            .frame(width: 30, height: 30)
            .scaleEffect(hover ? 1.08 : 1)

            Text("\(percent)%")
                .font(.system(size: 9.5, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(percent <= 20 ? Color.red : Color.white.opacity(0.7))
        }
        .frame(width: 34)
        .contentShape(Rectangle())
        .help(detail)
        .onHover { hover = $0 }
        .animation(.spring(response: 0.3, dampingFraction: 0.65), value: hover)
        .onAppear {
            withAnimation(.spring(response: 0.7, dampingFraction: 0.85).delay(0.1)) { appeared = true }
        }
    }
}

/// Batería de una pieza: barrita + porcentaje (o solo texto compacto si hay varias piezas).
struct BatteryPill: View {
    let label: String
    let percent: Int
    var compact = false

    private var short: String {
        label == "Estuche" ? "E" : label
    }

    var body: some View {
        HStack(spacing: 3) {
            if !label.isEmpty {
                Text(compact ? short : label)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.45))
            }
            if !compact {
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.16)).frame(width: 22, height: 4)
                    Capsule()
                        .fill(percent <= 20 ? Color.red : Color.green)
                        .frame(width: max(3, 22 * CGFloat(percent) / 100), height: 4)
                }
            }
            Text(compact ? "\(percent)" : "\(percent)%")
                .font(.system(size: 9.5, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(percent <= 20 ? Color.red : Color.white.opacity(0.65))
        }
        .lineLimit(1)
        .fixedSize()
    }
}
