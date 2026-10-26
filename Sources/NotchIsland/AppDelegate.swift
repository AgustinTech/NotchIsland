import AppKit
import Combine
import ServiceManagement
import SwiftUI

/// Contiene la vista de SwiftUI (de tamaño fijo) pegada arriba y centrada, sea cual sea el tamaño
/// de la ventana. Se coloca a mano en cada cambio de tamaño: el autoresizing de AppKit la dejaba
/// pegada a la izquierda cuando la ventana era más estrecha que la vista.
final class HostContainer: NSView {
    var hosted: NSView? {
        didSet { place() }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        place()
    }

    func resizeHosted(to size: NSSize) {
        hosted?.setFrameSize(size)
        place()
    }

    private func place() {
        guard let hosted else { return }
        let size = hosted.frame.size
        hosted.setFrameOrigin(NSPoint(
            x: ((bounds.width - size.width) / 2).rounded(),
            y: bounds.height - size.height
        ))
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let state = IslandState()
    private let player = NowPlayingModel()
    private let power = PowerModel()
    private let services = Services()
    private let bluetooth = BluetoothWatcher()
    private let hudMonitor = SystemHUDMonitor()
    private let mediaKeys = MediaKeyInterceptor()
    private let meetings = MeetingAlertCenter()
    private var geometry = NotchGeometry.detect()

    private var panel: NotchPanel!
    private var settingsWindow: NSWindow?
    private var appliedVisualSize = ""
    private var statusItem: NSStatusItem?
    private var menu: NSMenu?
    private var toggleItems: [NSMenuItem] = []
    private var hudStatusItem: NSMenuItem?
    private var spotifyMenuItem: NSMenuItem?
    private var loginMenuItem: NSMenuItem?
    private var monitors: [Any] = []
    private var cancellables = Set<AnyCancellable>()

    private var pendingOpen: DispatchWorkItem?
    private var pendingClose: DispatchWorkItem?
    private var transientWork: DispatchWorkItem?
    private var shrinkWork: DispatchWorkItem?

    private var scrollAccum: CGFloat = 0
    private var scrollAccumX: CGFloat = 0
    private var scrollConsumed = false
    /// Tras cambiar de pestaña con un deslizamiento, lo que queda de ese gesto no mueve nada debajo.
    private var swallowScroll = false

    private let hotkey = GlobalHotkey()
    /// Abierta con el atajo: no se cierra sola aunque el puntero esté lejos, hasta que entre en la isla.
    private var hotkeyHold = false
    /// Abierta con el atajo: Esc la cierra mientras siga abierta.
    private var hotkeySummoned = false

    /// Tras cerrar con el puntero encima, el hover espera a que salga de la zona (ver `HoverGuard`).
    private var hoverGuard = HoverGuard()
    /// `changeCount` de la pasteboard de arrastre al pulsar el botón (para reconocer arrastres de archivos).
    private var dragBaseline: Int?

    private var defaults: UserDefaults { .standard }

    // MARK: - Ciclo de vida

    func applicationDidFinishLaunching(_ notification: Notification) {
        applyGeometry()

        panel = NotchPanel(
            contentRect: currentWindowFrame(),
            styleMask: [],
            backing: .buffered,
            defer: false
        )
        let host = NSHostingView(
            rootView: IslandView(state: state, player: player, power: power, services: services)
        )
        // Sin esto SwiftUI cambia el tamaño de la ventana por su cuenta (al de la forma)
        // y pelea con nuestro ajuste: la isla se descentraba y se veía rara.
        host.sizingOptions = []

        // La vista de SwiftUI tiene SIEMPRE el tamaño de la isla abierta (más margen) y va pegada
        // arriba y centrada dentro de un contenedor. La ventana crece y se encoge, pero SwiftUI no
        // se entera de ningún cambio de tamaño, así que no recoloca nada (antes la isla "subía
        // desde abajo" al abrirse porque SwiftUI centraba su contenido mientras la ventana crecía).
        let hostSize = hostingSize()
        let container = HostContainer(frame: NSRect(origin: .zero, size: panel.frame.size))
        container.autoresizesSubviews = false
        host.autoresizingMask = []
        host.frame = NSRect(origin: .zero, size: hostSize)
        container.addSubview(host)
        container.hosted = host
        panel.contentView = container
        panel.orderFrontRegardless()
        SpaceAnchor.pin(panel)   // no se mueve al cambiar de escritorio con tres dedos

        state.showMenu = { [weak self] in self?.popMenu() }

        // La ventana crece enseguida y se encoge un poco después, cuando la animación ya terminó.
        // Importante: `.receive(on:)` hace que esto ocurra DESPUÉS de aplicar el cambio. Si se
        // redimensiona la ventana en pleno cambio, SwiftUI dibuja con el valor viejo y no repinta.
        Publishers.CombineLatest3(
            state.$expanded.removeDuplicates(),
            state.$liveSide.removeDuplicates(),
            state.$peekHeight.removeDuplicates()
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] expanded, side, peek in
            self?.updateFrame(expanded: expanded, side: side, peek: peek)
        }
        .store(in: &cancellables)

        // Cierre por cualquier vía (gesto, salir del notch…): si el puntero sigue encima, no se reabre solo.
        state.$expanded
            .removeDuplicates()
            .dropFirst()
            .filter { !$0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                let inside = self.hotRect().contains(NSEvent.mouseLocation)
                self.hoverGuard.closed(pointerInside: inside)
                if inside {
                    self.pendingOpen?.cancel()
                    self.pendingOpen = nil
                    if self.state.hovering { self.state.hovering = false }
                }
            }
            .store(in: &cancellables)

        // Los permisos de calendario y ubicación se piden al abrir por primera vez la pestaña "Hoy".
        Publishers.CombineLatest(
            state.$expanded.removeDuplicates(),
            state.$tab.removeDuplicates()
        )
        .sink { [weak self] expanded, tab in
            if expanded && tab == .today {
                self?.services.activate()
            } else {
                self?.services.deactivate()
            }
        }
        .store(in: &cancellables)

        // Ancho extra del notch cerrado según haya música o aviso.
        Publishers.Merge4(player.objectWillChange, state.objectWillChange, state.activity.objectWillChange, state.timer.objectWillChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshLive()
            }
            .store(in: &cancellables)


        // Canción nueva: el notch se despliega un momento con el título.
        player.$title
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] title in
                guard let self, !title.isEmpty, self.player.isPlaying,
                      self.defaults.bool(forKey: "trackPeek") else { return }
                self.showTransient(.track, for: 3.6)
            }
            .store(in: &cancellables)

        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.state.refreshVisualSettings()
            self.refreshVisualSizeIfNeeded()
            self.applyActivitySettings()
            self.applyHUDSettings()
            self.applyHotkeySetting()
            self.refreshLive()
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.updateForScreenChange()
        }

        setupMouseMonitors()
        setupStatusItem()
        setupHotkey()
        IslandPrewarm.start(state: state, host: host, player: player)

        power.onPlug = { [weak self] in
            guard let self, self.defaults.bool(forKey: "chargingPop") else { return }
            self.showTransient(.charging, for: 3.4)
        }
        power.onLow = { [weak self] in
            guard let self, self.defaults.bool(forKey: "lowBatteryAlert") else { return }
            self.showTransient(.lowBattery, for: 4.5)
        }
        power.start()
        player.start()
        services.clipboard.start()

        state.activity.onAirDrop = { [weak self] count, name in
            guard let self, self.flag("airdropActivity") else { return }
            self.showTransient(.airdrop(count: count, name: name), for: 4.5)
        }
        state.activity.onDownloadFinished = { [weak self] count, name in
            guard let self, self.flag("downloadsActivity") else { return }
            self.showTransient(.downloadDone(count: count, name: name), for: 3.2)
        }
        applyActivitySettings()

        // Reuniones: aviso 5 minutos antes y al empezar (solo si el calendario ya tiene permiso).
        meetings.onAlert = { [weak self] alert in
            guard let self, !self.state.expanded else { return false }
            self.showTransient(.meeting(alert), for: alert.duration)
            return true
        }
        meetings.start(calendar: services.calendar)

        // Volumen y brillo: se enseñan en el notch cerrado y se oculta el HUD del sistema.
        hudMonitor.onVolume = { [weak self] level, muted in
            self?.player.syncVolume(level)
            // Sin la intercepción de teclas el sistema muestra su HUD: el del notch saldría duplicado.
            guard let self, self.flag("hudActivity"), self.mediaKeys.isActive else { return }
            self.showTransient(.volume(level: level, muted: muted), for: 1.8, allowExpanded: true)
        }
        hudMonitor.onBrightness = { [weak self] level in
            guard let self, self.flag("hudActivity"), self.mediaKeys.isActive else { return }
            self.showTransient(.brightness(level: level), for: 1.8, allowExpanded: true)
        }
        applyHUDSettings()
        state.timer.onFinish = { [weak self] title in
            self?.showTransient(.timerDone(title: title), for: 6)
        }

        bluetooth.onConnect = { [weak self] name in
            self?.deviceConnected(name)
        }
        if defaults.bool(forKey: "devicePopup") {
            bluetooth.start()
        }
    }

    // MARK: - Ajustes de las actividades (descargas y AirDrop)

    /// Las opciones nuevas están activas mientras el usuario no diga lo contrario.
    private func flag(_ key: String) -> Bool {
        (defaults.object(forKey: key) as? Bool) ?? true
    }

    private func applyHUDSettings() {
        let on = flag("hudActivity")
        if on { hudMonitor.start() } else { hudMonitor.stop() }
        if on && flag("hideSystemHUD") { mediaKeys.start() } else { mediaKeys.stop() }
    }

    private func applyActivitySettings() {
        state.activity.configure(downloads: flag("downloadsActivity"), airdrop: flag("airdropActivity"))
    }



    // MARK: - Geometría

    private func applyGeometry() {
        let detected = NotchGeometry.detect()
        let size = IslandVisualSize(rawValue: defaults.string(forKey: "visualSize") ?? "") ?? .normal
        appliedVisualSize = size.rawValue
        geometry = sizedGeometry(from: detected, size: size)
        state.notchSize = geometry.notchSize
        state.expandedSize = geometry.expandedSize
    }

    private func sizedGeometry(from base: NotchGeometry, size: IslandVisualSize) -> NotchGeometry {
        NotchGeometry(
            screenFrame: base.screenFrame,
            notchSize: base.notchSize,
            expandedSize: CGSize(
                width: min(size.width, max(320, base.screenFrame.width - 88)),
                height: base.notchSize.height + size.extraHeight
            )
        )
    }

    private func refreshVisualSizeIfNeeded() {
        let size = IslandVisualSize(rawValue: defaults.string(forKey: "visualSize") ?? "") ?? .normal
        guard size.rawValue != appliedVisualSize, panel != nil else { return }
        appliedVisualSize = size.rawValue
        // Un cambio de tamaño no cambia de pantalla aunque el ratón esté sobre Ajustes.
        geometry = sizedGeometry(from: geometry, size: size)
        state.expandedSize = geometry.expandedSize
        (panel.contentView as? HostContainer)?.resizeHosted(to: hostingSize())
        panel.setFrame(currentWindowFrame(), display: true)
    }

    private func updateForScreenChange(retries: Int = 3) {
        // Durante una reconexión macOS puede informar de cero pantallas de forma transitoria.
        guard !NSScreen.screens.isEmpty else {
            guard retries > 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.updateForScreenChange(retries: retries - 1)
            }
            return
        }
        applyGeometry()
        (panel.contentView as? HostContainer)?.resizeHosted(to: hostingSize())
        panel.setFrame(currentWindowFrame(), display: true)
    }

    private func hostingSize() -> NSSize {
        NSSize(width: geometry.expandedSize.width + 88, height: geometry.expandedSize.height + 64)
    }

    /// Rectángulo (en pantalla) que ocupa la forma negra, sin el efecto de hover.
    private func islandRect(expanded: Bool, side: CGFloat, peek: CGFloat) -> NSRect {
        let size: CGSize
        if expanded {
            size = geometry.expandedSize
        } else {
            size = CGSize(
                width: geometry.notchSize.width + side * 2,
                height: geometry.notchSize.height + peek
            )
        }
        let screen = geometry.screenFrame
        return NSRect(
            x: screen.midX - size.width / 2,
            y: screen.maxY - size.height,
            width: size.width,
            height: size.height
        )
    }

    /// Ventana = forma + margen para las orejas, el hover y la sombra.
    private func windowFrame(expanded: Bool, side: CGFloat, peek: CGFloat) -> NSRect {
        let rect = islandRect(expanded: expanded, side: side, peek: peek)
        let padX: CGFloat = expanded ? 44 : 24
        let padY: CGFloat = expanded ? 64 : 8
        return NSRect(
            x: rect.minX - padX,
            y: rect.minY - padY,
            width: rect.width + padX * 2,
            height: rect.height + padY
        )
    }

    private func currentWindowFrame() -> NSRect {
        windowFrame(expanded: state.expanded, side: state.liveSide, peek: state.peekHeight)
    }

    /// Los valores llegan del propio cambio: leer `state` aquí daría el valor anterior.
    private func updateFrame(expanded: Bool, side: CGFloat, peek: CGFloat) {
        let target = windowFrame(expanded: expanded, side: side, peek: peek)
        let current = panel.frame
        let grown = current.union(target)

        // Crece al instante (para no recortar la animación) y se encoge cuando ya terminó.
        if grown != current {
            panel.setFrame(grown, display: true)
        }
        shrinkWork?.cancel()
        if grown != target {
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.panel.setFrame(self.currentWindowFrame(), display: true)
            }
            shrinkWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
        }
    }

    // MARK: - Actividad en vivo y avisos

    private func refreshLive() {
        var side: CGFloat = 0
        var peek: CGFloat = 0

        switch state.transient {
        case .charging?, .lowBattery?:
            side = 46
        case .device?:
            side = 46
            peek = IslandState.peek
        case .track?:
            side = 40
            peek = IslandState.peek
        case .airdrop?, .downloadDone?:
            side = 50
            peek = IslandState.peek
        case .meeting?:
            side = 50
            peek = IslandState.peek
        case .timerDone?:
            side = 50
            peek = IslandState.peek
        case .volume?, .brightness?:
            side = 46
            peek = IslandState.peek
        case nil:
            // Prioridad: avisos cortos > descargas en curso > música.
            if state.activity.downloads != nil {
                side = 50
                peek = IslandState.peek
            } else if state.timer.showsLive {
                side = TimerModel.liveSide
                peek = IslandState.peek
            } else if defaults.bool(forKey: "liveActivity") && player.isPlaying && player.hasTrack {
                side = 38
            }
        }

        if side != state.liveSide { state.liveSide = side }
        if peek != state.peekHeight { state.peekHeight = peek }
    }

    private func showTransient(_ value: IslandTransient, for seconds: Double, allowExpanded: Bool = false) {
        guard allowExpanded || !state.expanded else { return }
        transientWork?.cancel()
        state.transient = value

        let work = DispatchWorkItem { [weak self] in
            self?.state.transient = nil
        }
        transientWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func deviceConnected(_ name: String) {
        guard defaults.bool(forKey: "devicePopup") else { return }
        // La batería tarda un par de segundos en estar disponible tras conectar.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in
            guard let self else { return }
            self.services.devices.refresh(force: true) {
                let info = self.services.devices.info(for: name)
                self.showTransient(.device(name: name, icon: info.icon, percent: info.percent), for: 4)
            }
        }
    }

    // MARK: - Ratón (abrir al pasar por el notch, cerrar al salir)

    private func setupMouseMonitors() {
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown, .leftMouseDragged, .scrollWheel]

        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.handle(event)
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.handle(event)
            return self?.swallowsScroll(event) == true ? nil : event
        }) {
            monitors.append(local)
        }
    }

    private func hotRect() -> NSRect {
        islandRect(expanded: false, side: state.liveSide, peek: state.peekHeight)
            .insetBy(dx: -8, dy: -4)
    }

    private func keepOpenRect() -> NSRect {
        islandRect(expanded: true, side: 0, peek: 0).insetBy(dx: -14, dy: -14)
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .scrollWheel:
            handleScroll(event)
        case .leftMouseDown:
            dragBaseline = NSPasteboard(name: .drag).changeCount
        default:
            handleMove(dragging: event.type == .leftMouseDragged)
        }
    }

    private func handleMove(dragging: Bool) {
        let point = NSEvent.mouseLocation

        if state.expanded {
            if keepOpenRect().contains(point) {
                hotkeyHold = false   // el puntero ha entrado: desde aquí manda el hover de siempre
                pendingClose?.cancel()
                pendingClose = nil
            } else if !dragging, !state.pinned, !hotkeyHold, pendingClose == nil {
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.pendingClose = nil
                    if !self.keepOpenRect().contains(NSEvent.mouseLocation) && !self.state.pinned {
                        self.state.close()
                    }
                }
                pendingClose = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
            }
            return
        }

        let inside = hotRect().contains(point)
        // Recién cerrado con el puntero encima: no se rearma el hover hasta que salga de la zona.
        let armed = hoverGuard.pointerMoved(inside: inside)
        if state.hovering != (inside && armed) { state.hovering = inside && armed }

        guard inside, armed else {
            pendingOpen?.cancel()
            pendingOpen = nil
            return
        }
        guard pendingOpen == nil else { return }

        // Un arrastre solo abre el notch si lleva archivos (y es el arrastre actual, no uno antiguo).
        let drag = NSPasteboard(name: .drag)
        let draggingFiles = dragging
            && FileDragProbe.isFileDrag(baseline: dragBaseline, current: drag.changeCount, types: drag.types)
        if dragging && !draggingFiles { return }

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingOpen = nil
            guard self.hotRect().contains(NSEvent.mouseLocation) else { return }
            self.state.open(draggingFiles ? .tray : nil)
        }
        pendingOpen = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (draggingFiles ? 0.05 : 0.14), execute: work)
    }

    /// Dos dedos hacia abajo sobre el notch lo abren; hacia arriba lo cierran.
    private func handleScroll(_ event: NSEvent) {
        guard defaults.bool(forKey: "swipeGesture"), event.hasPreciseScrollingDeltas else { return }

        if event.phase == .began || event.phase == .mayBegin {
            scrollAccum = 0
            scrollAccumX = 0
            scrollConsumed = false
            swallowScroll = false
        }
        if event.phase == .ended || event.phase == .cancelled {
            scrollAccum = 0
            scrollAccumX = 0
            scrollConsumed = false
            return
        }
        guard !scrollConsumed, !event.phase.isEmpty else { return }

        let fingerDown: CGFloat = event.isDirectionInvertedFromDevice ? 1 : -1
        scrollAccum += event.scrollingDeltaY * fingerDown
        // Hacia la derecha = dedos a la derecha (con o sin desplazamiento natural).
        scrollAccumX += event.scrollingDeltaX * fingerDown
        let point = NSEvent.mouseLocation

        if !state.expanded, scrollAccum > 10, hotRect().contains(point) {
            scrollConsumed = true
            state.open()
        } else if state.expanded, scrollAccum < -45, keepOpenRect().contains(point), abs(scrollAccumX) < abs(scrollAccum) {
            scrollConsumed = true
            state.close()
        } else if state.expanded, abs(scrollAccumX) > 40, abs(scrollAccumX) > abs(scrollAccum) * 1.6, keepOpenRect().contains(point) {
            // Dedos a la izquierda: pestaña siguiente (el contenido nuevo entra por la derecha); a la derecha: la anterior.
            scrollConsumed = true
            swallowScroll = state.shiftTab(scrollAccumX < 0 ? 1 : -1)
        }
    }

    /// Tras un cambio de pestaña por deslizamiento, el resto del gesto (y su inercia) no llega a la pestaña nueva.
    private func swallowsScroll(_ event: NSEvent) -> Bool {
        swallowScroll && event.type == .scrollWheel && (!event.phase.isEmpty || !event.momentumPhase.isEmpty)
    }

    // MARK: - Atajo global (⌃⌥N) y Esc

    private func setupHotkey() {
        hotkey.onToggle = { [weak self] in self?.hotkeyToggle() }
        hotkey.onEscape = { [weak self] in self?.dismissFromHotkey() }
        applyHotkeySetting()

        // Cuando la isla se cierra, sea por lo que sea, se suelta Esc y la espera del puntero.
        state.$expanded
            .removeDuplicates()
            .filter { !$0 }
            .sink { [weak self] _ in self?.releaseHotkey() }
            .store(in: &cancellables)
        // Con un menú o un selector de archivos abierto, Esc es suyo.
        state.onPinChange = { [weak self] in self?.syncEscape() }

        // Clic fuera de la isla abierta con el atajo: se cierra, como un popover.
        if let clicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] _ in
            guard let self, self.hotkeyHold, self.state.expanded, !self.state.pinned else { return }
            if !self.keepOpenRect().contains(NSEvent.mouseLocation) { self.dismissFromHotkey() }
        }) {
            monitors.append(clicks)
        }
        // Esc con la isla ya enfocada (después de pulsar algo en ella).
        if let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard let self, event.keyCode == 53, event.window === self.panel, self.state.expanded else { return event }
            self.dismissFromHotkey()
            return nil
        }) {
            monitors.append(keys)
        }
    }

    private func applyHotkeySetting() {
        let enabled = flag("hotkeyEnabled")
        hotkey.setEnabled(enabled)
        if !enabled { releaseHotkey() }
    }

    private func hotkeyToggle() {
        guard !state.pinned else { return }
        if state.expanded {
            dismissFromHotkey()
            return
        }
        pendingOpen?.cancel()
        pendingOpen = nil
        pendingClose?.cancel()
        pendingClose = nil
        hotkeyHold = true
        hotkeySummoned = true
        syncEscape()
        state.open()
    }

    /// Cierra con el atajo o con Esc (el `HoverGuard` evita que el hover lo reabra si el puntero sigue encima).
    private func dismissFromHotkey() {
        guard state.expanded else { return }
        pendingClose?.cancel()
        pendingClose = nil
        state.close()
    }

    private func releaseHotkey() {
        hotkeyHold = false
        hotkeySummoned = false
        syncEscape()
    }

    private func syncEscape() {
        hotkey.setEscapeArmed(hotkeySummoned && !state.pinned)
    }

    // MARK: - Menú de ajustes (icono de la barra y botón "…" del notch)

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "capsule.tophalf.filled", accessibilityDescription: "NotchIsland")
            if button.image == nil { button.title = "◖" }
        }

        let menu = NSMenu()
        menu.autoenablesItems = false   // los estados (activo / desactivado) los fijamos nosotros

        // Agrupado por tema, con submenús: abajo solo queda lo que se usa a menudo.
        menu.addItem(group("Música", symbol: "music.note") { sub in
            sub.addItem(self.toggle("Música en el notch cerrado", "liveActivity", "Carátula y ecualizador mientras suena"))
            sub.addItem(self.toggle("Aviso al cambiar de canción", "trackPeek", "Muestra título y artista unos segundos"))
            sub.addItem(self.toggle("Letras sincronizadas", "showLyrics", "Letra en tiempo real bajo el título"))
            sub.addItem(.separator())
            let spotify = NSMenuItem(title: "Vincular cuenta de Spotify…", action: #selector(self.toggleSpotify(_:)), keyEquivalent: "")
            spotify.target = self
            spotify.image = Self.icon("link")
            sub.addItem(spotify)
            self.spotifyMenuItem = spotify
        })

        menu.addItem(group("Avisos en el notch", symbol: "bell.badge") { sub in
            sub.addItem(self.toggle("Cargador conectado", "chargingPop"))
            sub.addItem(self.toggle("Batería baja", "lowBatteryAlert", "Al llegar al 20 % y al 10 %"))
            sub.addItem(self.toggle("AirPods y auriculares", "devicePopup", "Al conectarse, con su batería"))
            sub.addItem(self.toggle("Descargas con progreso", "downloadsActivity"))
            sub.addItem(self.toggle("Archivos recibidos por AirDrop", "airdropActivity"))
            sub.addItem(self.toggle("Reuniones del calendario", "meetingAlerts", "Avisa unos minutos antes de que empiece"))
        })

        menu.addItem(group("Volumen y brillo", symbol: "speaker.wave.2.fill") { sub in
            sub.addItem(self.toggle("Mostrar en el notch", "hudActivity", "En vez del panel del sistema"))
            sub.addItem(self.toggle("Ocultar el panel del sistema", "hideSystemHUD", "Necesita el permiso de Accesibilidad"))
            sub.addItem(.separator())
            let status = NSMenuItem(title: "Conceder permiso de Accesibilidad…", action: #selector(self.enableHUD(_:)), keyEquivalent: "")
            status.target = self
            status.image = Self.icon("hand.raised.fill")
            sub.addItem(status)
            self.hudStatusItem = status
        })

        menu.addItem(group("Portapapeles", symbol: "doc.on.clipboard") { sub in
            sub.addItem(self.toggle("Guardar historial", "clipboardHistory", "No guarda contraseñas ni contenido privado"))
        })

        menu.addItem(group("Gestos y respuesta", symbol: "hand.tap") { sub in
            sub.addItem(self.toggle("Gestos de dos dedos", "swipeGesture", "Abrir, cerrar y cambiar de pestaña deslizando"))
            sub.addItem(self.toggle("Atajo \(GlobalHotkey.toggle.label)", "hotkeyEnabled", "Abre y cierra la isla desde cualquier app"))
            sub.addItem(self.toggle("Respuesta háptica", "haptics", "Un toque suave al abrir"))
        })

        menu.addItem(.separator())

        let appearance = NSMenuItem(title: "Ajustes visuales…", action: #selector(openVisualSettings(_:)), keyEquivalent: ",")
        appearance.target = self
        appearance.image = Self.icon("slider.horizontal.3")
        menu.addItem(appearance)

        let login = NSMenuItem(title: "Abrir al iniciar sesión", action: #selector(toggleLogin(_:)), keyEquivalent: "")
        login.target = self
        login.image = Self.icon("power")
        menu.addItem(login)
        loginMenuItem = login

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Salir de NotchIsland", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.image = Self.icon("xmark.circle")
        menu.addItem(quit)

        refreshMenuStates(menu)
        item.menu = menu
        self.menu = menu
        statusItem = item
    }

    // MARK: Piezas del menú

    private static func icon(_ symbol: String) -> NSImage? {
        NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    }

    /// Elemento con casilla ligado a una opción (`UserDefaults`), con una línea de ayuda opcional.
    private func toggle(_ title: String, _ key: String, _ subtitle: String? = nil) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: #selector(toggleDefault(_:)), keyEquivalent: "")
        entry.target = self
        entry.representedObject = key
        if #available(macOS 14.4, *), let subtitle { entry.subtitle = subtitle }
        toggleItems.append(entry)
        return entry
    }

    /// Entrada de primer nivel con icono y un submenú.
    private func group(_ title: String, symbol: String, build: (NSMenu) -> Void) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        entry.image = Self.icon(symbol)
        let sub = NSMenu(title: title)
        sub.autoenablesItems = false
        build(sub)
        entry.submenu = sub
        return entry
    }

    private func refreshMenuStates(_ menu: NSMenu) {
        for entry in toggleItems {
            if let key = entry.representedObject as? String {
                entry.state = defaults.bool(forKey: key) ? .on : .off
            }
        }
        if let status = hudStatusItem {
            let active = mediaKeys.isActive
            status.title = active ? "Accesibilidad concedida: el panel del sistema se oculta" : "Conceder permiso de Accesibilidad…"
            status.isEnabled = !active
            status.state = active ? .on : .off
        }
        if let spotify = spotifyMenuItem {
            spotify.title = player.spotifyLinked ? "Desvincular cuenta de Spotify" : "Vincular cuenta de Spotify…"
            spotify.image = Self.icon(player.spotifyLinked ? "link.badge.plus" : "link")
            if #available(macOS 14.4, *) {
                spotify.subtitle = player.spotifyLinked ? "Cuenta vinculada" : "Para leer y controlar lo que suena en cualquier dispositivo"
            }
        }
        loginMenuItem?.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    private func popMenu() {
        guard let menu else { return }
        refreshMenuStates(menu)
        state.pinned = true
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        state.pinned = false
    }

    @objc private func toggleDefault(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        defaults.set(!defaults.bool(forKey: key), forKey: key)
        sender.state = defaults.bool(forKey: key) ? .on : .off
        if key == "devicePopup", defaults.bool(forKey: key) {
            bluetooth.start()
        }
    }

    @objc private func openVisualSettings(_ sender: NSMenuItem) {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 420, height: 510),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Ajustes de NotchIsland"
            window.contentView = NSHostingView(rootView: SettingsView(state: state))
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func enableHUD(_ sender: NSMenuItem) {
        defaults.set(true, forKey: "hudActivity")
        defaults.set(true, forKey: "hideSystemHUD")
        applyHUDSettings()
        mediaKeys.requestPermission()
    }

    @objc private func toggleSpotify(_ sender: NSMenuItem) {
        if player.spotifyLinked {
            player.unlinkSpotify()
        } else {
            player.linkSpotify()
        }
    }

    @objc private func toggleLogin(_ sender: NSMenuItem) {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            NSLog("NotchIsland login item: %@", "\(error)")
        }
        sender.state = service.status == .enabled ? .on : .off
    }
}
