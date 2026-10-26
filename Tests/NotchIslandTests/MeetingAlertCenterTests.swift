import SwiftUI
import XCTest
@testable import NotchIsland

/// Prueba el temporizador de verdad con eventos falsos y la antelación acortada (segundos, no minutos).
final class MeetingAlertCenterTests: XCTestCase {
    private var suite = ""

    private func makeCenter(events: [MeetingEvent], lead: TimeInterval) -> MeetingAlertCenter {
        suite = "notchisland.tests.\(UUID().uuidString)"
        let center = MeetingAlertCenter(defaults: UserDefaults(suiteName: suite)!)
        center.lead = lead
        center.loadEvents = { _ in events }
        return center
    }

    override func tearDown() {
        if !suite.isEmpty {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            // El dominio vacío deja su .plist en Preferencias: se borra también.
            let plist = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Preferences/\(suite).plist")
            try? FileManager.default.removeItem(at: plist)
        }
        super.tearDown()
    }

    func testFiresBeforeAndAtStartExactlyOnce() {
        let begin = Date()
        let event = MeetingEvent(
            id: "daily", title: "Daily", start: begin.addingTimeInterval(10),
            tint: .blue, hasVideo: true, place: nil
        )
        let center = makeCenter(events: [event], lead: 9.5)

        var fired: [(kind: MeetingAlert.Kind, at: TimeInterval)] = []
        let both = expectation(description: "los dos avisos")
        both.expectedFulfillmentCount = 2
        center.onAlert = { alert in
            fired.append((alert.kind, Date().timeIntervalSince(begin)))
            both.fulfill()
            return true
        }
        center.start(calendar: CalendarModel())

        // Un cambio en el calendario a mitad de camino no debe repetir ni adelantar nada.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { center.refresh() }
        wait(for: [both], timeout: 14)

        XCTAssertEqual(fired.count, 2)
        XCTAssertEqual(fired.first?.kind, .soon(minutes: 1))
        XCTAssertEqual(fired.first?.at ?? 0, 0.5, accuracy: 0.8)
        XCTAssertEqual(fired.last?.kind, .now)
        XCTAssertEqual(fired.last?.at ?? 0, 10, accuracy: 0.8)
    }

    func testRetriesWhileTheIslandIsBusy() {
        let begin = Date()
        let event = MeetingEvent(
            id: "retro", title: "Retro", start: begin.addingTimeInterval(60),
            tint: .green, hasVideo: false, place: "Sala 2"
        )
        let center = makeCenter(events: [event], lead: 59.5)

        var attempts: [TimeInterval] = []
        let shown = expectation(description: "aviso enseñado")
        center.onAlert = { _ in
            attempts.append(Date().timeIntervalSince(begin))
            guard attempts.count > 1 else { return false }   // la isla estaba abierta
            shown.fulfill()
            return true
        }
        center.start(calendar: CalendarModel())
        wait(for: [shown], timeout: 8)

        XCTAssertEqual(attempts.count, 2)
        XCTAssertEqual(attempts.last ?? 0, 3.5, accuracy: 0.8)   // reintento a los 3 s del primero
    }

    func testTurningTheSettingOffSilencesAlertsAndOnBringsThemBack() {
        let event = MeetingEvent(
            id: "sync", title: "Sync", start: Date().addingTimeInterval(30),
            tint: .orange, hasVideo: false, place: nil
        )
        let center = makeCenter(events: [event], lead: 28.5)   // el aviso toca a los 1,5 s
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(false, forKey: "meetingAlerts")

        var turnedBackOn = false
        let silent = expectation(description: "nada mientras está apagado")
        silent.isInverted = true
        let shown = expectation(description: "aviso al reactivarlo")
        center.onAlert = { _ in
            if turnedBackOn { shown.fulfill() } else { silent.fulfill() }
            return true
        }
        center.start(calendar: CalendarModel())
        wait(for: [silent], timeout: 3)

        turnedBackOn = true
        defaults.set(true, forKey: "meetingAlerts")
        wait(for: [shown], timeout: 4)
    }

    func testSimultaneousAlertsAreShownOneAfterAnother() {
        let begin = Date()
        let start = begin.addingTimeInterval(30)
        let events = ["a", "b"].map {
            MeetingEvent(id: $0, title: "Reunión \($0)", start: start, tint: .blue, hasVideo: false, place: nil)
        }
        let center = makeCenter(events: events, lead: 29.5)   // los dos "en 5 min" tocan a los 0,5 s

        var shown: [(id: String, at: TimeInterval)] = []
        let both = expectation(description: "los dos avisos")
        both.expectedFulfillmentCount = 2
        center.onAlert = { alert in
            shown.append((alert.event.id, Date().timeIntervalSince(begin)))
            both.fulfill()
            return true
        }
        center.start(calendar: CalendarModel())
        wait(for: [both], timeout: 14)

        XCTAssertEqual(shown.map(\.id), ["a", "b"])
        // El segundo espera a que el primero termine: 6,5 s en pantalla y 1 s de margen.
        XCTAssertGreaterThanOrEqual((shown.last?.at ?? 0) - (shown.first?.at ?? 0), 7.4)
    }
}
