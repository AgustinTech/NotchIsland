import SwiftUI

/// Color del temporizador según el modo y el tramo (enfoque, descanso…).
extension TimerModel {
    var tint: Color {
        switch mode {
        case .timer: return Color(red: 1.0, green: 0.62, blue: 0.1)
        case .pomodoro: return segment.isBreak ? Color.green : Color(red: 1.0, green: 0.36, blue: 0.3)
        case .stopwatch: return Color.cyan
        }
    }
}

enum TimerFormat {
    /// "5:00", "25:00" o "1:05:00".
    static func clock(_ seconds: Int) -> String {
        let s = max(0, seconds)
        if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) }
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Refresca su contenido cada segundo SOLO mientras el contador corre; parado o en pausa no hay nada vivo.
struct TimerTicker<Content: View>: View {
    @ObservedObject var model: TimerModel
    @ViewBuilder var content: (TimerReading) -> Content

    var body: some View {
        if model.phase == .running {
            TimelineView(.periodic(from: Date(), by: 1)) { context in
                content(model.reading(at: context.date))
            }
        } else {
            content(model.reading(at: Date()))
        }
    }
}

// MARK: - Notch cerrado

/// Anillo pequeño de la izquierda (lo que queda; en pausa se atenúa y enseña el símbolo de pausa).
struct TimerGlyph: View {
    @ObservedObject var timer: TimerModel

    var body: some View {
        TimerTicker(model: timer) { reading in
            ZStack {
                Circle().stroke(Color.white.opacity(0.16), lineWidth: 2.4)
                Circle()
                    .trim(from: 0, to: max(0.03, reading.fraction))
                    .stroke(timer.tint, style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.9), value: reading.fraction)
                Image(systemName: timer.phase == .paused ? "pause.fill" : (timer.mode == .stopwatch ? "stopwatch.fill" : "timer"))
                    .font(.system(size: 8.5, weight: .heavy))
                    .foregroundStyle(Color.white.opacity(timer.phase == .paused ? 0.7 : 1))
            }
            .frame(width: 22, height: 22)
            .opacity(timer.phase == .paused ? 0.75 : 1)
        }
    }
}

/// Tiempo restante (o transcurrido) a la derecha.
struct TimerTrailing: View {
    @ObservedObject var timer: TimerModel

    var body: some View {
        TimerTicker(model: timer) { reading in
            Text(TimerFormat.clock(reading.seconds))
                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(timer.phase == .paused ? Color.white.opacity(0.6) : Color.white)
        }
    }
}

struct TimerPeek: View {
    @ObservedObject var timer: TimerModel

    var body: some View {
        HStack(spacing: 6) {
            Text(timer.label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.white)
            Text(timer.phase == .paused ? "En pausa" : (timer.mode == .stopwatch ? "En marcha" : "Quedan"))
                .font(.system(size: 11))
                .foregroundStyle(Color.white.opacity(0.55))
        }
        .lineLimit(1)
    }
}

/// Aviso al terminar.
struct TimerDoneGlyph: View {
    var body: some View {
        Group {
            if #available(macOS 15, *) {
                Image(systemName: "bell.fill")
                    .symbolEffect(.bounce)
            } else {
                Image(systemName: "bell.fill")
            }
        }
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(Color.orange)
    }
}

struct TimerDonePeek: View {
    var title: String

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.white)
            .lineLimit(1)
    }
}
