import AppKit
import QuickLookThumbnailing
import SwiftUI

struct TrayTab: View {
    @ObservedObject var state: IslandState

    var body: some View {
        VStack(spacing: 6) {
            header

            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white.opacity(state.dropTargeted ? 0.14 : 0.05))

                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(
                        Color.white.opacity(state.dropTargeted ? 0.9 : 0.18),
                        style: StrokeStyle(lineWidth: state.dropTargeted ? 1.6 : 1.1, dash: [6, 5])
                    )

                if state.files.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "tray.and.arrow.down.fill")
                            .font(.system(size: 22))
                            .symbolEffect(.bounce, value: state.dropTargeted)
                        Text(state.dropTargeted ? "Suéltalo aquí" : "Arrastra archivos para llevarlos contigo")
                            .font(.system(size: 11.5, weight: .medium))
                            .contentTransition(.opacity)
                    }
                    .foregroundStyle(Color.white.opacity(state.dropTargeted ? 0.9 : 0.5))
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(state.files, id: \.self) { url in
                                FileChip(url: url) {
                                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                        state.files.removeAll { $0 == url }
                                    }
                                }
                                .transition(.scale(scale: 0.5).combined(with: .opacity))
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .frame(maxHeight: .infinity)
                    }
                }
            }
            .frame(maxHeight: .infinity)
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: state.dropTargeted)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(state.files.isEmpty ? "Bandeja" : "\(state.files.count) \(state.files.count == 1 ? "archivo" : "archivos")")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.6))
                .contentTransition(.numericText())

            Spacer()

            pill("Añadir", symbol: "plus") { chooseFiles() }

            if !state.files.isEmpty {
                pill("AirDrop", symbol: "dot.radiowaves.left.and.right") { airDrop() }
                pill("Compartir", symbol: "square.and.arrow.up") { share() }
                pill("Vaciar", symbol: "trash") {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                        state.files.removeAll()
                    }
                }
            }
        }
        .frame(height: 22)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: state.files.isEmpty)
    }

    private func pill(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                Text(title)
            }
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(Color.white.opacity(0.9))
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(Capsule().fill(Color.white.opacity(0.12)))
        }
        .buttonStyle(ScaleButtonStyle())
        .transition(.scale(scale: 0.8).combined(with: .opacity))
    }

    private func airDrop() {
        let urls = state.files
        guard let service = NSSharingService(named: .sendViaAirDrop),
              service.canPerform(withItems: urls) else { return }
        service.perform(withItems: urls)
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Añadir a la bandeja"
        state.pinned = true
        // La isla no activa la app: sin esto el diálogo saldría detrás de las demás ventanas.
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { result in
            if result == .OK { state.addFiles(panel.urls) }
            state.pinned = false
            NSApp.deactivate()   // devuelve el foco a la app que estabas usando
        }
    }

    private func share() {
        SharePresenter.present(state.files, state: state)
    }
}

struct FileChip: View {
    let url: URL
    let onRemove: () -> Void

    @State private var thumb: NSImage?
    @State private var hover = false

    var body: some View {
        VStack(spacing: 5) {
            ZStack(alignment: .topTrailing) {
                Image(nsImage: thumb ?? NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 44, height: 44)
                    .shadow(color: Color.black.opacity(0.35), radius: 4, y: 2)

                if hover {
                    Button(action: onRemove) {
                        Image(systemName: "xmark.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(Color.white, Color.black.opacity(0.75))
                            .font(.system(size: 17))
                    }
                    .buttonStyle(ScaleButtonStyle())
                    .offset(x: 7, y: -7)
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
                }
            }
            .frame(width: 50, height: 48)

            Text(url.lastPathComponent)
                .font(.system(size: 10))
                .foregroundStyle(Color.white.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 66)
        }
        .scaleEffect(hover ? 1.07 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.65), value: hover)
        .onHover { hover = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(url.lastPathComponent)
        .accessibilityHint("Doble clic para abrir. Hay más acciones en el menú contextual.")
        .accessibilityAction(named: "Abrir") { NSWorkspace.shared.open(url) }
        .accessibilityAction(named: "Quitar de la bandeja", onRemove)
        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
        .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
        .contextMenu {
            Button("Abrir") { NSWorkspace.shared.open(url) }
            Button("Mostrar en Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            Divider()
            Button("Quitar de la bandeja", action: onRemove)
        }
        .task(id: url) { thumb = await Self.thumbnail(for: url) }
    }

    private static func thumbnail(for url: URL) async -> NSImage? {
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: 64, height: 64),
            scale: 2,
            representationTypes: .thumbnail
        )
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
    }
}
