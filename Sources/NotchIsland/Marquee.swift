import SwiftUI

/// Texto de una sola línea que, si no cabe en el ancho disponible, no se encoge ni se corta con
/// puntos suspensivos:
/// - `scrolls == true` (la línea activa): espera un momento, arranca con suavidad, recorre el texto con
///   calma, se detiene al final y vuelve; con un degradado en los bordes por donde el texto se sale.
/// - `scrolls == false`: se queda quieta y se difumina por el borde derecho.
/// Si el texto cabe es un `Text` normal: ni animaciones ni temporizadores. Con "Reducir movimiento"
/// tampoco se desplaza.
struct MarqueeText: View {
    let text: String
    let font: Font
    let color: Color
    var scrolls = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var textWidth: CGFloat = 0
    @State private var offset: CGFloat = 0

    /// Puntos por segundo, pausa antes de arrancar y al llegar al final, y vuelta al principio.
    private static let speed: Double = 36
    private static let lead: Double = 0.9
    private static let hold: Double = 1.5
    private static let rewind: Double = 1.0
    /// Hueco entre la última letra y el borde derecho al llegar al final.
    private static let tail: CGFloat = 6

    var body: some View {
        GeometryReader { box in
            let overflow = max(0, textWidth - box.size.width)
            let travel = overflow > 0.5 ? overflow + Self.tail : 0
            let moves = scrolls && !reduceMotion

            Text(text)
                .font(font)
                .foregroundStyle(color)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .background(
                    GeometryReader { Color.clear.preference(key: MarqueeWidthKey.self, value: $0.size.width) }
                )
                .onPreferenceChange(MarqueeWidthKey.self) { textWidth = $0 }
                .modifier(MarqueeEffect(x: offset, overflow: overflow, size: box.size))
                .task(id: MarqueeRun(text: text, moves: moves, travel: Int(travel.rounded()))) {
                    await run(travel: travel, moves: moves)
                }
        }
    }

    @MainActor
    private func run(travel: CGFloat, moves: Bool) async {
        var reset = Transaction()
        reset.disablesAnimations = true
        withTransaction(reset) { offset = 0 }
        guard moves, travel > 0 else { return }

        let move = max(1.4, Double(travel) / Self.speed)
        try? await Task.sleep(nanoseconds: Self.nanoseconds(Self.lead))
        while !Task.isCancelled {
            withAnimation(.timingCurve(0.42, 0, 0.3, 1, duration: move)) { offset = -travel }
            try? await Task.sleep(nanoseconds: Self.nanoseconds(move + Self.hold))
            guard !Task.isCancelled else { return }
            withAnimation(.timingCurve(0.42, 0, 0.3, 1, duration: Self.rewind)) { offset = 0 }
            try? await Task.sleep(nanoseconds: Self.nanoseconds(Self.rewind + Self.lead))
        }
    }

    private static func nanoseconds(_ seconds: Double) -> UInt64 {
        UInt64(max(0, seconds) * 1_000_000_000)
    }
}

private struct MarqueeWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct MarqueeRun: Hashable {
    let text: String
    let moves: Bool
    let travel: Int
}

/// Desplaza el texto y lo recorta al ancho de la caja, difuminando los bordes por los que aún hay texto
/// oculto. Es animable: SwiftUI la evalúa en cada fotograma con el desplazamiento intermedio, así el
/// degradado crece y se encoge exactamente a la vez que el texto se mueve.
private struct MarqueeEffect: ViewModifier, Animatable {
    var x: CGFloat
    let overflow: CGFloat
    let size: CGSize

    private static let fade: CGFloat = 14

    var animatableData: CGFloat {
        get { x }
        set { x = newValue }
    }

    func body(content: Content) -> some View {
        let width = max(size.width, 1)
        let left = min(Self.fade, max(0, -x)) / width
        let right = min(Self.fade, max(0, overflow + x)) / width

        content
            .offset(x: x)
            .frame(width: size.width, height: size.height, alignment: .leading)
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: Color.black.opacity(0), location: 0),
                        .init(color: Color.black, location: left),
                        .init(color: Color.black, location: 1 - right),
                        .init(color: Color.black.opacity(0), location: 1)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
    }
}
