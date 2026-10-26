import SwiftUI

// Aviso de reunión en el notch cerrado: a la izquierda un icono con el color del calendario del evento
// (cámara si tiene videollamada), a la derecha cuánto falta, y debajo el título.

/// Lado izquierdo. Al empezar el evento el icono late; antes, solo "rebota" al aparecer.
struct MeetingGlyph: View {
    let alert: MeetingAlert
    @State private var arrived = false

    var body: some View {
        Image(systemName: alert.event.hasVideo ? "video.fill" : "calendar")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(alert.event.tint)
            .symbolEffect(.bounce, options: .nonRepeating, value: arrived)
            .symbolEffect(.pulse, isActive: alert.kind == .now)
            .onAppear { arrived = true }
    }
}

/// Lado derecho: "5 min" o "Ahora".
struct MeetingCountdown: View {
    let alert: MeetingAlert

    var body: some View {
        Group {
            switch alert.kind {
            case .soon(let minutes):
                Text("\(minutes) min")
                    .foregroundStyle(Color.white)
            case .now:
                Text("Ahora")
                    .foregroundStyle(alert.event.tint)
            }
        }
        .font(.system(size: 12, weight: .semibold))
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }
}

/// Línea de abajo: el título y, en gris, la hora (antes) o el sitio (al empezar).
struct MeetingPeek: View {
    let alert: MeetingAlert

    var body: some View {
        HStack(spacing: 7) {
            Text(alert.event.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.white)
                .lineLimit(1)
                .truncationMode(.tail)
            if let detail {
                Text(detail)
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(Color.white.opacity(0.5))
                    .lineLimit(1)
                    .fixedSize()
            }
        }
    }

    private var detail: String? {
        switch alert.kind {
        case .soon:
            return alert.event.start.formatted(date: .omitted, time: .shortened)
        case .now:
            return alert.event.hasVideo ? "Videollamada" : alert.event.place
        }
    }
}
