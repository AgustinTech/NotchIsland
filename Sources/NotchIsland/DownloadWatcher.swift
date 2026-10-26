import Foundation

/// Vigila la carpeta de Descargas sin gastar nada mientras no pasa nada:
/// - Un `DispatchSource` avisa cuando entra, sale o se renombra un archivo.
/// - Mientras hay descargas en curso, un temporizador de 1 s mide su avance (y se apaga al terminar).
/// - El progreso real lo publican los propios navegadores con `NSProgress` (Safari, Chrome, Brave,
///   Edge, Arc y Firefox lo hacen). Si no lo publican, se usa el `Info.plist` del paquete `.download`
///   de Safari y, en último caso, solo el tamaño que va ocupando el archivo (progreso indeterminado).
final class DownloadWatcher: @unchecked Sendable {
    let directory: URL

    /// Se llaman en el hilo principal.
    var onSummary: ((DownloadSummary?) -> Void)?
    var onFinished: (([URL]) -> Void)?
    var onAirDrop: (([URL]) -> Void)?

    private let queue = DispatchQueue(label: "NotchIsland.downloads", qos: .utility)
    private let airDrop: AirDropDetector

    // Hilo principal.
    private var subscriber: Any?

    // Solo se tocan desde `queue`.
    private var source: DispatchSourceFileSystemObject?
    private var timer: DispatchSourceTimer?
    private var scanWork: DispatchWorkItem?
    private var known: Set<String> = []
    private var recent: [(url: URL, date: Date)] = []
    private var items: [String: Item] = [:]
    private var published: [String: Progress] = [:]
    private var trackDownloads = false
    private var detectAirDrop = false
    private var lastSummary: DownloadSummary?

    private struct Item {
        var id: String
        var partial: URL?
        var started: Date
        var lastChange: Date
        var bytes: Int64 = 0
        var modified: Date
        var fraction: Double?
        var speed: Double?
        var sampleBytes: Int64 = 0
        var sampleDate: Date
        var source: String?
        var name: String?
    }

    /// Una descarga sin avances en este tiempo deja de contar como actividad (pausada o abandonada).
    private static let stall: TimeInterval = 45
    private static let partialSuffixes: Set<String> = ["crdownload", "download", "part", "partial", "opdownload"]

    init(directory: URL) {
        self.directory = directory.resolvingSymlinksInPath()
        self.airDrop = AirDropDetector(queue: queue)
        airDrop.onArrival = { [weak self] urls in
            DispatchQueue.main.async { self?.onAirDrop?(urls) }
        }
    }

    // MARK: - Ciclo de vida

    /// Hilo principal. Es idempotente: se puede llamar de nuevo para cambiar qué se vigila.
    func start(downloads: Bool, airdrop: Bool) {
        if downloads { subscribe() } else { unsubscribe() }

        queue.async { [self] in
            trackDownloads = downloads
            detectAirDrop = airdrop
            if !downloads { clearItems() }

            if source == nil {
                // Abrir la carpeta puede pedir permiso al sistema; por eso no se hace en el hilo principal.
                let fd = open(directory.path, O_EVTONLY)
                guard fd >= 0 else { return }
                let watch = DispatchSource.makeFileSystemObjectSource(
                    fileDescriptor: fd,
                    eventMask: [.write, .extend, .rename, .delete, .link],
                    queue: queue
                )
                watch.setEventHandler { [weak self] in self?.scheduleScan() }
                watch.setCancelHandler { close(fd) }
                known = Self.names(in: directory)
                source = watch
                watch.resume()
            }
            scan()
        }
    }

    /// Hilo principal.
    func stop() {
        unsubscribe()
        queue.async { [self] in
            source?.cancel()
            source = nil
            scanWork?.cancel()
            scanWork = nil
            known = []
            recent = []
            detectAirDrop = false
            trackDownloads = false
            clearItems()
        }
    }

    private func clearItems() {
        items = [:]
        published = [:]
        timer?.cancel()
        timer = nil
        emit(nil)
    }

    // MARK: - Progreso publicado por las apps (NSProgress)

    private func subscribe() {
        guard subscriber == nil else { return }
        subscriber = Progress.addSubscriber(forFileURL: directory) { [weak self] progress in
            guard let self, let url = progress.userInfo[.fileURLKey] as? URL else { return nil }
            let id = Self.id(of: url)
            let kind = progress.userInfo[.fileOperationKindKey] as? String
            guard URL(fileURLWithPath: id).deletingLastPathComponent().path == self.directory.path,
                  kind == Progress.FileOperationKind.downloading.rawValue
                    || Self.isPartial(url.lastPathComponent) else { return nil }

            self.queue.async {
                self.published[id] = progress
                self.scan()
            }
            return { [weak self] in
                guard let self else { return }
                self.queue.async {
                    if self.published[id] === progress { self.published[id] = nil }
                    self.scan()
                }
            }
        }
    }

    private func unsubscribe() {
        if let token = subscriber { Progress.removeSubscriber(token) }
        subscriber = nil
    }

    // MARK: - Exploración de la carpeta

    private func scheduleScan() {
        guard scanWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in self?.scan() }
        scanWork = work
        queue.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    private func scan() {
        scanWork?.cancel()
        scanWork = nil
        guard source != nil else { return }

        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        let byName = Dictionary(urls.map { ($0.lastPathComponent, $0) }, uniquingKeysWith: { first, _ in first })
        let names = Set(byName.keys)
        let fresh = names.subtracting(known).sorted().compactMap { byName[$0] }
        known = names

        let now = Date()
        let arrivals = fresh.filter { !Self.isPartial($0.lastPathComponent) }
        recent = recent.filter { now.timeIntervalSince($0.date) < 8 } + arrivals.map { ($0, now) }

        if detectAirDrop { airDrop.consider(arrivals) }

        guard trackDownloads else { return }
        var partials: [String: URL] = [:]
        for url in urls where Self.isPartial(url.lastPathComponent) {
            partials[Self.id(of: url)] = url
        }
        reconcile(partials: partials, now: now)
        measure(now: now)
        publishSummary(now: now)
        updateTimer(now: now)
    }

    /// Altas y bajas de descargas.
    private func reconcile(partials: [String: URL], now: Date) {
        for id in Set(partials.keys).union(published.keys) where items[id] == nil {
            let file = partials[id]
            let measured = file.map(Self.measure) ?? (bytes: 0, modified: now)
            // Un parcial viejo que quedó abandonado no es una descarga en curso.
            let live = published[id] != nil || now.timeIntervalSince(measured.modified) < 10
            items[id] = Item(
                id: id,
                partial: file,
                started: now,
                lastChange: live ? now : measured.modified,
                bytes: measured.bytes,
                modified: measured.modified,
                sampleBytes: measured.bytes,
                sampleDate: now,
                source: Self.source(of: file ?? (published[id]?.userInfo[.fileURLKey] as? URL) ?? URL(fileURLWithPath: id)),
                name: Self.displayName(id: id)
            )
        }

        var finished: [URL] = []
        for id in items.keys.sorted(by: { items[$0]!.started < items[$1]!.started }) {
            items[id]?.partial = partials[id]
            guard partials[id] == nil, published[id] == nil, let item = items[id] else { continue }
            items[id] = nil

            // Terminó si aparece el archivo con su nombre definitivo (Safari, Firefox) o, para los
            // nombres provisionales de Chrome/Brave, un archivo nuevo justo ahora.
            let target = URL(fileURLWithPath: id)
            if let index = recent.firstIndex(where: { $0.url.path == id }) {
                recent.remove(at: index)
                finished.append(target)
            } else if item.name != nil, Self.modified(target).map({ $0 >= item.started.addingTimeInterval(-2) }) == true {
                finished.append(target)
            } else if item.name == nil, !recent.isEmpty {
                finished.append(recent.removeFirst().url)
            }
        }
        if !finished.isEmpty {
            DispatchQueue.main.async { [weak self] in self?.onFinished?(finished) }
        }
    }

    /// Tamaño, avance y velocidad de cada descarga.
    private func measure(now: Date) {
        for id in Array(items.keys) {
            guard var item = items[id] else { continue }

            if let partial = item.partial {
                let measured = Self.measure(partial)
                item.bytes = measured.bytes
                if measured.modified != item.modified { item.lastChange = now }
                item.modified = measured.modified
            }

            var fraction: Double?
            if let progress = published[id], !progress.isIndeterminate, progress.totalUnitCount > 0 {
                fraction = min(max(progress.fractionCompleted, 0), 1)
            } else if let partial = item.partial, let safari = Self.safariProgress(partial) {
                fraction = safari.fraction
                item.bytes = max(item.bytes, safari.bytes)
            }
            if fraction != item.fraction || item.bytes != item.sampleBytes { item.lastChange = now }
            item.fraction = fraction

            let elapsed = now.timeIntervalSince(item.sampleDate)
            if elapsed >= 0.8 {
                let instant = Double(item.bytes - item.sampleBytes) / elapsed
                item.speed = item.speed.map { $0 * 0.5 + instant * 0.5 } ?? instant
                item.sampleBytes = item.bytes
                item.sampleDate = now
            }
            items[id] = item
        }
    }

    private func publishSummary(now: Date) {
        let active = items.values
            .filter { now.timeIntervalSince($0.lastChange) < Self.stall }
            .sorted { $0.started < $1.started }
        guard let first = active.first else {
            emit(nil)
            return
        }

        let fractions = active.compactMap(\.fraction)
        let fraction = fractions.isEmpty ? nil : fractions.reduce(0, +) / Double(fractions.count)
        let speeds = active.compactMap(\.speed)

        emit(DownloadSummary(
            count: active.count,
            name: first.name,
            source: first.source,
            fraction: fraction,
            receivedBytes: active.reduce(0) { $0 + $1.bytes },
            bytesPerSecond: speeds.isEmpty ? nil : speeds.reduce(0, +)
        ))
    }

    private func emit(_ summary: DownloadSummary?) {
        guard summary != lastSummary else { return }
        lastSummary = summary
        DispatchQueue.main.async { [weak self] in self?.onSummary?(summary) }
    }

    private func updateTimer(now: Date) {
        // Un parcial abandonado en Descargas no debe mantener despierto el temporizador.
        let busy = items.values.contains {
            published[$0.id] != nil || now.timeIntervalSince($0.lastChange) < Self.stall
        }
        if !busy {
            timer?.cancel()
            timer = nil
        } else if timer == nil {
            let tick = DispatchSource.makeTimerSource(queue: queue)
            tick.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(200))
            tick.setEventHandler { [weak self] in self?.scan() }
            tick.resume()
            timer = tick
        }
    }

    // MARK: - Utilidades

    private static func names(in directory: URL) -> Set<String> {
        let urls = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )
        return Set((urls ?? []).map(\.lastPathComponent))
    }

    private static func isPartial(_ name: String) -> Bool {
        partialSuffixes.contains((name as NSString).pathExtension.lowercased())
    }

    /// Ruta del archivo final: la del parcial sin su sufijo (`foo.zip.crdownload` -> `foo.zip`).
    private static func id(of url: URL) -> String {
        var resolved = url.resolvingSymlinksInPath()
        if isPartial(resolved.lastPathComponent) { resolved.deletePathExtension() }
        return resolved.path
    }

    /// Chrome y Brave llaman "Unconfirmed 123456" al archivo hasta que termina: no es un nombre útil.
    private static func displayName(id: String) -> String? {
        let name = URL(fileURLWithPath: id).lastPathComponent
        if name.hasPrefix("Unconfirmed ") { return nil }
        return name
    }

    private static func source(of url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case "download": return "Safari"
        case "part": return "Firefox"
        case "opdownload": return "Opera"
        default: return Quarantine.read(url)?.agent
        }
    }

    private static func modified(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// Bytes y fecha de la última escritura. Los paquetes `.download` se miden por dentro.
    private static func measure(_ url: URL) -> (bytes: Int64, modified: Date) {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        let values = try? url.resourceValues(forKeys: Set(keys))
        var modified = values?.contentModificationDate ?? .distantPast
        guard values?.isDirectory == true else {
            return (Int64(values?.fileSize ?? 0), modified)
        }

        var total: Int64 = 0
        let children = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys)) ?? []
        for child in children where child.lastPathComponent != "Info.plist" {
            let childValues = try? child.resourceValues(forKeys: Set(keys))
            total += Int64(childValues?.fileSize ?? 0)
            if let date = childValues?.contentModificationDate, date > modified { modified = date }
        }
        return (total, modified)
    }

    /// El `Info.plist` del paquete `.download` de Safari guarda los bytes recibidos y el total.
    private static func safariProgress(_ url: URL) -> (fraction: Double, bytes: Int64)? {
        guard url.pathExtension.lowercased() == "download",
              let data = try? Data(contentsOf: url.appendingPathComponent("Info.plist")),
              let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              let total = (plist["DownloadEntryProgressTotalToLoad"] as? NSNumber)?.int64Value, total > 0,
              let received = (plist["DownloadEntryProgressBytesSoFar"] as? NSNumber)?.int64Value else { return nil }
        return (min(1, Double(received) / Double(total)), received)
    }
}

// MARK: - Cuarentena (de dónde viene un archivo)

/// `com.apple.quarantine` tiene la forma `0083;6abfdfa9;sharingd;UUID`: banderas, fecha de recepción
/// en hexadecimal y la app que lo trajo (Safari, Brave, sharingd = AirDrop…).
enum Quarantine {
    static func read(_ url: URL) -> (agent: String, date: Date)? {
        let name = "com.apple.quarantine"
        let size = getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW)
        guard size > 0 else { return nil }

        var buffer = [UInt8](repeating: 0, count: size)
        guard getxattr(url.path, name, &buffer, size, 0, XATTR_NOFOLLOW) > 0 else { return nil }

        let parts = String(decoding: buffer, as: UTF8.self).split(separator: ";", omittingEmptySubsequences: false)
        guard parts.count >= 3, let stamp = UInt64(parts[1], radix: 16) else { return nil }
        return (String(parts[2]), Date(timeIntervalSince1970: TimeInterval(stamp)))
    }
}
