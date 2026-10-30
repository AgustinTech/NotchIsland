import AppKit
import SwiftUI

// MARK: - Filtros

enum ClipFilter: String, CaseIterable, Identifiable {
    case all, text, links, images, files

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "Todo"
        case .text: return "Texto"
        case .links: return "Enlaces"
        case .images: return "Imágenes"
        case .files: return "Archivos"
        }
    }

    var symbol: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .text: return "text.alignleft"
        case .links: return "link"
        case .images: return "photo"
        case .files: return "doc"
        }
    }

    var emptyTitle: String {
        switch self {
        case .all: return "Nada copiado todavía"
        case .text: return "Sin textos"
        case .links: return "Sin enlaces"
        case .images: return "Sin imágenes"
        case .files: return "Sin archivos"
        }
    }

    func matches(_ item: ClipItem) -> Bool {
        switch self {
        case .all: return true
        case .text: return item.kind == .text
        case .links: return item.kind == .link
        case .images: return item.kind == .image
        case .files: return item.kind == .files
        }
    }
}

// MARK: - Pestaña

struct ClipboardTab: View {
    @ObservedObject var model: ClipboardModel
    /// La isla está abierta (la pestaña sigue montada un instante tras cerrar).
    var expanded = true

    @State private var filter: ClipFilter = .all
    @State private var confirmClear = false
    @State private var scrolledID: UUID?
    @Namespace private var chipSpace

    private let spring = Animation.spring(response: 0.38, dampingFraction: 0.82)

    private var visible: [ClipItem] {
        model.items.filter(filter.matches)
    }

    var body: some View {
        VStack(spacing: 8) {
            header

            ZStack {
                if visible.isEmpty {
                    emptyState
                        .transition(.opacity)
                } else {
                    carousel
                        .padding(.horizontal, -22)   // las tarjetas se deslizan hasta el borde de la isla
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .animation(spring, value: visible.isEmpty)
    }

    // MARK: Cabecera

    private var header: some View {
        HStack(spacing: 6) {
            if model.items.isEmpty {
                Text("Portapapeles")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.6))
                    .transition(.opacity)
            } else {
                HStack(spacing: 1) {
                    ForEach(ClipFilter.allCases) { chip($0) }
                }
                .transition(.opacity)
            }

            Spacer(minLength: 8)

            if model.capturing {
                if !visible.isEmpty {
                    Text("\(visible.count) \(visible.count == 1 ? "elemento" : "elementos")")
                        .font(.system(size: 10.5, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(Color.white.opacity(0.4))
                        .contentTransition(.numericText())
                }
            } else {
                Text("En pausa")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Color.orange)
            }

            if visible.contains(where: { !$0.pinned }) {
                clearPill
            }

            pauseButton
        }
        .frame(height: 22)
        .animation(spring, value: model.items.isEmpty)
        .animation(spring, value: model.capturing)
        .animation(spring, value: visible.contains(where: { !$0.pinned }))
    }

    private func chip(_ option: ClipFilter) -> some View {
        let selected = filter == option
        return Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.78)) {
                filter = option
                scrolledID = nil
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: option.symbol)
                if selected {
                    Text(option.title)
                        .transition(.opacity.combined(with: .scale(scale: 0.7, anchor: .leading)))
                }
            }
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(Color.white.opacity(selected ? 1 : 0.45))
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background {
                if selected {
                    Capsule()
                        .fill(Color.white.opacity(0.18))
                        .matchedGeometryEffect(id: "chip", in: chipSpace)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(ScaleButtonStyle())
        .help(option.title)
    }

    private var clearPill: some View {
        Button {
            if confirmClear {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    model.clear(visible)
                    confirmClear = false
                }
            } else {
                withAnimation(spring) { confirmClear = true }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "trash")
                Text(confirmClear ? "¿Seguro?" : "Vaciar")
                    .contentTransition(.interpolate)
            }
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(confirmClear ? Color(red: 1, green: 0.45, blue: 0.42) : Color.white.opacity(0.9))
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(
                Capsule().fill(confirmClear ? Color.red.opacity(0.22) : Color.white.opacity(0.12))
            )
        }
        .buttonStyle(ScaleButtonStyle())
        .transition(.scale(scale: 0.8).combined(with: .opacity))
        // Vuelve a "Vaciar" si no se confirma en un par de segundos.
        .task(id: confirmClear) {
            guard confirmClear else { return }
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if !Task.isCancelled { withAnimation(spring) { confirmClear = false } }
        }
    }

    private var pauseButton: some View {
        Button {
            withAnimation(spring) { model.setCapturing(!model.capturing) }
        } label: {
            Image(systemName: model.capturing ? "pause.fill" : "play.fill")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(model.capturing ? Color.white.opacity(0.7) : Color.orange)
                .frame(width: 22, height: 22)
                .background(Circle().fill(model.capturing ? Color.white.opacity(0.1) : Color.orange.opacity(0.2)))
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(ScaleButtonStyle())
        .help(model.capturing ? "Pausar el historial" : "Reanudar el historial")
    }

    // MARK: Carrusel

    private var carousel: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 8) {
                ForEach(visible) { item in
                    ClipCard(model: model, item: item)
                        .transition(
                            .asymmetric(
                                insertion: .scale(scale: 0.8).combined(with: .opacity),
                                removal: .scale(scale: 0.6).combined(with: .opacity)
                            )
                        )
                }
            }
            .scrollTargetLayout()
            .animation(spring, value: visible.map(\.id))
        }
        .contentMargins(.horizontal, 22, for: .scrollContent)
        .scrollTargetBehavior(.viewAligned)
        .scrollPosition(id: $scrolledID)
        .frame(height: ClipCard.size.height)
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.035),
                    .init(color: .black, location: 0.965),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        )
        // Algo nuevo copiado: el carrusel vuelve al principio para que se vea.
        .onChange(of: visible.first?.id) { _, id in
            withAnimation(spring) { scrolledID = id }
        }
    }

    // MARK: Estados vacíos

    @ViewBuilder
    private var emptyState: some View {
        if model.blocked {
            ClipEmptyState(
                symbol: "lock.fill",
                title: "macOS no deja leer el portapapeles",
                subtitle: "Actívalo en Ajustes > Privacidad > Pegar desde otras apps",
                buttonTitle: "Abrir Ajustes"
            ) {
                if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension") {
                    NSWorkspace.shared.open(url)
                }
            }
        } else if model.items.isEmpty && !model.capturing {
            ClipEmptyState(
                symbol: "pause.circle",
                title: "Historial en pausa",
                subtitle: "Ahora mismo no se guarda lo que copias",
                buttonTitle: "Reanudar"
            ) {
                withAnimation(spring) { model.setCapturing(true) }
            }
        } else if model.items.isEmpty {
            ClipEmptyState(
                symbol: "doc.on.clipboard",
                title: ClipFilter.all.emptyTitle,
                subtitle: "Lo que copies y tus capturas aparecerán aquí"
            )
        } else {
            ClipEmptyState(
                symbol: filter.symbol,
                title: filter.emptyTitle,
                subtitle: "Prueba con otro filtro"
            )
        }
    }
}
