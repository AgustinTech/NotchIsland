import AppKit
import SwiftUI

enum IslandTab: String, CaseIterable, Identifiable {
    case music, tray, today, clipboard, tools, mirror

    var id: String { rawValue }

    var title: String {
        switch self {
        case .music: return "Música"
        case .tray: return "Bandeja"
        case .today: return "Hoy"
        case .clipboard: return "Portapapeles"
        case .tools: return "Herramientas"
        case .mirror: return "Espejo"
        }
    }

    var symbol: String {
        switch self {
        case .music: return "music.note"
        case .tray: return "tray.full.fill"
        case .today: return "square.grid.2x2.fill"
        case .clipboard: return "doc.on.clipboard.fill"
        case .tools: return "timer"
        case .mirror: return "camera.fill"
        }
    }
}

enum IslandVisualSize: String, CaseIterable, Identifiable {
    case normal, wide, large

    var id: String { rawValue }

    var title: String {
        switch self {
        case .normal: return "Normal"
        case .wide: return "Amplio"
        case .large: return "Grande"
        }
    }

    var width: CGFloat {
        switch self {
        case .normal: return 520
        case .wide: return 580
        case .large: return 640
        }
    }

    var extraHeight: CGFloat {
        switch self {
        case .normal: return 164
        case .wide: return 184
        case .large: return 204
        }
    }
}

/// Avisos cortos que aparecen en el notch cerrado.
enum IslandTransient: Equatable {
    case charging
    case lowBattery
    case track
    case device(name: String, icon: String, percent: Int?)
    case airdrop(count: Int, name: String)
    case meeting(MeetingAlert)
    case downloadDone(count: Int, name: String)
    case volume(level: Double, muted: Bool)
    case brightness(level: Double)
    case timerDone(title: String)
}

/// Estado compartido entre la ventana (AppKit) y la vista (SwiftUI).
final class IslandState: ObservableObject {
    @Published var expanded = false
    @Published var hovering = false
    /// El contenido de la isla abierta sigue montado un momento tras cerrar, para poder desvanecerse.
    @Published var contentMounted = false
    @Published var tab: IslandTab = .music
    @Published private(set) var visibleTabs = IslandTab.allCases
    @Published private(set) var animationSpeed = 1.0
    @Published private(set) var reduceMotion = false
    /// Sentido del último deslizamiento entre pestañas (+1 hacia la derecha, -1 hacia la izquierda, 0 ninguno).
    @Published var tabDirection = 0
    var tabDirectionReset: DispatchWorkItem?
    @Published var dropTargeted = false
    /// Ancho extra a cada lado del notch cuando está cerrado pero con actividad.
    @Published var liveSide: CGFloat = 0
    /// Alto extra por debajo del notch (texto de "canción nueva", dispositivo conectado…).
    @Published var peekHeight: CGFloat = 0
    @Published var transient: IslandTransient?
    /// Descargas en curso y archivos recibidos: actividad del notch cerrado que viene de la carpeta Descargas.
    let activity = ActivityCenter()
    /// Temporizador, Pomodoro y cronómetro (también se ven en el notch cerrado).
    let timer = TimerModel()
    @Published var notchSize = CGSize(width: 190, height: 32)
    @Published var expandedSize = CGSize(width: 620, height: 208)
    @Published var files: [URL] = [] {
        didSet { saveFiles() }
    }

    /// Lo asigna la app para abrir el menú de ajustes desde el propio notch.
    var showMenu: () -> Void = {}
    /// Mientras hay un menú abierto el notch no se cierra.
    var pinned = false {
        didSet { if pinned != oldValue { onPinChange?() } }
    }
    var onPinChange: (() -> Void)?

    static let peek: CGFloat = 24

    // MARK: - Medidas de la forma (las usan la vista y la ventana)

    var bodySize: CGSize {
        if expanded { return expandedSize }
        let grow: CGFloat = hovering ? 1 : 0
        return CGSize(
            width: notchSize.width + liveSide * 2 + grow * 20,
            height: notchSize.height + peekHeight + grow * 4
        )
    }

    /// Volumen o brillo en pantalla (se enseña dentro de la isla si está abierta).
    var hudKind: HUDGlyph.Kind? {
        switch transient {
        case .volume(let level, let muted)?: return .volume(level: level, muted: muted)
        case .brightness(let level)?: return .brightness(level: level)
        default: return nil
        }
    }

    var isLive: Bool { liveSide > 0 || peekHeight > 0 }

    /// Tamaño del notch cerrado sin el efecto de hover (el contenido cerrado se coloca a este tamaño).
    var restingSize: CGSize {
        CGSize(width: notchSize.width + liveSide * 2, height: notchSize.height + peekHeight)
    }

    private var unmountWork: DispatchWorkItem?

    /// Curva cóncava de las esquinas superiores (como la unión del notch con la pantalla).
    var earRadius: CGFloat {
        if expanded { return 14 }
        return (isLive || hovering) ? 7 : 0
    }

    var bottomRadius: CGFloat {
        if expanded { return 28 }
        if peekHeight > 0 { return 20 }
        return (isLive || hovering) ? 14 : 12
    }

    // MARK: - Abrir y cerrar

    func open(_ newTab: IslandTab? = nil) {
        if let newTab {
            tab = newTab
        } else if !expanded, case .meeting? = transient {
            tab = .today   // el aviso de una reunión abre la agenda
        } else if !expanded && tab == .mirror {
            tab = .music
        }
        guard !expanded else { return }
        hovering = false
        transient = nil
        unmountWork?.cancel()
        contentMounted = true
        expanded = true
        if UserDefaults.standard.bool(forKey: "haptics") {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    }

    func close() {
        expanded = false
        dropTargeted = false

        // Desmonta el contenido cuando ya se ha desvanecido (la cámara del espejo se apaga entonces).
        unmountWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.expanded else { return }
            self.contentMounted = false
        }
        unmountWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    // MARK: - Bandeja

    init() {
        let saved = UserDefaults.standard.stringArray(forKey: "trayFiles") ?? []
        files = saved
            .filter { FileManager.default.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
        refreshVisualSettings()
    }

    func refreshVisualSettings() {
        let defaults = UserDefaults.standard
        let tabs = IslandTab.allCases.filter {
            (defaults.object(forKey: "showTab.\($0.rawValue)") as? Bool) ?? true
        }
        visibleTabs = tabs.isEmpty ? [.music] : tabs
        if !visibleTabs.contains(tab) { tab = visibleTabs[0] }

        let savedSpeed = defaults.object(forKey: "visualAnimationSpeed") as? Double ?? 1
        animationSpeed = min(max(savedSpeed, 0.5), 2)
        reduceMotion = defaults.bool(forKey: "visualReduceMotion")
    }

    func setTabVisible(_ tab: IslandTab, visible: Bool) {
        guard visible || visibleTabs.count > 1 else { return }
        UserDefaults.standard.set(visible, forKey: "showTab.\(tab.rawValue)")
        refreshVisualSettings()
    }

    private func saveFiles() {
        UserDefaults.standard.set(files.map { $0.path }, forKey: "trayFiles")
    }

    @discardableResult
    func addFiles(_ urls: [URL]) -> Bool {
        var known = Set(files.map(\.standardizedFileURL))
        let additions = urls.filter { url in
            let normalized = url.standardizedFileURL
            return url.isFileURL && FileManager.default.fileExists(atPath: url.path)
                && known.insert(normalized).inserted
        }
        guard !additions.isEmpty else { return false }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
            files.append(contentsOf: additions)
        }
        if UserDefaults.standard.bool(forKey: "haptics") {
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        }
        return true
    }

    /// Recibe archivos soltados sobre la bandeja.
    func ingest(_ providers: [NSItemProvider]) -> Bool {
        let accepted = Self.loadURLs(providers) { [weak self] urls in
            self?.addFiles(urls)
        }
        return accepted
    }

    /// Lee las URLs de archivo de un arrastre y las devuelve juntas en el hilo principal.
    static func loadURLs(_ providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) -> Bool {
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier("public.file-url") }
        guard !fileProviders.isEmpty else { return false }

        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []
        for provider in fileProviders {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url {
                    lock.lock()
                    urls.append(url)
                    lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            completion(urls)
        }
        return true
    }
}
