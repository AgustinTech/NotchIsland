import Foundation

/// Snapshot del Centro de control de macOS. MediaRemote es una API privada y puede no
/// publicar la sesión de un reproductor; en ese caso se conservan sus avisos propios.
struct SystemNowPlaying {
    let player: Player
    let title: String
    let artist: String
    let album: String
    let playing: Bool
    let duration: TimeInterval?
    let position: TimeInterval?

    // osascript es un proceso de Apple: en macOS recientes la llamada directa desde
    // una app de terceros devuelve una respuesta vacía. No se envían AppleEvents al
    // reproductor y esta consulta no solicita permisos.
    private static let script = #"""
    ObjC.import('Foundation');
    function run() {
      try {
        const framework = $.NSBundle.bundleWithPath('/System/Library/PrivateFrameworks/MediaRemote.framework/');
        framework.load;
        const request = $.NSClassFromString('MRNowPlayingRequest');
        if (!request) return '{}';
        const result = {playing: request.localIsPlaying ? true : false};
        const item = request.localNowPlayingItem;
        if (item && item.nowPlayingInfo) {
          const info = item.nowPlayingInfo, keys = info.keyEnumerator;
          let key;
          while ((key = keys.nextObject) && !key.isNil()) {
            const value = info.objectForKey(key);
            if (value && !value.isNil()) {
              const name = ObjC.unwrap(key).replace('kMRMediaRemoteNowPlayingInfo', '');
              if (value.isKindOfClass($.NSDate)) result[name] = value.timeIntervalSince1970;
              else if (value.isKindOfClass($.NSString) || value.isKindOfClass($.NSNumber)) result[name] = ObjC.unwrap(value);
            }
          }
        }
        const path = request.localNowPlayingPlayerPath;
        if (path && path.client) {
          const client = path.client;
          if (client.parentApplicationBundleIdentifier && !client.parentApplicationBundleIdentifier.isNil())
            result.parentBundle = ObjC.unwrap(client.parentApplicationBundleIdentifier);
          if (client.bundleIdentifier && !client.bundleIdentifier.isNil())
            result.bundle = ObjC.unwrap(client.bundleIdentifier);
        }
        return JSON.stringify(result);
      } catch (error) { return '{}'; }
    }
    """#

    static func query() -> SystemNowPlaying? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-l", "JavaScript", "-e", script]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }

        // La consulta va fuera del hilo principal. El límite evita que un servicio
        // de medios atascado bloquee las siguientes lecturas.
        let watchdog = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 4, execute: watchdog)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return parse(json)
    }

    /// Interpreta el JSON de MediaRemote. Separado de `query` para poder testearlo.
    static func parse(_ json: [String: Any], now: TimeInterval = Date().timeIntervalSince1970) -> SystemNowPlaying? {
        guard let title = json["Title"] as? String, !title.isEmpty else { return nil }
        let bundle = (json["parentBundle"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (json["bundle"] as? String ?? "")
        let player: Player
        switch bundle {
        case Player.spotify.bundleID: player = .spotify
        case Player.music.bundleID: player = .music
        default: return nil
        }
        func number(_ key: String) -> Double? { (json[key] as? NSNumber)?.doubleValue }

        let playing = json["playing"] as? Bool ?? false
        let duration = number("Duration")
        let elapsed = number("ElapsedTime")
        let timestamp = number("Timestamp")

        let position: TimeInterval?
        if let elapsed, elapsed > 0 {
            // Comportamiento clásico: ElapsedTime medido en Timestamp.
            position = elapsed + (playing ? max(0, min(now - (timestamp ?? now), 5)) : 0)
        } else if playing, let timestamp, now - timestamp >= 0 {
            // Spotify en macOS recientes publica siempre ElapsedTime = 0 y Timestamp = instante
            // en que empezó a sonar: la posición es el tiempo transcurrido desde entonces.
            let sinceStart = now - timestamp
            if let duration, duration > 0 {
                position = min(sinceStart, duration)
            } else {
                position = min(sinceStart, 3600)
            }
        } else {
            position = nil
        }

        return SystemNowPlaying(
            player: player, title: title,
            artist: json["Artist"] as? String ?? "",
            album: json["Album"] as? String ?? "",
            playing: playing, duration: duration, position: position
        )
    }
}
