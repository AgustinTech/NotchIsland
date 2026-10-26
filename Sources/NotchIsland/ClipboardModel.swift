import AppKit
import Carbon.HIToolbox
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

// MARK: - Elemento del historial

struct ClipItem: Identifiable, Codable, Equatable {
    enum Kind: String, Codable {
        case text, link, image, files
    }

    var id = UUID()
    var kind: Kind
    /// Huella del contenido, para no guardar dos veces lo mismo.
    var key: String
    var date: Date
    var pinned = false

    var sourceName: String?
    var sourceBundleID: String?

    /// Texto, o la dirección si es un enlace.
    var text: String?
    /// Título del enlace (si la app de origen lo incluye al copiar).
    var title: String?
    var paths: [String] = []
    /// Nombre del archivo con la imagen reducida dentro de la carpeta de imágenes.
    var imageFile: String?
    var width = 0
    var height = 0
    var bytes: Int64 = 0
}

// MARK: - Modelo

/// Historial del portapapeles.
///
/// - Vigila `changeCount` cada medio segundo (casi gratis); el contenido solo se lee cuando cambia,
///   y siempre fuera del hilo principal, porque macOS puede pedir permiso para leer el portapapeles.
/// - No guarda nada marcado como oculto/temporal ni lo que copian los gestores de contraseñas.
/// - Se guarda en `~/Library/Application Support/NotchIsland/` (JSON + imágenes reducidas).
final class ClipboardModel: ObservableObject {
    @Published private(set) var items: [ClipItem] = []
    /// Falso si el usuario ha pausado el historial (`defaults write … clipboardHistory -bool false`).
    @Published private(set) var capturing = true
    /// macOS no deja a la app leer el portapapeles (Ajustes > Privacidad > Pegar desde otras apps).
    @Published private(set) var blocked = false
    /// Tarjeta que acaba de copiarse (para la confirmación animada).
    @Published private(set) var copiedID: UUID?

    static let defaultsKey = "clipboardHistory"
    /// Máximo de elementos sin fijar.
    static let limit = 40
    /// Un texto más largo que esto no se guarda (mejor no guardarlo que guardarlo recortado).
    static let maxTextLength = 100_000
    static let maxImageSide = 1280

    static var captureEnabled: Bool {
        (UserDefaults.standard.object(forKey: defaultsKey) as? Bool) ?? true
    }

    private let pasteboard: NSPasteboard
    private let directory: URL
    private var imagesDirectory: URL { directory.appendingPathComponent("ClipboardImages", isDirectory: true) }
    private var storeURL: URL { directory.appendingPathComponent("clipboard.json") }

    private var timer: Timer?
    private var lastChange = 0
    private var saveWork: DispatchWorkItem?
    private var copiedWork: DispatchWorkItem?
    private var terminateObserver: NSObjectProtocol?
    private let queue = DispatchQueue(label: "notchisland.clipboard", qos: .utility)

    private static let thumbnails: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 60
        return cache
    }()

    init(pasteboard: NSPasteboard = .general, directory: URL? = nil) {
        self.pasteboard = pasteboard
        self.directory = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotchIsland", isDirectory: true)
    }

    // MARK: - Arranque

    func start() {
        guard timer == nil else { return }
        load()
        capturing = Self.captureEnabled
        lastChange = pasteboard.changeCount
        refreshBlocked()

        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        timer.tolerance = 0.25
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.flush()
        }
    }

    private func tick() {
        let enabled = Self.captureEnabled
        if enabled != capturing { capturing = enabled }

        let count = pasteboard.changeCount
        guard count != lastChange else { return }
        lastChange = count
        // En pausa no se guarda nada, ni siquiera lo copiado mientras tanto.
        guard enabled else { return }

        let front = NSWorkspace.shared.frontmostApplication
        if let id = front?.bundleIdentifier, Self.isPasswordManager(id) { return }
        let own = front?.bundleIdentifier == Bundle.main.bundleIdentifier
        let date = Date()
        let frontID = own ? nil : front?.bundleIdentifier
        let frontName = own ? nil : front?.localizedName

        queue.async { [weak self] in
            guard let self, let capture = self.read(frontID: frontID, frontName: frontName) else { return }
            DispatchQueue.main.async {
                self.ingest(capture, date: date)
            }
        }
    }

    private func refreshBlocked() {
        var denied = false
        if #available(macOS 15.4, *) {
            denied = pasteboard.accessBehavior == .alwaysDeny
        }
        if denied != blocked { blocked = denied }
    }

    // MARK: - Lectura del portapapeles (hilo secundario)

    private struct Capture {
        var kind: ClipItem.Kind
        var key: String
        var text: String?
        var title: String?
        var paths: [String] = []
        var bytes: Int64 = 0
        var image: StoredImage?
        var sourceID: String?
        var sourceName: String?
    }

    private struct StoredImage {
        var file: String
        var width: Int
        var height: Int
        var bytes: Int
    }

    private static let sourceType = NSPasteboard.PasteboardType("org.nspasteboard.source")
    private static let urlNameType = NSPasteboard.PasteboardType("public.url-name")
    private static let remoteType = "com.apple.is-remote-clipboard"

    /// Tipos con los que las apps avisan de que el contenido es secreto, temporal o automático.
    private static let privateTypes: Set<String> = [
        "org.nspasteboard.ConcealedType",
        "org.nspasteboard.TransientType",
        "org.nspasteboard.AutoGeneratedType",
        "de.petermaurer.TransientPasteboardType",
        "com.typeit4me.clipping",
        "Pasteboard generator type",
        "net.antelle.keeweb"
    ]

    private static let passwordMarkers = ["agilebits", "onepassword", "1password", "bitwarden", "keepass", "lastpass", "dashlane"]

    private static let passwordManagers = [
        "com.1password", "com.agilebits", "com.bitwarden", "com.apple.keychainaccess", "com.apple.passwords",
        "org.keepassxc", "org.keepassx", "com.lastpass", "com.dashlane", "com.enpass", "me.proton.pass",
        "com.nordpass", "com.keepersecurity", "com.callpod"
    ]

    static func isPasswordManager(_ bundleID: String) -> Bool {
        let id = bundleID.lowercased()
        return passwordManagers.contains { id.hasPrefix($0) }
    }

    static func isPrivate(types: [String]) -> Bool {
        types.contains { type in
            privateTypes.contains(type) || passwordMarkers.contains { type.lowercased().contains($0) }
        }
    }

    private func read(frontID: String?, frontName: String?) -> Capture? {
        let types = (pasteboard.types ?? []).map(\.rawValue)
        guard !types.isEmpty, !Self.isPrivate(types: types) else { return nil }

        var sourceID = frontID
        var sourceName = frontName
        if let declared = pasteboard.string(forType: Self.sourceType), !declared.isEmpty {
            if Self.isPasswordManager(declared) { return nil }
            if declared != Bundle.main.bundleIdentifier {
                sourceID = declared
                sourceName = nil
            }
        }
        if types.contains(Self.remoteType) {
            sourceID = nil
            sourceName = "Otro dispositivo"
        }

        func finish(_ capture: Capture) -> Capture {
            var capture = capture
            capture.sourceID = sourceID
            capture.sourceName = sourceName
            return capture
        }

        // Archivos copiados en el Finder.
        if types.contains("public.file-url"),
           let urls = pasteboard.readObjects(
               forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
           ) as? [URL], !urls.isEmpty {
            let files = Array(urls.prefix(30))
            let size = files.reduce(Int64(0)) { sum, url in
                let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
                return sum + ((values?.isDirectory ?? false) ? 0 : Int64(values?.fileSize ?? 0))
            }
            let paths = files.map(\.path)
            return finish(Capture(
                kind: .files, key: Self.digest("files", paths.joined(separator: "\n")),
                paths: paths, bytes: size
            ))
        }

        let string = pasteboard.string(forType: .string)
        let trimmed = string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let url = Self.link(from: trimmed)

        // Imagen: solo si no hay un texto "de verdad" (Excel, por ejemplo, copia texto e imagen a la vez).
        if trimmed.isEmpty || url != nil, let image = imageData(types: types) {
            if let stored = Self.store(image, in: imagesDirectory) {
                return finish(Capture(
                    kind: .image, key: Self.digest("image", Self.hash(image)),
                    bytes: Int64(stored.bytes), image: stored
                ))
            }
        }

        if let url {
            let title = pasteboard.string(forType: Self.urlNameType)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return finish(Capture(
                kind: .link, key: Self.digest("link", url.absoluteString),
                text: url.absoluteString, title: (title?.isEmpty ?? true) ? nil : title
            ))
        }

        if trimmed.isEmpty, types.contains("public.url"),
           let raw = pasteboard.string(forType: .URL),
           let url = Self.link(from: raw.trimmingCharacters(in: .whitespacesAndNewlines)) {
            let title = pasteboard.string(forType: Self.urlNameType)
            return finish(Capture(
                kind: .link, key: Self.digest("link", url.absoluteString),
                text: url.absoluteString, title: title
            ))
        }

        if let string, !trimmed.isEmpty, string.count <= Self.maxTextLength {
            return finish(Capture(kind: .text, key: Self.digest("text", string), text: string))
        }
        return nil
    }

    private func imageData(types: [String]) -> Data? {
        if let data = pasteboard.data(forType: .png) { return data }
        if let data = pasteboard.data(forType: .tiff) { return data }
        for type in types {
            if let ut = UTType(type), ut.conforms(to: .image),
               let data = pasteboard.data(forType: NSPasteboard.PasteboardType(type)) {
                return data
            }
        }
        return nil
    }

    private static func link(from text: String) -> URL? {
        guard !text.isEmpty, text.count < 2048, !text.contains(where: \.isWhitespace),
              let url = URL(string: text), let scheme = url.scheme?.lowercased() else { return nil }
        if ["http", "https", "ftp"].contains(scheme) {
            return (url.host ?? "").isEmpty ? nil : url
        }
        return scheme == "mailto" ? url : nil
    }

    private static func digest(_ kind: String, _ content: String) -> String {
        hash(Data((kind + ":" + content).utf8))
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// Reduce la imagen (máx. `maxImageSide` px) y la guarda: PNG si tiene transparencia, JPEG si no.
    private static func store(_ data: Data, in directory: URL) -> StoredImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int else { return nil }

        let image: CGImage?
        if max(width, height) > maxImageSide {
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxImageSide
            ] as CFDictionary)
        } else {
            image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        guard let image else { return nil }

        let hasAlpha: Bool
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: hasAlpha = false
        default: hasAlpha = true
        }
        let type: UTType = hasAlpha ? .png : .jpeg
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.86] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }

        let name = UUID().uuidString + (hasAlpha ? ".png" : ".jpg")
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
            )
            let url = directory.appendingPathComponent(name)
            try (output as Data).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            return nil
        }
        return StoredImage(file: name, width: width, height: height, bytes: output.length)
    }

    // MARK: - Alta de elementos

    private func ingest(_ capture: Capture, date: Date) {
        refreshBlocked()

        var sourceName = capture.sourceName
        if let id = capture.sourceID, let name = Self.appName(for: id) { sourceName = name }

        if let index = items.firstIndex(where: { $0.key == capture.key }) {
            // Ya estaba: sube al principio y se actualiza de dónde viene.
            items[index].date = date
            if capture.sourceID != nil || sourceName != nil {
                items[index].sourceBundleID = capture.sourceID
                items[index].sourceName = sourceName
            }
            if let file = capture.image?.file { removeImageFile(file) }
        } else {
            items.append(ClipItem(
                kind: capture.kind, key: capture.key, date: date,
                sourceName: sourceName, sourceBundleID: capture.sourceID,
                text: capture.text, title: capture.title, paths: capture.paths,
                imageFile: capture.image?.file,
                width: capture.image?.width ?? 0, height: capture.image?.height ?? 0,
                bytes: capture.bytes
            ))
        }
        normalize()
        scheduleSave()
    }

    /// Fijados primero, después por fecha; recorta lo que sobre.
    private func normalize() {
        var sorted = items.sorted {
            $0.pinned != $1.pinned ? $0.pinned : $0.date > $1.date
        }
        var unpinned = 0
        var kept: [ClipItem] = []
        for item in sorted {
            if item.pinned {
                kept.append(item)
            } else if unpinned < Self.limit {
                unpinned += 1
                kept.append(item)
            } else if let file = item.imageFile {
                removeImageFile(file)
            }
        }
        sorted = kept
        if sorted != items { items = sorted }
    }

    static func appName(for bundleID: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let name = FileManager.default.displayName(atPath: url.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    // MARK: - Acciones

    /// Vuelve a poner el elemento en el portapapeles (sin que cuente como una copia nueva) y, si la app
    /// tiene permiso de Accesibilidad, lo pega en la app que tenga el foco. Nunca pide ese permiso.
    func use(_ item: ClipItem) {
        guard write(item) else { return }
        lastChange = pasteboard.changeCount

        copiedWork?.cancel()
        copiedID = item.id
        let work = DispatchWorkItem { [weak self] in
            self?.copiedID = nil
        }
        copiedWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1, execute: work)

        if UserDefaults.standard.bool(forKey: "haptics") {
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        }

        let front = NSWorkspace.shared.frontmostApplication
        if AXIsProcessTrusted(), front?.bundleIdentifier != Bundle.main.bundleIdentifier {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                Self.postPaste()
            }
        }
    }

    private func write(_ item: ClipItem) -> Bool {
        switch item.kind {
        case .text:
            guard let text = item.text else { return false }
            pasteboard.clearContents()
            return pasteboard.setString(text, forType: .string)

        case .link:
            guard let text = item.text else { return false }
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .URL)
            if let title = item.title { pasteboard.setString(title, forType: Self.urlNameType) }
            return pasteboard.setString(text, forType: .string)

        case .image:
            guard let file = item.imageFile,
                  let data = try? Data(contentsOf: imagesDirectory.appendingPathComponent(file)) else { return false }
            pasteboard.clearContents()
            pasteboard.setData(data, forType: file.hasSuffix(".png") ? .png : NSPasteboard.PasteboardType("public.jpeg"))
            if let tiff = NSImage(data: data)?.tiffRepresentation {
                pasteboard.setData(tiff, forType: .tiff)
            }
            return true

        case .files:
            let urls = item.paths.filter { FileManager.default.fileExists(atPath: $0) }.map { URL(fileURLWithPath: $0) }
            pasteboard.clearContents()
            if urls.isEmpty {
                // Los archivos ya no existen: al menos se copian sus rutas.
                return pasteboard.setString(item.paths.joined(separator: "\n"), forType: .string)
            }
            return pasteboard.writeObjects(urls as [NSURL])
        }
    }

    func togglePin(_ item: ClipItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].pinned.toggle()
        normalize()
        scheduleSave()
    }

    func remove(_ item: ClipItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        let removed = items.remove(at: index)
        if let file = removed.imageFile { removeImageFile(file) }
        scheduleSave()
    }

    /// Borra los elementos indicados que no estén fijados.
    func clear(_ targets: [ClipItem]) {
        let ids = Set(targets.filter { !$0.pinned }.map(\.id))
        guard !ids.isEmpty else { return }
        for item in items where ids.contains(item.id) {
            if let file = item.imageFile { removeImageFile(file) }
        }
        items.removeAll { ids.contains($0.id) }
        scheduleSave()
    }

    func setCapturing(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.defaultsKey)
        if on != capturing { capturing = on }
        // Lo copiado mientras estaba en pausa no se guarda al reanudar.
        lastChange = pasteboard.changeCount
    }

    // MARK: - Arrastrar fuera

    func dragProvider(for item: ClipItem) -> NSItemProvider {
        switch item.kind {
        case .text:
            return NSItemProvider(object: (item.text ?? "") as NSString)
        case .link:
            guard let text = item.text, let url = URL(string: text) else { return NSItemProvider() }
            let provider = NSItemProvider(object: url as NSURL)
            provider.registerObject(text as NSString, visibility: .all)
            return provider
        case .image:
            guard let file = item.imageFile,
                  let provider = NSItemProvider(contentsOf: imagesDirectory.appendingPathComponent(file)) else {
                return NSItemProvider()
            }
            provider.suggestedName = "Imagen"
            return provider
        case .files:
            guard let path = item.paths.first(where: { FileManager.default.fileExists(atPath: $0) }),
                  let provider = NSItemProvider(contentsOf: URL(fileURLWithPath: path)) else {
                return NSItemProvider()
            }
            return provider
        }
    }

    // MARK: - Miniaturas

    /// Miniatura de una imagen del historial (en caché; se decodifica fuera del hilo principal).
    func thumbnail(for item: ClipItem) async -> NSImage? {
        guard let file = item.imageFile else { return nil }
        let cacheKey = file as NSString
        if let cached = Self.thumbnails.object(forKey: cacheKey) { return cached }

        let url = imagesDirectory.appendingPathComponent(file)
        return await Task.detached(priority: .utility) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                      kCGImageSourceShouldCacheImmediately: true,
                      kCGImageSourceThumbnailMaxPixelSize: 400
                  ] as CFDictionary) else { return nil }
            let image = NSImage(cgImage: cg, size: NSSize(width: cg.width / 2, height: cg.height / 2))
            Self.thumbnails.setObject(image, forKey: cacheKey)
            return image
        }.value
    }

    private func removeImageFile(_ file: String) {
        Self.thumbnails.removeObject(forKey: file as NSString)
        let url = imagesDirectory.appendingPathComponent(file)
        queue.async { try? FileManager.default.removeItem(at: url) }
    }

    // MARK: - Persistencia

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let saved = try? JSONDecoder().decode([ClipItem].self, from: data) else { return }
        items = saved.filter { item in
            guard let file = item.imageFile else { return true }
            return FileManager.default.fileExists(atPath: imagesDirectory.appendingPathComponent(file).path)
        }
        normalize()

        // Imágenes sueltas de elementos que ya no existen.
        let used = Set(items.compactMap(\.imageFile))
        let folder = imagesDirectory
        queue.async {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            for file in files where !used.contains(file) {
                try? FileManager.default.removeItem(at: folder.appendingPathComponent(file))
            }
        }
    }

    /// Guarda con un pequeño retraso para agrupar cambios seguidos.
    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.saveWork = nil
            self?.saveNow()
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    private func saveNow() {
        let snapshot = items
        let folder = directory
        let url = storeURL
        queue.async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            do {
                try FileManager.default.createDirectory(
                    at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
                )
                try data.write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            } catch {
                // Sin disco no hay historial persistente, pero la app sigue funcionando.
            }
        }
    }

    /// Escribe ya lo pendiente (al salir de la app).
    func flush() {
        guard let work = saveWork else { return }
        work.cancel()
        saveWork = nil
        saveNow()
        queue.sync {}
    }

    // MARK: - Pegar con Cmd+V

    private static func postPaste() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let key = keyCodeForV()
        let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cgSessionEventTap)
        up?.post(tap: .cgSessionEventTap)
    }

    /// Tecla que produce "v" en la distribución de teclado actual (Dvorak, Colemak…); la 9 si no se encuentra.
    static func keyCodeForV() -> CGKeyCode {
        guard let layout = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(layout, kTISPropertyUnicodeKeyLayoutData) else { return 9 }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return 9 }
        let keyLayout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        let keyboardType = UInt32(CGEventSource(stateID: .hidSystemState)?.keyboardType ?? 0)

        for code in 0..<128 {
            var dead: UInt32 = 0
            var length = 0
            var chars = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(
                keyLayout, UInt16(code), UInt16(kUCKeyActionDown), 0, keyboardType,
                OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, chars.count, &length, &chars
            )
            if status == noErr, length == 1, chars[0] == 0x76 { return CGKeyCode(code) }
        }
        return 9
    }
}
