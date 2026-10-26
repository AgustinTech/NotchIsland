import AppKit
import CryptoKit
import Network

/// Lo que está sonando según la API web de Spotify.
struct SpotifyPlayback {
    var title: String
    var artist: String
    var album: String
    var isPlaying: Bool
    var progress: TimeInterval
    var duration: TimeInterval
    var artworkURL: URL?
    /// Momento (reloj de Spotify) al que corresponde `progress`.
    var timestamp: Date?
}

enum SpotifyResult {
    case active(SpotifyPlayback)
    /// Nada sonando (ningún dispositivo activo).
    case idle
    /// Sin red o error del servidor: no se cambia nada.
    case failed
}

/// Cuenta de Spotify vinculada con el inicio de sesión oficial (OAuth con PKCE, sin secreto).
/// Los tokens se guardan en el Llavero. Cada persona usa su propio Client ID de
/// developer.spotify.com/dashboard (la app no lleva ninguna clave dentro).
final class SpotifyAccount {
    static let redirectPort: UInt16 = 53682
    static let redirectURI = "http://127.0.0.1:53682/callback"
    private static let scope = "user-read-playback-state user-modify-playback-state user-read-currently-playing"
    private static let clientKey = "spotifyClientID"

    private struct Tokens: Codable {
        var access: String
        var refresh: String
        var expires: Date
    }

    private var tokens: Tokens?
    private var listener: NWListener?
    private var listenerTimeout: DispatchWorkItem?

    init() {
        tokens = Keychain.load()
    }

    var isLinked: Bool { tokens != nil }

    var clientID: String? {
        get {
            let value = UserDefaults.standard.string(forKey: Self.clientKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (value?.isEmpty ?? true) ? nil : value
        }
        set { UserDefaults.standard.set(newValue, forKey: Self.clientKey) }
    }

    func unlink() {
        tokens = nil
        Keychain.delete()
    }

    // MARK: - Vincular

    /// Abre el navegador para iniciar sesión en Spotify y espera la respuesta en un puerto local.
    func link(completion: @escaping (Bool, String?) -> Void) {
        guard let clientID else {
            completion(false, "Falta el Client ID.")
            return
        }
        stopListener()

        let verifier = Self.randomString(64)
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = Self.randomString(16)

        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        guard let port = NWEndpoint.Port(rawValue: Self.redirectPort),
              let listener = try? NWListener(using: parameters, on: port) else {
            completion(false, "No se pudo abrir el puerto local \(Self.redirectPort) para recibir la respuesta de Spotify.")
            return
        }
        self.listener = listener

        var finished = false
        func finish(_ ok: Bool, _ message: String?) {
            guard !finished else { return }
            finished = true
            DispatchQueue.main.async {
                self.stopListener()
                completion(ok, message)
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .global(qos: .userInitiated))
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                let request = String(data: data ?? Data(), encoding: .utf8) ?? ""
                let line = request.components(separatedBy: "\r\n").first ?? ""
                let target = line.split(separator: " ").dropFirst().first.map(String.init) ?? ""
                let items = URLComponents(string: "http://127.0.0.1" + target)?.queryItems ?? []
                let code = items.first { $0.name == "code" }?.value
                let returnedState = items.first { $0.name == "state" }?.value
                let error = items.first { $0.name == "error" }?.value

                let ok = code != nil && returnedState == state
                let page = Self.responsePage(success: ok)
                connection.send(content: page.data(using: .utf8), completion: .contentProcessed { _ in connection.cancel() })

                guard target.hasPrefix("/callback") else { return }
                guard ok, let code else {
                    finish(false, error == "access_denied" ? "Cancelaste el acceso a Spotify." : "Spotify no devolvió el código de acceso.")
                    return
                }
                guard let self else { return }
                Task { @MainActor in
                    let result = await self.exchange(code: code, verifier: verifier, clientID: clientID)
                    finish(result, result ? nil : "No se pudo completar el inicio de sesión con Spotify. Revisa el Client ID y la Redirect URI.")
                }
            }
        }
        listener.stateUpdateHandler = { state in
            if case .failed = state { finish(false, "No se pudo escuchar la respuesta de Spotify.") }
        }
        listener.start(queue: .global(qos: .userInitiated))

        // Si no se completa el inicio de sesión, se cierra el puerto.
        let timeout = DispatchWorkItem { finish(false, "Se agotó el tiempo para iniciar sesión en Spotify.") }
        listenerTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 180, execute: timeout)

        var components = URLComponents(string: "https://accounts.spotify.com/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "scope", value: Self.scope),
            URLQueryItem(name: "state", value: state)
        ]
        if let url = components.url { NSWorkspace.shared.open(url) }
    }

    private func stopListener() {
        listenerTimeout?.cancel()
        listenerTimeout = nil
        listener?.cancel()
        listener = nil
    }

    private func exchange(code: String, verifier: String, clientID: String) async -> Bool {
        let body = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": Self.redirectURI,
            "client_id": clientID,
            "code_verifier": verifier
        ]
        guard let json = await tokenRequest(body),
              let access = json["access_token"] as? String,
              let refresh = json["refresh_token"] as? String else { return false }
        store(access: access, refresh: refresh, expiresIn: (json["expires_in"] as? Double) ?? 3600)
        return true
    }

    // MARK: - Tokens

    private func store(access: String, refresh: String, expiresIn: Double) {
        let value = Tokens(access: access, refresh: refresh, expires: Date().addingTimeInterval(expiresIn))
        tokens = value
        Keychain.save(value)
    }

    private func tokenRequest(_ form: [String: String]) async -> [String: Any]? {
        guard let url = URL(string: "https://accounts.spotify.com/api/token") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form
            .map { "\($0.key)=\(Self.formEncode($0.value))" }
            .joined(separator: "&")
            .data(using: .utf8)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return nil }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if http.statusCode == 400, (json?["error"] as? String) == "invalid_grant" {
            unlink()   // la sesión caducó o se revocó: hay que vincular otra vez
            return nil
        }
        return http.statusCode == 200 ? json : nil
    }

    private func validToken() async -> String? {
        guard let current = tokens else { return nil }
        if current.expires.timeIntervalSinceNow > 60 { return current.access }
        guard let clientID,
              let json = await tokenRequest([
                "grant_type": "refresh_token",
                "refresh_token": current.refresh,
                "client_id": clientID
              ]),
              let access = json["access_token"] as? String else { return nil }
        store(access: access, refresh: (json["refresh_token"] as? String) ?? current.refresh, expiresIn: (json["expires_in"] as? Double) ?? 3600)
        return access
    }

    // MARK: - API

    func playback() async -> SpotifyResult {
        guard let token = await validToken(),
              let url = URL(string: "https://api.spotify.com/v1/me/player?additional_types=episode") else { return .failed }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return .failed }

        if http.statusCode == 204 { return .idle }
        guard http.statusCode == 200,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let item = json["item"] as? [String: Any] else { return http.statusCode == 200 ? .idle : .failed }

        let title = item["name"] as? String ?? ""
        var artist = ((item["artists"] as? [[String: Any]])?.compactMap { $0["name"] as? String })?.joined(separator: ", ") ?? ""
        var album = (item["album"] as? [String: Any])?["name"] as? String ?? ""
        var images = (item["album"] as? [String: Any])?["images"] as? [[String: Any]] ?? []
        if let show = item["show"] as? [String: Any] {   // podcasts
            artist = show["publisher"] as? String ?? artist
            album = show["name"] as? String ?? album
            images = show["images"] as? [[String: Any]] ?? images
        }
        let image = images.first { ($0["width"] as? Int ?? 0) <= 700 && ($0["width"] as? Int ?? 0) >= 250 } ?? images.first
        let progress = (json["progress_ms"] as? Double ?? 0) / 1000
        let duration = (item["duration_ms"] as? Double ?? 0) / 1000

        return .active(SpotifyPlayback(
            title: title,
            artist: artist,
            album: album,
            isPlaying: json["is_playing"] as? Bool ?? false,
            progress: progress,
            duration: duration,
            artworkURL: (image?["url"] as? String).flatMap(URL.init(string:)),
            timestamp: (json["timestamp"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
        ))
    }

    /// Controles (`PUT /me/player/pause`, `POST /me/player/next`…). Devuelve el código HTTP (0 si no hubo respuesta).
    func send(_ method: String, _ path: String, query: [String: String] = [:]) async -> Int {
        guard let token = await validToken() else { return 0 }
        var components = URLComponents(string: "https://api.spotify.com/v1/me/player/\(path)")
        if !query.isEmpty { components?.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        guard let url = components?.url else { return 0 }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 10
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("0", forHTTPHeaderField: "Content-Length")
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return 0 }
        return http.statusCode
    }

    // MARK: - Utilidades

    private static func randomString(_ length: Int) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return String((0..<length).map { _ in alphabet.randomElement()! })
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func responsePage(success: Bool) -> String {
        let title = success ? "Spotify vinculado" : "No se pudo vincular"
        let text = success ? "Ya puedes volver a NotchIsland. Puedes cerrar esta pestaña." : "Vuelve a NotchIsland e inténtalo de nuevo."
        let body = """
        <!doctype html><html lang="es"><head><meta charset="utf-8"><title>\(title)</title>
        <style>body{margin:0;height:100vh;display:grid;place-items:center;background:#000;color:#fff;font-family:-apple-system,system-ui,sans-serif;text-align:center}
        h1{font-size:28px;margin:0 0 8px}p{margin:0;color:#aaa;font-size:16px}</style></head>
        <body><div><h1>\(title)</h1><p>\(text)</p></div></body></html>
        """
        return "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
    }

    // MARK: - Llavero

    private enum Keychain {
        private static let service = "local.notchisland.spotify"
        private static let account = "tokens"

        private static var query: [String: Any] {
            [kSecClass as String: kSecClassGenericPassword,
             kSecAttrService as String: service,
             kSecAttrAccount as String: account]
        }

        static func save(_ tokens: Tokens) {
            guard let data = try? JSONEncoder().encode(tokens) else { return }
            delete()
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(item as CFDictionary, nil)
        }

        static func load() -> Tokens? {
            var item = query
            item[kSecReturnData as String] = true
            item[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            guard SecItemCopyMatching(item as CFDictionary, &result) == errSecSuccess,
                  let data = result as? Data else { return nil }
            return try? JSONDecoder().decode(Tokens.self, from: data)
        }

        static func delete() {
            SecItemDelete(query as CFDictionary)
        }
    }
}

// MARK: - Asistente para pedir el Client ID

enum SpotifySetup {
    /// Explica los tres pasos y pide el Client ID. Devuelve `nil` si se cancela.
    static func askClientID(current: String?) -> String? {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "Vincular tu cuenta de Spotify"
        alert.informativeText = """
        1. Entra en developer.spotify.com/dashboard con tu cuenta y crea una app (el nombre da igual).
        2. En "Redirect URIs" añade exactamente:  \(SpotifyAccount.redirectURI)
        3. Copia el "Client ID" de la app y pégalo aquí.

        Después se abrirá Spotify para que autorices el acceso. La sesión se guarda en tu Llavero.
        """
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.placeholderString = "Client ID"
        field.stringValue = current ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "Vincular")
        alert.addButton(withTitle: "Abrir el panel de Spotify")
        alert.addButton(withTitle: "Cancelar")
        alert.window.initialFirstResponder = field

        while true {
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if value.count >= 20 { return value }
                NSSound.beep()
            case .alertSecondButtonReturn:
                if let url = URL(string: "https://developer.spotify.com/dashboard") { NSWorkspace.shared.open(url) }
            default:
                return nil
            }
        }
    }

    static func showError(_ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "No se pudo vincular Spotify"
        alert.informativeText = message
        alert.runModal()
    }
}
