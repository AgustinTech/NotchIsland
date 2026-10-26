import AppKit
import Combine
import SwiftUI

enum Player: Hashable {
    case music, spotify

    var appName: String { self == .music ? "Music" : "Spotify" }
    var bundleID: String { self == .music ? "com.apple.Music" : "com.spotify.client" }
    var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    /// Abre (o trae al frente) la aplicación.
    func open() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}

/// Qué suena en Música / Spotify.
/// - Los cambios llegan por notificaciones del sistema (sin polling).
/// - Posición, carátula y botones usan AppleScript (macOS pide permiso de Automatización una vez).
/// - Las letras se piden a lrclib.net (solo se envía título, artista, álbum y duración).
final class NowPlayingModel: ObservableObject {
    @Published var title = ""
    @Published var artist = ""
    @Published var album = ""
    @Published var isPlaying = false
    @Published var artwork: NSImage?
    /// Carátula suavizada para el fondo de la pestaña de música.
    @Published var backdrop: NSImage?
    /// Cuánto de clara es la carátula: se usa para oscurecer más el fondo si hace falta.
    @Published var backdropLuma: Double = 0.4
    @Published var accent: Color = Color.white
    @Published var duration: TimeInterval = 0
    @Published var lyrics: [LyricLine] = []
    @Published var lyricsState: LyricsState = .idle
    @Published var volume: Double = 0.5
    /// Reproductor abierto al que macOS no deja controlar a NotchIsland (permiso de Automatización).
    @Published private(set) var blockedPlayer: Player?

    private var lastVolumeSend = Date.distantPast
    private var current: Player?
    private var trackKey = ""
    /// Invalida lecturas de AppleScript que terminan después de un cambio de reproducción.
    private var refreshRevision = 0
    private var lyricsEnabled = UserDefaults.standard.bool(forKey: "showLyrics")
    private var lyricsRevision = 0
    private var basePosition: TimeInterval = 0
    private var baseStamp = Date()
    private var tokens: [NSObjectProtocol] = []
    private var workspaceTokens: [NSObjectProtocol] = []
    private let queue = DispatchQueue(label: "notchisland.applescript")
    /// Los avisos de permiso pueden quedarse esperando a que contestes: van en su propia cola.
    private let permissionQueue = DispatchQueue(label: "notchisland.permissions")
    private var askedPermission: Set<Player> = []
    private var reconcileTimer: Timer?
    private var permissionPoll: Timer?

    // Cuenta de Spotify (API web): estado y controles en cualquier dispositivo, sin permisos de Automatización.
    let spotify = SpotifyAccount()
    @Published private(set) var spotifyLinked = false
    private var webTimer: Timer?
    private var webBusy = false
    private var lastWebPoll = Date.distantPast
    private var lastWebActive = Date.distantPast
    private var pendingArtworkURL: URL?
    /// Tras saltar en la barra, se ignora la posición que devuelve Spotify un momento (llega con retraso).
    private var seekHoldUntil = Date.distantPast

    /// Lo usa `run` (estático) para avisar de un permiso denegado.
    private static weak var shared: NowPlayingModel?

    var hasTrack: Bool { !title.isEmpty }

    /// Permiso pendiente que merece avisar (con Spotify vinculado ya no hace falta para Spotify).
    var permissionNotice: Player? {
        if blockedPlayer == .spotify && spotifyLinked { return nil }
        return blockedPlayer
    }

    /// Posición actual calculada a partir de la última lectura (no hace falta consultar cada segundo).
    func position(at date: Date = Date()) -> TimeInterval {
        var p = basePosition
        if isPlaying { p += date.timeIntervalSince(baseStamp) }
        p = max(0, p)
        return duration > 0 ? min(p, duration) : p
    }

    private func setBase(_ p: TimeInterval) {
        basePosition = p
        baseStamp = Date()
        objectWillChange.send()
    }

    // MARK: - Arranque

    func start() {
        let center = DistributedNotificationCenter.default()

        tokens.append(center.addObserver(
            forName: Notification.Name("com.apple.Music.playerInfo"),
            object: nil, queue: .main
        ) { [weak self] note in
            self?.handle(note.userInfo, from: .music)
        })

        tokens.append(center.addObserver(
            forName: Notification.Name("com.spotify.client.PlaybackStateChanged"),
            object: nil, queue: .main
        ) { [weak self] note in
            self?.handle(note.userInfo, from: .spotify)
        })

        tokens.append(NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.syncLyricsPreference()
        })

        Self.shared = self
        spotifyLinked = spotify.isLinked
        if spotifyLinked { startWebPolling() }

        // Al abrir o cerrar Música / Spotify: se reconcilia el estado y se piden permisos si hace falta.
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspaceTokens.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let id = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
                guard let player = [Player.music, Player.spotify].first(where: { $0.bundleID == id }) else { return }
                self?.playerAppChanged(player, launched: name == NSWorkspace.didLaunchApplicationNotification)
            })
        }

        for player in [Player.music, Player.spotify] where player.isRunning {
            checkPermission(player, ask: true)
            refresh(player)
        }
        updateReconcile()
    }

    // MARK: - Permiso de Automatización

    /// `ask: true` hace que macOS muestre el aviso de permiso (una sola vez por reproductor y arranque).
    private func checkPermission(_ player: Player, ask: Bool) {
        if ask {
            guard !askedPermission.contains(player) else { return }
            askedPermission.insert(player)
        }
        permissionQueue.async { [weak self] in
            guard player.isRunning else { return }
            let target = NSAppleEventDescriptor(bundleIdentifier: player.bundleID)
            let status = AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, ask)
            DispatchQueue.main.async {
                guard let self else { return }
                if status == noErr {
                    if self.blockedPlayer == player { self.blockedPlayer = nil }
                    self.stopPermissionPoll()
                    if ask { self.refresh(player) }
                } else if status == OSStatus(errAEEventNotPermitted) {
                    self.blockedPlayer = player
                }
            }
        }
    }

    /// Vuelve a mirar el permiso (barato): por ejemplo al abrir la pestaña de música.
    func recheckPermissions() {
        for player in [Player.music, Player.spotify] where player.isRunning {
            checkPermission(player, ask: false)
        }
    }

    /// Abre Ajustes del Sistema > Privacidad > Automatización y espera a que lo concedas.
    func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
        permissionPoll?.invalidate()
        var tries = 0
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] timer in
            tries += 1
            self?.recheckPermissions()
            if tries > 45 || self?.blockedPlayer == nil { timer.invalidate() }
        }
        RunLoop.main.add(timer, forMode: .common)
        permissionPoll = timer
    }

    private func stopPermissionPoll() {
        permissionPoll?.invalidate()
        permissionPoll = nil
    }

    fileprivate static func reportDenied(_ player: Player) {
        DispatchQueue.main.async { shared?.blockedPlayer = player }
    }

    fileprivate static func reportAllowed(_ player: Player) {
        DispatchQueue.main.async {
            if shared?.blockedPlayer == player { shared?.blockedPlayer = nil }
        }
    }

    // MARK: - Reconciliación

    private func playerAppChanged(_ player: Player, launched: Bool) {
        if launched {
            checkPermission(player, ask: true)
        } else if current == player {
            refreshRevision &+= 1
            clear()
        }
        if blockedPlayer == player && !launched { blockedPlayer = nil }
        updateReconcile()
    }

    /// Mientras Música o Spotify estén abiertos se comprueba el estado cada pocos segundos: si se
    /// perdiera un aviso (o cambia la canción sola), la isla se corrige sin tocar nada.
    private func updateReconcile() {
        let running = [Player.music, Player.spotify].contains { $0.isRunning }
        if running, reconcileTimer == nil {
            let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
                guard let self else { return }
                let player = self.current ?? [Player.spotify, Player.music].first { $0.isRunning }
                if let player, player.isRunning { self.refresh(player) }
            }
            timer.tolerance = 2
            RunLoop.main.add(timer, forMode: .common)
            reconcileTimer = timer
        } else if !running {
            reconcileTimer?.invalidate()
            reconcileTimer = nil
        }
    }

    // MARK: - Cuenta de Spotify

    func linkSpotify() {
        guard let id = SpotifySetup.askClientID(current: spotify.clientID) else { return }
        spotify.clientID = id
        spotify.link { [weak self] ok, message in
            guard let self else { return }
            if ok {
                self.spotifyLinked = true
                self.startWebPolling()
            } else if let message {
                SpotifySetup.showError(message)
            }
        }
    }

    func unlinkSpotify() {
        spotify.unlink()
        spotifyLinked = false
        stopWebPolling()
        if current == .spotify && !Player.spotify.isRunning {
            refreshRevision &+= 1
            clear()
        }
    }

    private func startWebPolling() {
        guard webTimer == nil else { return }
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in self?.pollWeb() }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        webTimer = timer
        pollWeb(force: true)
    }

    private func stopWebPolling() {
        webTimer?.invalidate()
        webTimer = nil
    }

    /// Suena: cada 3 s. En pausa o sin nada: cada 6 s.
    private func pollWeb(force: Bool = false) {
        guard spotify.isLinked, !webBusy else { return }
        if !force, !isPlaying, Date().timeIntervalSince(lastWebPoll) < 6 { return }
        webBusy = true
        lastWebPoll = Date()
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self.spotify.playback()
            self.webBusy = false
            self.handleWeb(result)
        }
    }

    private func handleWeb(_ result: SpotifyResult) {
        if !spotify.isLinked {   // la sesión se revocó
            spotifyLinked = false
            stopWebPolling()
            return
        }
        switch result {
        case .failed:
            return
        case .idle:
            if current == .spotify, !Player.spotify.isRunning, Date().timeIntervalSince(lastWebActive) > 8 {
                refreshRevision &+= 1
                clear()
            }
        case .active(let playback):
            // Un "pausado" de Spotify no pisa lo que suena en otro reproductor.
            if !playback.isPlaying, let current, current != .spotify { return }

            // Justo después de saltar en la barra, Spotify aún devuelve la posición vieja.
            let key = "\(Player.spotify)|\(playback.title)|\(playback.artist)"
            if Date() < seekHoldUntil, key == trackKey { return }

            // `progress` corresponde al instante `timestamp`: se suma lo que ha pasado desde entonces.
            var position = playback.progress
            if playback.isPlaying, let stamp = playback.timestamp {
                position += min(max(Date().timeIntervalSince(stamp), 0), 4)
            }

            lastWebActive = Date()
            refreshRevision &+= 1
            pendingArtworkURL = playback.artworkURL
            apply(
                title: playback.title,
                artist: playback.artist,
                album: playback.album,
                playing: playback.isPlaying,
                duration: playback.duration,
                position: position,
                from: .spotify,
                smooth: true
            )
        }
    }

    private var useWeb: Bool { spotifyLinked && current == .spotify }

    /// Controla Spotify por la API web; si falla (cuenta sin Premium, sin dispositivo…) usa AppleScript.
    private func web(_ method: String, _ path: String, query: [String: String] = [:], fallback: @escaping () -> Void) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let status = await self.spotify.send(method, path, query: query)
            if (200..<300).contains(status) {
                try? await Task.sleep(nanoseconds: 1_400_000_000)
            } else {
                fallback()
                try? await Task.sleep(nanoseconds: 600_000_000)
            }
            self.pollWeb(force: true)
        }
    }

    // MARK: - Controles

    func playPause() {
        if useWeb {
            let wasPlaying = isPlaying
            let p = position()
            isPlaying.toggle()
            setBase(p)
            web("PUT", wasPlaying ? "pause" : "play") { [weak self] in _ = self?.send("playpause") }
            return
        }
        guard send("playpause") else { return }
        // Se anticipa el cambio de icono, pero el estado real lo confirma el reproductor enseguida.
        let p = position()
        isPlaying.toggle()
        setBase(p)
        if let player = current {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.refresh(player) }
        }
    }

    func next() {
        if useWeb { web("POST", "next") { [weak self] in _ = self?.send("next track") }; return }
        _ = send("next track")
    }

    func previous() {
        if position() > 3 {
            seekHoldUntil = Date().addingTimeInterval(2)
            setBase(0)   // con más de 3 s, "anterior" reinicia la canción
        }
        if useWeb { web("POST", "previous") { [weak self] in _ = self?.send("previous track") }; return }
        _ = send("previous track")
    }

    func seek(to time: TimeInterval) {
        seekHoldUntil = Date().addingTimeInterval(2.5)
        if useWeb {
            refreshRevision &+= 1
            setBase(time)
            web("PUT", "seek", query: ["position_ms": String(Int(time * 1000))]) { [weak self] in
                guard let self, let player = self.target() else { return }
                let value = String(format: "%.1f", time)
                self.queue.async { _ = Self.run("tell application \"\(player.appName)\" to set player position to \(value)", player: player) }
            }
            return
        }
        guard let player = target() else { return }
        refreshRevision &+= 1
        setBase(time)
        let value = String(format: "%.1f", time)
        let script = "tell application \"\(player.appName)\" to set player position to \(value)"
        queue.async {
            _ = Self.run(script, player: player)
        }
    }

    var sourceName: String { (current ?? .music).appName }

    func openSource() {
        (target() ?? current ?? .music).open()
    }

    // MARK: - Volumen del sistema

    func refreshVolume() {
        queue.async { [weak self] in
            let result = Self.run("output volume of (get volume settings)")
            guard let value = result?.int32Value, value >= 0, value <= 100 else { return }
            DispatchQueue.main.async { self?.volume = Double(value) / 100 }
        }
    }

    /// Cambios de volumen que vienen de fuera (teclas, Centro de Control): la barra los sigue.
    func syncVolume(_ value: Double) {
        guard Date().timeIntervalSince(lastVolumeSend) > 0.4 else { return }
        if abs(volume - value) > 0.005 { volume = value }
    }

    func setVolume(_ value: Double) {
        volume = value
        guard Date().timeIntervalSince(lastVolumeSend) > 0.05 else { return }
        commitVolume()
    }

    func commitVolume() {
        lastVolumeSend = Date()
        let percent = Int((volume * 100).rounded())
        queue.async {
            _ = Self.run("set volume output volume \(percent)")
        }
    }

    private func target() -> Player? {
        let candidate = current ?? [Player.music, Player.spotify].first(where: { $0.isRunning })
        guard let player = candidate, player.isRunning else { return nil }
        return player
    }

    @discardableResult
    private func send(_ command: String) -> Bool {
        guard let player = target() else { return false }
        refreshRevision &+= 1
        let script = "tell application \"\(player.appName)\" to \(command)"
        queue.async {
            _ = Self.run(script, player: player)
        }
        return true
    }

    // MARK: - Estado

    private func handle(_ info: [AnyHashable: Any]?, from player: Player) {
        guard let info = info else { return }
        let state = (info["Player State"] as? String ?? "").lowercased()

        // Si suena Spotify, un "pausado" de Música (o al revés) no debe cambiar lo que se muestra.
        if let current, current != player, state != "playing" { return }

        if state == "stopped" {
            if current == player {
                refreshRevision &+= 1
                clear()
            }
            return
        }

        refreshRevision &+= 1

        let milliseconds = ((info["Total Time"] ?? info["Duration"]) as? NSNumber)?.doubleValue
        let position = (info["Playback Position"] as? NSNumber)?.doubleValue

        apply(
            title: info["Name"] as? String ?? "",
            artist: info["Artist"] as? String ?? "",
            album: info["Album"] as? String ?? "",
            playing: state == "playing",
            duration: milliseconds.map { $0 / 1000 },
            position: position,
            from: player
        )
        // Lectura exacta de la posición (y duración) por AppleScript.
        refresh(player)
    }

    private func apply(
        title: String,
        artist: String,
        album: String,
        playing: Bool,
        duration: TimeInterval?,
        position: TimeInterval?,
        from player: Player,
        smooth: Bool = false
    ) {
        let key = "\(player)|\(title)|\(artist)"
        let changed = key != trackKey
        let carried = changed ? 0 : self.position()   // se calcula con el estado anterior
        let wasPlaying = isPlaying

        current = player
        self.title = title
        self.artist = artist
        if !album.isEmpty || changed { self.album = album }
        isPlaying = playing

        if let d = duration, d > 0 {
            self.duration = d
        } else if changed {
            self.duration = 0
        }
        // Con lecturas periódicas, la barra solo se recoloca si se desvía de verdad (sin tirones).
        if smooth, !changed, wasPlaying == playing, let position, abs(position - carried) < 1.2 {
            objectWillChange.send()
        } else {
            setBase(position ?? carried)
        }

        if changed {
            trackKey = key
            artwork = nil
            backdrop = nil
            accent = Color.white
            lyrics = []
            lyricsState = .idle
            fetchArtwork(for: player, key: key)
            fetchLyrics(key: key)
        }
    }

    private func clear() {
        current = nil
        trackKey = ""
        title = ""
        artist = ""
        album = ""
        isPlaying = false
        artwork = nil
        backdrop = nil
        accent = Color.white
        duration = 0
        lyrics = []
        lyricsState = .idle
        lyricsRevision &+= 1
        setBase(0)
    }

    private func refresh(_ player: Player) {
        guard player.isRunning else { return }
        if player == .spotify, spotifyLinked, Date().timeIntervalSince(lastWebActive) < 8 { return }
        let revision = refreshRevision
        let script = """
        tell application "\(player.appName)"
            if player state is stopped then return ""
            set tr to current track
            set n to name of tr
            set a to artist of tr
            set al to album of tr
            set st to player state as text
            set pos to player position as text
            set du to duration of tr as text
            return n & "||" & a & "||" & al & "||" & st & "||" & pos & "||" & du
        end tell
        """
        queue.async { [weak self] in
            guard let text = Self.run(script, player: player)?.stringValue else { return }
            if text.isEmpty {
                // El reproductor está parado: si era el que mostrábamos, se limpia.
                DispatchQueue.main.async {
                    guard let self, self.refreshRevision == revision, self.current == player else { return }
                    self.clear()
                }
                return
            }
            let parts = text.components(separatedBy: "||")
            guard parts.count >= 6 else { return }

            func number(_ s: String) -> Double {
                Double(s.replacingOccurrences(of: ",", with: ".")) ?? 0
            }
            let position = number(parts[4])
            var duration = number(parts[5])
            if player == .spotify { duration /= 1000 }   // Spotify da milisegundos

            DispatchQueue.main.async {
                guard let self, self.refreshRevision == revision else { return }
                self.apply(
                    title: parts[0],
                    artist: parts[1],
                    album: parts[2],
                    playing: parts[3].lowercased() == "playing",
                    duration: duration,
                    position: position,
                    from: player
                )
            }
        }
    }

    // MARK: - Carátula (mejor esfuerzo)

    private func fetchArtwork(for player: Player, key: String) {
        let webURL = player == .spotify ? pendingArtworkURL : nil
        guard player.isRunning || webURL != nil else { return }
        queue.async { [weak self] in
            switch player {
            case .spotify:
                var resolved = webURL
                if resolved == nil {
                    let script = "tell application \"Spotify\" to artwork url of current track"
                    resolved = Self.run(script, player: .spotify)?.stringValue.flatMap { URL(string: $0) }
                }
                guard let url = resolved else { return }
                URLSession.shared.dataTask(with: url) { data, _, _ in
                    guard let data = data, let image = NSImage(data: data) else { return }
                    DispatchQueue.main.async {
                        self?.setArtwork(image, key: key)
                    }
                }.resume()

            case .music:
                let script = "tell application \"Music\" to get data of artwork 1 of current track"
                guard let data = Self.run(script, player: .music)?.data,
                      let image = NSImage(data: data) else { return }
                DispatchQueue.main.async {
                    self?.setArtwork(image, key: key)
                }
            }
        }
    }

    private func setArtwork(_ image: NSImage, key: String) {
        guard trackKey == key else { return }
        artwork = image
        backdrop = image.softBackdrop()
        backdropLuma = image.averageLuma()
        accent = image.dominantAccent() ?? Color.white
    }

    // MARK: - Letras sincronizadas (lrclib.net)

    private func syncLyricsPreference() {
        let enabled = UserDefaults.standard.bool(forKey: "showLyrics")
        guard enabled != lyricsEnabled else { return }
        lyricsEnabled = enabled

        if enabled {
            if hasTrack { fetchLyrics(key: trackKey) }
        } else {
            lyricsRevision &+= 1
            lyrics = []
            lyricsState = .idle
        }
    }

    private func fetchLyrics(key: String) {
        guard lyricsEnabled else { return }
        lyricsRevision &+= 1
        let revision = lyricsRevision
        lyricsState = .loading

        let track = title
        let artistName = artist
        let albumName = album
        let seconds = duration

        var exact = URLComponents(string: "https://lrclib.net/api/get")
        var items = [
            URLQueryItem(name: "track_name", value: track),
            URLQueryItem(name: "artist_name", value: artistName)
        ]
        if !albumName.isEmpty { items.append(URLQueryItem(name: "album_name", value: albumName)) }
        if seconds > 0 { items.append(URLQueryItem(name: "duration", value: String(Int(seconds.rounded())))) }
        exact?.queryItems = items

        var search = URLComponents(string: "https://lrclib.net/api/search")
        search?.queryItems = [
            URLQueryItem(name: "track_name", value: track),
            URLQueryItem(name: "artist_name", value: artistName)
        ]

        Self.getJSON(exact?.url) { [weak self] first in
            guard UserDefaults.standard.bool(forKey: "showLyrics") else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.lyricsEnabled, self.trackKey == key,
                      self.lyricsRevision == revision else { return }
                if let object = first as? [String: Any],
                   let lrc = object["syncedLyrics"] as? String, !lrc.isEmpty {
                    self.finishLyrics(LRC.parse(lrc), key: key, revision: revision)
                    return
                }
                // Solo consulta la búsqueda flexible si esta pista aún necesita letra.
                Self.getJSON(search?.url) { [weak self] second in
                    let list = second as? [[String: Any]] ?? []
                    let lrc = list.compactMap { $0["syncedLyrics"] as? String }.first { !$0.isEmpty }
                    self?.finishLyrics(lrc.map { LRC.parse($0) } ?? [], key: key, revision: revision)
                }
            }
        }
    }

    private func finishLyrics(_ lines: [LyricLine], key: String, revision: Int) {
        DispatchQueue.main.async {
            guard self.lyricsEnabled, self.trackKey == key,
                  self.lyricsRevision == revision else { return }
            self.lyrics = lines
            self.lyricsState = lines.isEmpty ? .missing : .found
        }
    }

    private static func getJSON(_ url: URL?, completion: @escaping (Any?) -> Void) {
        guard let url = url else {
            completion(nil)
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("NotchIsland/0.2 (uso personal)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { data, response, _ in
            guard let data = data, (response as? HTTPURLResponse)?.statusCode == 200 else {
                completion(nil)
                return
            }
            completion(try? JSONSerialization.jsonObject(with: data))
        }.resume()
    }

    // MARK: - AppleScript

    /// Ejecuta AppleScript. Si se indica el reproductor, se anota si macOS bloquea el permiso (-1743).
    private static func run(_ source: String, player: Player? = nil) -> NSAppleEventDescriptor? {
        var errorInfo: NSDictionary?
        let result: NSAppleEventDescriptor? = NSAppleScript(source: source)?.executeAndReturnError(&errorInfo)
        if let errorInfo = errorInfo {
            let code = (errorInfo[NSAppleScript.errorNumber] as? NSNumber)?.intValue
            if let player, code == -1743 { reportDenied(player) }
            NSLog("NotchIsland AppleScript: %@", errorInfo)
            return nil
        }
        if let player { reportAllowed(player) }
        return result
    }
}
