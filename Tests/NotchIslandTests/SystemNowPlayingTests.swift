import XCTest
@testable import NotchIsland

final class SystemNowPlayingTests: XCTestCase {
    private let spotifyBundle = "com.spotify.client"

    private func json(_ overrides: [String: Any]) -> [String: Any] {
        var base: [String: Any] = [
            "Title": "I Wonder",
            "Artist": "Kanye West",
            "Album": "Graduation",
            "playing": true,
            "Duration": 243.44,
            "ElapsedTime": 0,
            "Timestamp": 1_000.0,
            "bundle": "com.spotify.client"
        ]
        for (key, value) in overrides { base[key] = value }
        return base
    }

    func testSpotifyPublishesZeroElapsedSoPositionComesFromTimestamp() {
        // Caso real en macOS recientes: ElapsedTime siempre 0 y Timestamp = inicio de la reproducción.
        let now = 1_100.0
        let snapshot = SystemNowPlaying.parse(json([:]), now: now)
        XCTAssertEqual(snapshot?.position ?? -1, 100.0, accuracy: 0.001)
        XCTAssertTrue(snapshot?.playing ?? false)
    }

    func testPositionClampsToDurationWhenTimestampIsOld() {
        let snapshot = SystemNowPlaying.parse(json([:]), now: 1_000 + 600)
        XCTAssertEqual(snapshot?.position ?? -1, 243.44, accuracy: 0.001)
    }

    func testClassicElapsedTimeIsRespected() {
        // Reproductor clásico: ElapsedTime medido en Timestamp; se suma lo transcurrido (tope 5 s).
        let snapshot = SystemNowPlaying.parse(
            json(["ElapsedTime": 30.0, "Timestamp": 1_096.0]), now: 1_100.0
        )
        XCTAssertEqual(snapshot?.position ?? -1, 34.0, accuracy: 0.001)
    }

    func testPausedWithZeroElapsedHasNoPosition() {
        let snapshot = SystemNowPlaying.parse(json(["playing": false]), now: 1_100.0)
        XCTAssertNil(snapshot?.position)
    }

    func testUnknownPlayerIsRejected() {
        let snapshot = SystemNowPlaying.parse(
            json(["bundle": "com.apple.quicktimeplayer"]), now: 1_100.0
        )
        XCTAssertNil(snapshot)
    }

    func testMissingTitleIsRejected() {
        var data = json([:])
        data["Title"] = ""
        XCTAssertNil(SystemNowPlaying.parse(data, now: 1_100.0))
    }
}
