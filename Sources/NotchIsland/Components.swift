import AppKit
import CoreImage
import SwiftUI

// MARK: - Botón con efecto de pulsación

struct ScaleButtonStyle: ButtonStyle {
    var pressed: CGFloat = 0.86

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? pressed : 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

// MARK: - Transición con desenfoque

struct BlurFade: ViewModifier {
    var radius: CGFloat
    func body(content: Content) -> some View {
        content.blur(radius: radius)
    }
}

extension AnyTransition {
    static var blurFade: AnyTransition {
        .modifier(active: BlurFade(radius: 5), identity: BlurFade(radius: 0))
    }
}

// MARK: - Tarjeta para la pestaña "Hoy"

struct Card<Content: View>: View {
    let title: String
    let symbol: String
    var tint: Color = .white
    let content: Content

    init(title: String, symbol: String, tint: Color = .white, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.tint = tint
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .foregroundStyle(tint)
                Text(title.uppercased())
                    .foregroundStyle(Color.white.opacity(0.45))
            }
            .font(.system(size: 9.5, weight: .bold))
            .tracking(0.4)

            content

            Spacer(minLength: 0)
        }
        .padding(11)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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

// MARK: - Visualizador de audio (animado, no es un análisis real del sonido)

struct Visualizer: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var color: Color
    var active: Bool
    var bars = 5
    var maxHeight: CGFloat = 16
    var barWidth: CGFloat = 3

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !active || reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: barWidth * 0.75) {
                ForEach(0..<bars, id: \.self) { i in
                    let p = Double(i)
                    let wave = (sin(t * (2.6 + p * 0.7) + p * 1.9) + sin(t * (4.1 + p * 0.4) + p * 0.6)) / 4 + 0.5
                    let level = active ? (reduceMotion ? 0.55 : 0.18 + 0.82 * wave) : 0.14
                    Capsule()
                        .fill(color)
                        .frame(width: barWidth, height: max(barWidth, maxHeight * level))
                }
            }
            .frame(height: maxHeight)
        }
        .animation(.easeOut(duration: 0.3), value: active)
    }
}

// MARK: - Slider fino (volumen)

struct MiniSlider: View {
    @Binding var value: Double
    var tint: Color = .white
    var onEnd: () -> Void = {}

    @State private var hover = false
    @State private var dragging = false

    var body: some View {
        GeometryReader { geo in
            let h: CGFloat = (hover || dragging) ? 7 : 4
            let width = max(geo.size.width, 1)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.18)).frame(height: h)
                Capsule().fill(tint).frame(width: max(h, width * CGFloat(value)), height: h)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        dragging = true
                        value = Double(min(max(drag.location.x / width, 0), 1))
                    }
                    .onEnded { _ in
                        dragging = false
                        onEnd()
                    }
            )
        }
        .frame(height: 16)
        .onHover { hover = $0 }
        .animation(.spring(response: 0.25, dampingFraction: 0.75), value: hover)
        .animation(.spring(response: 0.25, dampingFraction: 0.75), value: dragging)
        .focusable()
        .onMoveCommand { direction in
            switch direction {
            case .left: adjust(by: -0.05)
            case .right: adjust(by: 0.05)
            default: break
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Volumen")
        .accessibilityValue("\(Int((value * 100).rounded())) por ciento")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: adjust(by: 0.05)
            case .decrement: adjust(by: -0.05)
            @unknown default: break
            }
        }
    }

    private func adjust(by amount: Double) {
        value = min(max(value + amount, 0), 1)
        onEnd()
    }
}

// MARK: - Batería

struct BatteryGlyph: View {
    let percent: Int
    let charging: Bool

    private var fill: Color {
        if charging { return Color.green }
        if percent <= 20 { return Color.red }
        return Color.white
    }

    var body: some View {
        HStack(spacing: 1) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.45), lineWidth: 1)
                    .frame(width: 22, height: 11)
                RoundedRectangle(cornerRadius: 1.8, style: .continuous)
                    .fill(fill)
                    .frame(width: max(2, 18 * CGFloat(percent) / 100), height: 7)
                    .padding(.leading, 2)
            }
            Capsule()
                .fill(Color.white.opacity(0.45))
                .frame(width: 1.5, height: 4)
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: percent)
    }
}

struct BatteryBadge: View {
    @ObservedObject var power: PowerModel

    var body: some View {
        HStack(spacing: 5) {
            if power.onAC {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.green)
                    .transition(.scale.combined(with: .opacity))
            }
            Text("\(power.percent)%")
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(Color.white.opacity(0.85))
                .contentTransition(.numericText())
            BatteryGlyph(percent: power.percent, charging: power.onAC)
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: power.onAC)
        .animation(.default, value: power.percent)
    }
}

// MARK: - Color dominante de la carátula

extension NSImage {
    /// Color medio de la imagen, subido de brillo y saturación para usarlo como acento.
    func dominantAccent() -> Color? {
        guard let cg = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }

        let pixel = UnsafeMutablePointer<UInt8>.allocate(capacity: 4)
        pixel.initialize(repeating: 0, count: 4)
        defer { pixel.deallocate() }

        guard let context = CGContext(
            data: pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.interpolationQuality = .medium
        context.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))

        let r = CGFloat(pixel[0]) / 255
        let g = CGFloat(pixel[1]) / 255
        let b = CGFloat(pixel[2]) / 255

        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
            .getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)

        let boosted = NSColor(
            hue: hue,
            saturation: min(1, saturation * 1.25),
            brightness: max(brightness, 0.78),
            alpha: 1
        )
        return Color(nsColor: boosted)
    }
}

extension NSImage {
    /// Copia reducida a `side` x `side` píxeles.
    func tiny(side: Int) -> NSImage? {
        guard let cg = cgImage(forProposedRect: nil, context: nil, hints: nil),
              let context = CGContext(
                data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        context.interpolationQuality = .high
        context.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let small = context.makeImage() else { return nil }
        return NSImage(cgImage: small, size: NSSize(width: side, height: side))
    }
}

extension NSImage {
    /// Carátula reducida, desenfocada y con más saturación: sirve de fondo suave (como en Apple Music)
    /// sin tener que aplicar filtros en cada fotograma.
    func softBackdrop(side: Int = 48) -> NSImage? {
        guard let small = tiny(side: side),
              let cg = small.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let input = CIImage(cgImage: cg)
        let blurred = input.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 3.0])
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.7, kCIInputBrightnessKey: 0.02, kCIInputContrastKey: 1.05])
            .cropped(to: input.extent)
        guard let output = CIContext().createCGImage(blurred, from: input.extent) else { return nil }
        return NSImage(cgImage: output, size: NSSize(width: side, height: side))
    }
}

extension NSImage {
    /// Luminosidad media (0 oscuro … 1 claro).
    func averageLuma() -> Double {
        guard let cg = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return 0.4 }
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return 0.4 }
        context.interpolationQuality = .medium
        context.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (0.299 * Double(pixel[0]) + 0.587 * Double(pixel[1]) + 0.114 * Double(pixel[2])) / 255
    }
}
