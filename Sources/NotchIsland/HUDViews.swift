import SwiftUI

/// Barra fina del HUD de volumen y brillo (debajo del notch).
struct HUDBar: View {
    var level: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.22))
                Capsule()
                    .fill(Color.white)
                    .frame(width: max(5, geometry.size.width * CGFloat(min(max(level, 0), 1))))
            }
        }
        .frame(height: 5)
        .animation(.spring(response: 0.22, dampingFraction: 0.85), value: level)
    }
}

/// Porcentaje a la derecha del notch.
struct HUDPercent: View {
    var level: Double

    var body: some View {
        Text("\(Int((min(max(level, 0), 1) * 100).rounded()))%")
            .font(.system(size: 12, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(Color.white)
            .contentTransition(.numericText())
            .animation(.easeOut(duration: 0.15), value: level)
    }
}

/// Icono de la izquierda: altavoz con ondas que crecen con el volumen, o sol.
struct HUDGlyph: View {
    enum Kind: Equatable {
        case volume(level: Double, muted: Bool)
        case brightness(level: Double)
    }

    var kind: Kind

    var body: some View {
        switch kind {
        case .volume(let level, let muted):
            Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.3.fill", variableValue: muted ? nil : level)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.white)
                .contentTransition(.symbolEffect(.replace))
        case .brightness(let level):
            Image(systemName: "sun.max.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.55 + 0.45 * level))
                .symbolEffect(.bounce, value: level >= 0.999)
        }
    }
}

/// Con la isla abierta el HUD sale como una pastilla en la parte de abajo.
struct HUDPill: View {
    var kind: HUDGlyph.Kind

    private var level: Double {
        switch kind {
        case .volume(let level, let muted): return muted ? 0 : level
        case .brightness(let level): return level
        }
    }

    var body: some View {
        HStack(spacing: 9) {
            HUDGlyph(kind: kind)
                .frame(width: 22)
            HUDBar(level: level)
                .frame(width: 110)
            HUDPercent(level: level)
                .frame(width: 38, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
        .background(
            Capsule()
                .fill(Color.black.opacity(0.78))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 0.6))
        )
        .shadow(color: Color.black.opacity(0.4), radius: 10, y: 4)
    }
}
