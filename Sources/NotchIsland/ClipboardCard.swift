import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Apps de origen (icono y color de acento, en caché)

enum ClipSource {
    private static var icons: [String: NSImage] = [:]
    private static var accents: [String: Color] = [:]

    static func icon(_ bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        if let cached = icons[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        icons[bundleID] = image
        return image
    }

    static func accent(_ bundleID: String?) -> Color? {
        guard let bundleID else { return nil }
        if let cached = accents[bundleID] { return cached }
        guard let color = icon(bundleID)?.dominantAccent() else { return nil }
        accents[bundleID] = color
        return color
    }
}

// MARK: - Tiempo relativo, corto

enum ClipTime {
    static func short(_ date: Date, now: Date) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 45 { return "ahora" }
        if seconds < 3600 { return "\(max(1, Int(seconds / 60))) min" }
        if seconds < 86_400 { return "\(Int(seconds / 3600)) h" }
        if Calendar.current.isDateInYesterday(date) { return "ayer" }
        let days = Int(seconds / 86_400)
        if days < 7 { return "\(days) d" }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }
}

// MARK: - Cómo se muestra cada elemento

extension ClipItem {
    /// Color si el texto es un código hexadecimal (#RGB, #RRGGBB o #RRGGBBAA).
    var swatch: Color? {
        guard kind == .text, let text, text.count <= 10 else { return nil }
        let hex = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hex.hasPrefix("#"), [4, 7, 9].contains(hex.count) else { return nil }
        let digits = hex.dropFirst()
        guard digits.allSatisfy(\.isHexDigit) else { return nil }

        var value: UInt64 = 0
        Scanner(string: String(digits)).scanHexInt64(&value)
        let r, g, b, a: Double
        switch digits.count {
        case 3:
            r = Double((value >> 8) & 0xF) / 15
            g = Double((value >> 4) & 0xF) / 15
            b = Double(value & 0xF) / 15
            a = 1
        case 6:
            r = Double((value >> 16) & 0xFF) / 255
            g = Double((value >> 8) & 0xFF) / 255
            b = Double(value & 0xFF) / 255
            a = 1
        default:
            r = Double((value >> 24) & 0xFF) / 255
            g = Double((value >> 16) & 0xFF) / 255
            b = Double((value >> 8) & 0xFF) / 255
            a = Double(value & 0xFF) / 255
        }
        return Color(.sRGB, red: r, green: g, blue: b, opacity: a)
    }

    /// Texto negro o blanco, el que mejor se lea sobre el color.
    var swatchInk: Color {
        guard let text else { return .white }
        let digits = String(text.trimmingCharacters(in: .whitespacesAndNewlines).dropFirst())
        var value: UInt64 = 0
        Scanner(string: digits).scanHexInt64(&value)
        let r, g, b: Double
        switch digits.count {
        case 3:
            r = Double((value >> 8) & 0xF) / 15; g = Double((value >> 4) & 0xF) / 15; b = Double(value & 0xF) / 15
        case 6:
            r = Double((value >> 16) & 0xFF) / 255; g = Double((value >> 8) & 0xFF) / 255; b = Double(value & 0xFF) / 255
        default:
            r = Double((value >> 24) & 0xFF) / 255; g = Double((value >> 16) & 0xFF) / 255; b = Double((value >> 8) & 0xFF) / 255
        }
        return (0.299 * r + 0.587 * g + 0.114 * b) > 0.62 ? Color.black.opacity(0.78) : Color.white
    }

    /// ¿Parece código, un comando o una ruta? Entonces se muestra con tipografía monoespaciada.
    var looksLikeCode: Bool {
        guard kind == .text, let text else { return false }
        let sample = String(text.prefix(400))
        let firstLine = sample.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""

        let commands = ["sudo ", "git ", "npm ", "cd ", "ls ", "brew ", "pip ", "swift ", "curl ", "docker ",
                        "python ", "yarn ", "cargo ", "ssh ", "mkdir ", "$ ", "./"]
        if commands.contains(where: { firstLine.hasPrefix($0) }) { return true }
        if firstLine.hasPrefix("/") || firstLine.hasPrefix("~/") { return !firstLine.contains(" ") }

        let punctuation = ["{", "}", ";", "=>", "->", "</", "/>", "()", "::", "&&", "||", "=="]
        let words = ["func ", "def ", "import ", "const ", "return ", "#include", "class ", "var ", "let ", "SELECT "]
        let marks = punctuation.filter { sample.contains($0) }.count
        let hits = marks + words.filter { sample.contains($0) }.count
        let indented = sample.split(separator: "\n").filter { $0.hasPrefix("  ") || $0.hasPrefix("\t") }.count >= 2
        return (marks >= 1 && hits >= 2) || marks >= 3 || (indented && hits >= 1)
    }

    /// Primeras líneas del texto, sin líneas en blanco al principio.
    var previewText: String {
        guard let text else { return "" }
        var lines = String(text.prefix(360)).replacingOccurrences(of: "\t", with: "  ")
            .components(separatedBy: .newlines)
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeFirst()
        }
        if !looksLikeCode {
            lines = lines.map { $0.trimmingCharacters(in: .whitespaces) }
        }
        return lines.prefix(6).joined(separator: "\n")
    }

    var isLongText: Bool {
        guard let text else { return false }
        return text.count > 150 || text.filter(\.isNewline).count >= 4
    }

    var host: String {
        guard let text, let url = URL(string: text) else { return "Enlace" }
        if url.scheme?.lowercased() == "mailto" { return url.path }
        let host = url.host ?? text
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// Título del enlace o, si no lo hay, su ruta.
    var linkDetail: String? {
        if let title, !title.isEmpty { return title }
        guard let text, let url = URL(string: text), url.scheme?.lowercased() != "mailto" else { return nil }
        var detail = url.path == "/" ? "" : url.path
        if let query = url.query { detail += "?" + query }
        return detail.isEmpty ? nil : detail
    }

    var footerText: String {
        switch kind {
        case .text:
            let lines = (text ?? "").split(whereSeparator: \.isNewline).count
            if lines > 1 { return "\(lines) líneas" }
            let count = (text ?? "").count
            return "\(count) \(count == 1 ? "carácter" : "caracteres")"
        case .link:
            return URL(string: text ?? "")?.scheme?.lowercased() == "mailto" ? "Correo" : "Enlace"
        case .image:
            return "\(width) × \(height)"
        case .files:
            let size = bytes > 0 ? ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) : nil
            if paths.count > 1 { return ["\(paths.count) archivos", size].compactMap { $0 }.joined(separator: " · ") }
            return size ?? "Archivo"
        }
    }

    var fileIcon: NSImage {
        let path = paths.first ?? ""
        if FileManager.default.fileExists(atPath: path) {
            return NSWorkspace.shared.icon(forFile: path)
        }
        let type = UTType(filenameExtension: URL(fileURLWithPath: path).pathExtension) ?? .data
        return NSWorkspace.shared.icon(for: type)
    }
}

// MARK: - Tarjeta del carrusel

struct ClipCard: View {
    @ObservedObject var model: ClipboardModel
    let item: ClipItem

    static let size = CGSize(width: 138, height: 100)
    private static let radius: CGFloat = 16

    @State private var hover = false
    @State private var thumb: NSImage?

    private var copied: Bool { model.copiedID == item.id }
    private var swatch: Color? { item.swatch }
    private var immersive: Bool { item.kind == .image || swatch != nil }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: Self.radius, style: .continuous) }

    var body: some View {
        ZStack(alignment: .top) {
            backdrop

            VStack(spacing: 0) {
                header
                content
                footer
            }

            if copied {
                CopiedBadge()
                    .transition(.opacity)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipShape(shape)
        .overlay(
            shape.strokeBorder(
                LinearGradient(
                    colors: [Color.white.opacity(hover ? 0.3 : 0.12), Color.white.opacity(hover ? 0.1 : 0.02)],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                lineWidth: 0.8
            )
        )
        .scaleEffect(copied ? 0.96 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: copied)
        .animation(.easeOut(duration: 0.16), value: hover)
        .contentShape(shape)
        .onHover { hover = $0 }
        .onTapGesture { model.use(item) }
        .onDrag { model.dragProvider(for: item) }
        .contextMenu {
            Button { model.use(item) } label: { Label("Copiar", systemImage: "doc.on.doc") }
            Button {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { model.togglePin(item) }
            } label: {
                Label(item.pinned ? "Quitar de fijados" : "Fijar", systemImage: item.pinned ? "pin.slash" : "pin")
            }
            Divider()
            Button(role: .destructive) {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { model.remove(item) }
            } label: {
                Label("Eliminar", systemImage: "trash")
            }
        }
        .task(id: item.imageFile) {
            guard item.kind == .image else { return }
            let image = await model.thumbnail(for: item)
            withAnimation(.easeOut(duration: 0.2)) { thumb = image }
        }
    }

    // MARK: Fondo

    @ViewBuilder
    private var backdrop: some View {
        if item.kind == .image {
            ZStack {
                Color.white.opacity(0.07)
                if let thumb {
                    Image(nsImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: Self.size.width, height: Self.size.height)
                        .clipped()
                        .transition(.opacity)
                }
                scrims
            }
        } else if let swatch {
            ZStack {
                Color.black
                swatch
                scrims
            }
        } else {
            ZStack(alignment: .top) {
                Color.white.opacity(hover ? 0.11 : 0.07)
                if let accent = ClipSource.accent(item.sourceBundleID) {
                    LinearGradient(
                        colors: [accent.opacity(0.34), accent.opacity(0)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 32)
                }
            }
        }
    }

    /// Degradados para que la cabecera y el pie se lean sobre imágenes y colores.
    private var scrims: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [Color.black.opacity(0.55), Color.black.opacity(0)], startPoint: .top, endPoint: .bottom)
                .frame(height: 36)
            Spacer(minLength: 0)
            if item.kind == .image {
                LinearGradient(colors: [Color.black.opacity(0), Color.black.opacity(0.5)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 30)
            }
        }
    }

    // MARK: Cabecera

    private var header: some View {
        HStack(spacing: 5) {
            sourceIcon
            Text(item.sourceName ?? "Desconocido")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.white.opacity(immersive ? 0.95 : 0.8))
                .lineLimit(1)

            Spacer(minLength: 2)

            if hover {
                HStack(spacing: 3) {
                    miniButton(item.pinned ? "pin.slash.fill" : "pin.fill", help: item.pinned ? "Quitar de fijados" : "Fijar") {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { model.togglePin(item) }
                    }
                    miniButton("trash.fill", tint: Color(red: 1, green: 0.42, blue: 0.4), help: "Eliminar") {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { model.remove(item) }
                    }
                }
                .transition(.scale(scale: 0.7, anchor: .trailing).combined(with: .opacity))
            } else {
                HStack(spacing: 4) {
                    if item.pinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundStyle(Color.orange)
                            .rotationEffect(.degrees(35))
                    }
                    TimelineView(.periodic(from: Date(), by: 20)) { context in
                        Text(ClipTime.short(item.date, now: context.date))
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(Color.white.opacity(immersive ? 0.8 : 0.45))
                            .lineLimit(1)
                    }
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 26)
        .shadow(color: Color.black.opacity(immersive ? 0.4 : 0), radius: 2, y: 1)
    }

    @ViewBuilder
    private var sourceIcon: some View {
        if let icon = ClipSource.icon(item.sourceBundleID) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 15, height: 15)
        } else {
            Image(systemName: sourceSymbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.6))
                .frame(width: 15, height: 15)
        }
    }

    private var sourceSymbol: String {
        switch item.sourceName {
        case "Otro dispositivo": return "iphone"
        case "Captura de pantalla": return "camera.viewfinder"
        default: return "app.dashed"
        }
    }

    private func miniButton(_ symbol: String, tint: Color = .white, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 19, height: 19)
                .background(Circle().fill(immersive ? Color.black.opacity(0.5) : Color.white.opacity(0.16)))
                .contentShape(Circle())
        }
        .buttonStyle(ScaleButtonStyle())
        .help(help)
    }

    // MARK: Contenido

    @ViewBuilder
    private var content: some View {
        Group {
            switch item.kind {
            case .text:
                if swatch != nil { colorContent } else { textContent }
            case .link:
                linkContent
            case .image:
                Color.clear
            case .files:
                filesContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 10)
    }

    private var textContent: some View {
        let code = item.looksLikeCode
        return Text(item.previewText)
            .font(code ? .system(size: 9.5, design: .monospaced) : .system(size: 11))
            .foregroundStyle(Color.white.opacity(code ? 0.85 : 0.92))
            .lineSpacing(code ? 1 : 1.5)
            .lineLimit(4)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: 0.7),
                        .init(color: item.isLongText ? Color.black.opacity(0.15) : .black, location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
    }

    private var colorContent: some View {
        Text((item.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased())
            .font(.system(size: 16, weight: .semibold, design: .monospaced))
            .foregroundStyle(item.swatchInk)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .offset(y: 2)
    }

    private var linkContent: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color(red: 0.25, green: 0.55, blue: 1).opacity(0.28))
                    Image(systemName: item.footerText == "Correo" ? "envelope.fill" : "link")
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(Color(red: 0.45, green: 0.7, blue: 1))
                }
                .frame(width: 23, height: 23)

                Text(item.host)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let detail = item.linkDetail {
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.white.opacity(0.55))
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
        }
        .padding(.top, 2)
    }

    private var filesContent: some View {
        let name = URL(fileURLWithPath: item.paths.first ?? "").lastPathComponent
        let missing = !(item.paths.first.map { FileManager.default.fileExists(atPath: $0) } ?? false)
        return HStack(alignment: .top, spacing: 8) {
            Image(nsImage: item.fileIcon)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 32, height: 32)
                .shadow(color: Color.black.opacity(0.35), radius: 3, y: 2)
                .opacity(missing ? 0.45 : 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.white.opacity(missing ? 0.5 : 0.92))
                    .lineLimit(2)
                    .truncationMode(.middle)
                if item.paths.count > 1 {
                    Text("y \(item.paths.count - 1) más")
                        .font(.system(size: 9.5))
                        .foregroundStyle(Color.white.opacity(0.5))
                } else if missing {
                    Text("No disponible")
                        .font(.system(size: 9.5))
                        .foregroundStyle(Color.white.opacity(0.4))
                }
            }
        }
        .padding(.top, 2)
    }

    // MARK: Pie

    @ViewBuilder
    private var footer: some View {
        if swatch == nil {
            Text(item.footerText)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Color.white.opacity(item.kind == .image ? 0.9 : 0.35))
                .shadow(color: Color.black.opacity(item.kind == .image ? 0.5 : 0), radius: 2, y: 1)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 20, alignment: .top)
        } else {
            Color.clear.frame(height: 8)
        }
    }
}

// MARK: - Confirmación "Copiado"

private struct CopiedBadge: View {
    @State private var shown = false

    var body: some View {
        ZStack {
            Rectangle().fill(Color.black.opacity(0.6))
            VStack(spacing: 5) {
                Image(systemName: "checkmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Color.white, Color.green)
                    .font(.system(size: 26))
                    .scaleEffect(shown ? 1 : 0.4)
                Text("Copiado")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .opacity(shown ? 1 : 0)
                    .offset(y: shown ? 0 : 4)
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.6)) { shown = true }
        }
    }
}

// MARK: - Estado vacío

/// Tres tarjetas "fantasma" y un mensaje encima.
struct ClipEmptyState: View {
    let symbol: String
    let title: String
    let subtitle: String
    var buttonTitle: String?
    var action: () -> Void = {}

    var body: some View {
        ZStack {
            HStack(spacing: 8) {
                ForEach(0..<3, id: \.self) { index in
                    ghost(index)
                }
            }

            VStack(spacing: 0) {
                ZStack {
                    Circle().fill(
                        LinearGradient(
                            colors: [Color.white.opacity(0.14), Color.white.opacity(0.06)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    Image(systemName: symbol)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.85))
                        .symbolEffect(.pulse, options: .repeating.speed(0.35))
                }
                .frame(width: 32, height: 32)
                .overlay(Circle().strokeBorder(Color.white.opacity(0.14), lineWidth: 0.8))
                .padding(.bottom, 9)

                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.85))
                Text(subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.white.opacity(0.4))
                    .multilineTextAlignment(.center)
                    .padding(.top, 3)
                if let buttonTitle {
                    Button(action: action) {
                        Text(buttonTitle)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.9))
                            .padding(.horizontal, 10)
                            .frame(height: 20)
                            .background(Capsule().fill(Color.white.opacity(0.14)))
                    }
                    .buttonStyle(ScaleButtonStyle())
                    .padding(.top, 8)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
            .background(
                RadialGradient(
                    colors: [Color.black.opacity(0.85), Color.black.opacity(0)],
                    center: .center,
                    startRadius: 20,
                    endRadius: 130
                )
                .scaleEffect(x: 1.5, y: 1)
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func ghost(_ index: Int) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Circle().fill(Color.white.opacity(0.09)).frame(width: 14, height: 14)
                Capsule().fill(Color.white.opacity(0.09)).frame(width: 40, height: 5)
            }
            if index == 1 {
                // La tarjeta del centro imita una imagen (como el visor del carrusel).
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.white.opacity(0.10), Color.white.opacity(0.04)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(height: 34)
                    .frame(maxWidth: .infinity)
            }
            Capsule().fill(Color.white.opacity(0.07)).frame(height: 5)
            Capsule().fill(Color.white.opacity(0.07)).frame(width: index == 1 ? 70 : 96, height: 5)
            Spacer(minLength: 0)
        }
        .padding(11)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.white.opacity(0.055), Color.white.opacity(0.025)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay(
                    // Brillo de cristal en la mitad superior.
                    LinearGradient(
                        colors: [Color.white.opacity(0.05), Color.white.opacity(0)],
                        startPoint: .top,
                        endPoint: .center
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.white.opacity(index == 1 ? 0.11 : 0.08), lineWidth: 0.8)
                )
        )
        .scaleEffect(index == 1 ? 1.03 : 1, anchor: .center)
        .opacity(1 - Double(index) * 0.18)
    }
}
