import AppKit
import QuickLookThumbnailing

/// Resumen de las descargas en curso que se muestra en el notch cerrado.
struct DownloadSummary: Equatable {
    var count: Int
    /// Nombre del archivo. `nil` cuando el navegador aún usa un nombre provisional (Chrome, Brave…).
    var name: String?
    /// App que descarga ("Brave", "Safari"…), para los nombres que todavía no se conocen.
    var source: String?
    /// `nil` cuando el servidor no dice el tamaño total.
    var fraction: Double?
    var receivedBytes: Int64
    var bytesPerSecond: Double?

    var title: String {
        if count > 1 { return "\(count) descargas" }
        if let name { return name }
        if let source { return "Descargando con \(source)" }
        return "Descargando archivo"
    }
}

/// Actividades del notch cerrado que vienen de la carpeta de Descargas: descargas con progreso
/// y archivos recibidos por AirDrop. Solo trabaja mientras hay algo que mostrar.
final class ActivityCenter: ObservableObject {
    @Published private(set) var downloads: DownloadSummary?
    /// Icono o miniatura del archivo del último aviso (descarga terminada, AirDrop).
    @Published private(set) var image: NSImage?

    /// Se llaman en el hilo principal: número de archivos y nombre del primero.
    var onAirDrop: ((_ count: Int, _ name: String) -> Void)?
    var onDownloadFinished: ((_ count: Int, _ name: String) -> Void)?

    private var watcher: DownloadWatcher?
    private var imageTarget: URL?

    /// Enciende o apaga cada función. Es barato llamarlo muchas veces con los mismos valores.
    /// `directory` es la carpeta a vigilar (por defecto, Descargas).
    func configure(downloads wantsDownloads: Bool, airdrop wantsAirDrop: Bool, directory: URL? = nil) {
        guard wantsDownloads || wantsAirDrop else {
            watcher?.stop()
            watcher = nil
            publish(nil)
            return
        }

        let folder = directory
            ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Downloads")

        if watcher == nil || watcher?.directory != folder.resolvingSymlinksInPath() {
            watcher?.stop()
            let fresh = DownloadWatcher(directory: folder)
            fresh.onSummary = { [weak self] summary in self?.publish(summary) }
            fresh.onFinished = { [weak self] urls in self?.finished(urls) }
            fresh.onAirDrop = { [weak self] urls in self?.arrived(urls) }
            watcher = fresh
        }
        watcher?.start(downloads: wantsDownloads, airdrop: wantsAirDrop)
        if !wantsDownloads { publish(nil) }
    }

    private func publish(_ summary: DownloadSummary?) {
        if summary != downloads { downloads = summary }
    }

    // MARK: - Avisos

    private func finished(_ urls: [URL]) {
        guard let first = urls.first else { return }
        loadImage(for: first)
        onDownloadFinished?(urls.count, first.lastPathComponent)
    }

    private func arrived(_ urls: [URL]) {
        guard let first = urls.first else { return }
        loadImage(for: first)
        onAirDrop?(urls.count, first.lastPathComponent)
    }

    /// Primero el icono del archivo (al instante) y después su miniatura real, si existe.
    private func loadImage(for url: URL) {
        imageTarget = url
        image = NSWorkspace.shared.icon(forFile: url.path)

        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: 48, height: 48),
            scale: 2,
            representationTypes: .thumbnail
        )
        Task { @MainActor [weak self] in
            guard let thumbnail = try? await QLThumbnailGenerator.shared
                .generateBestRepresentation(for: request).nsImage else { return }
            guard let self, self.imageTarget == url else { return }
            self.image = thumbnail
        }
    }
}

// MARK: - Formato

enum ActivityFormat {
    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, count), countStyle: .file)
    }

    /// "3,2 MB/s" (o `nil` si apenas se mueve).
    static func speed(_ bytesPerSecond: Double?) -> String? {
        guard let bytesPerSecond, bytesPerSecond >= 1024 else { return nil }
        return bytes(Int64(bytesPerSecond)) + "/s"
    }
}
