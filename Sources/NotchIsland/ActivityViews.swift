import AppKit
import SwiftUI

/// Azul de AirDrop y de las descargas (el del sistema, un poco más claro para fondo negro).
let activityAzure = Color(red: 0.30, green: 0.63, blue: 1.0)

// MARK: - Anillo de progreso (lado izquierdo)

struct ActivityRing: View {
    /// `nil` = el servidor no dice el tamaño: gira en vez de llenarse.
    var fraction: Double?
    var done = false

    private let line: CGFloat = 2.4

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.16), lineWidth: line)

            if done {
                Circle()
                    .stroke(Color.green, style: StrokeStyle(lineWidth: line, lineCap: .round))
                    .transition(.opacity)
            } else if let fraction {
                Circle()
                    .trim(from: 0, to: max(0.04, fraction))
                    .stroke(activityAzure, style: StrokeStyle(lineWidth: line, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .transition(.opacity)
            } else {
                IndeterminateArc()
                    .transition(.opacity)
            }

            Image(systemName: done ? "checkmark" : "arrow.down")
                .font(.system(size: 8.5, weight: .heavy))
                .foregroundStyle(done ? Color.green : Color.white)
                .contentTransition(.symbolEffect(.replace))
        }
        .frame(width: 22, height: 22)
        .animation(.linear(duration: 1), value: fraction)
        .animation(.spring(response: 0.4, dampingFraction: 0.75), value: done)
        .animation(.easeInOut(duration: 0.25), value: fraction == nil)
    }
}

/// Arco que gira. Solo se anima mientras está en pantalla (una descarga sin tamaño conocido).
private struct IndeterminateArc: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Circle()
                .trim(from: 0, to: 0.3)
                .stroke(activityAzure, style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
                .rotationEffect(.degrees(t * 300))
        }
    }
}

// MARK: - Lado derecho

/// Porcentaje, o los megas recibidos si no se conoce el total.
struct DownloadTrailing: View {
    let summary: DownloadSummary

    var body: some View {
        Group {
            if let fraction = summary.fraction {
                Text("\(Int((fraction * 100).rounded()))%")
                    .font(.system(size: 12, weight: .semibold))
            } else {
                Text(ActivityFormat.bytes(summary.receivedBytes))
                    .font(.system(size: 10.5, weight: .semibold))
            }
        }
        .monospacedDigit()
        .foregroundStyle(Color.white)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .contentTransition(.numericText())
        .animation(.snappy(duration: 0.3), value: summary.fraction)
        .animation(.snappy(duration: 0.3), value: summary.receivedBytes)
    }
}

/// Icono (o miniatura) del archivo, con esquinas continuas.
struct ActivityThumbnail: View {
    let image: NSImage?
    var size: CGFloat = 22

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5)
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
            } else {
                Color.clear.frame(width: size, height: size)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: image)
    }
}

struct AirDropGlyph: View {
    var body: some View {
        Image(systemName: "airdrop")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(activityAzure)
            .symbolEffect(.variableColor.iterative, options: .repeat(2))
    }
}

// MARK: - Línea de abajo

private struct PeekText: View {
    let text: String
    var weight: Font.Weight = .semibold
    var color = Color.white

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: weight))
            .foregroundStyle(color)
            .lineLimit(1)
            .truncationMode(.middle)
    }
}

struct DownloadPeek: View {
    let summary: DownloadSummary

    var body: some View {
        HStack(spacing: 7) {
            PeekText(text: summary.title)
            if let speed = ActivityFormat.speed(summary.bytesPerSecond) {
                Text(speed)
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(Color.white.opacity(0.5))
                    .lineLimit(1)
                    .fixedSize()
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.25), value: ActivityFormat.speed(summary.bytesPerSecond) == nil)
    }
}

struct DownloadDonePeek: View {
    let count: Int
    let name: String

    var body: some View {
        HStack(spacing: 7) {
            Text(count > 1 ? "\(count) descargas completadas" : "Descarga completada")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.white)
                .lineLimit(1)
                .fixedSize()
            if count == 1 {
                PeekText(text: name, weight: .regular, color: Color.white.opacity(0.5))
            }
        }
    }
}

struct AirDropPeek: View {
    let count: Int
    let name: String

    var body: some View {
        HStack(spacing: 7) {
            Text("AirDrop")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(activityAzure)
                .fixedSize()
            PeekText(text: count > 1 ? "\(count) archivos" : name, weight: .medium, color: Color.white.opacity(0.9))
        }
    }
}
