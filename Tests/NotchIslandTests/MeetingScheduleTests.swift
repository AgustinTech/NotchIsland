import SwiftUI
import XCTest
@testable import NotchIsland

final class MeetingScheduleTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func event(_ id: String = "a", startsIn seconds: TimeInterval) -> MeetingEvent {
        MeetingEvent(
            id: id, title: "Reunión \(id)", start: t0.addingTimeInterval(seconds),
            tint: .blue, hasVideo: false, place: nil
        )
    }

    private func plan(_ events: [MeetingEvent], handled: Set<String> = [], at offset: TimeInterval = 0) -> MeetingSchedule.Plan {
        MeetingSchedule.plan(events: events, handled: handled, now: t0.addingTimeInterval(offset))
    }

    func testFirstAlertIsScheduledFiveMinutesBeforeStart() {
        let result = plan([event(startsIn: 20 * 60)])

        XCTAssertNil(result.due)
        XCTAssertEqual(result.next, t0.addingTimeInterval(15 * 60))
    }

    func testFiveMinuteAlertFiresOnTime() {
        let result = plan([event(startsIn: 5 * 60)])

        XCTAssertEqual(result.due?.kind, .soon(minutes: 5))
        XCTAssertEqual(result.next, t0.addingTimeInterval(5 * 60))   // y el siguiente, al empezar
    }

    func testStartAlertFiresAtStartOnceTheFirstOneIsDone() {
        let soon = plan([event(startsIn: 5 * 60)]).due
        let result = plan([event(startsIn: 0)], handled: [soon!.key])

        XCTAssertEqual(result.due?.kind, .now)
        XCTAssertNil(result.next)
    }

    func testEachAlertIsShownOnlyOnce() {
        let now = plan([event(startsIn: 0)])
        let again = plan([event(startsIn: 0)], handled: [now.due!.key])

        XCTAssertNil(again.due)
        XCTAssertNil(again.next)
    }

    func testLateAlertShowsTheRealTimeLeft() {
        // El Mac despertó un minuto tarde: faltan 4 minutos, no 5.
        let result = plan([event(startsIn: 4 * 60)])

        XCTAssertEqual(result.due?.kind, .soon(minutes: 4))
    }

    func testAlertsMissedForTooLongAreDropped() {
        // Faltan 100 s: el aviso de los 5 minutos llegaría con 200 s de retraso.
        let result = plan([event(startsIn: 100)])

        XCTAssertNil(result.due)
        XCTAssertEqual(result.next, t0.addingTimeInterval(100))
    }

    func testStartAlertStillShownJustAfterStart() {
        let result = plan([event(startsIn: -90)])

        XCTAssertEqual(result.due?.kind, .now)
    }

    func testPastEventsProduceNothing() {
        let result = plan([event(startsIn: -10 * 60)])

        XCTAssertNil(result.due)
        XCTAssertNil(result.next)
    }

    func testEventsAtTheSameTimeAreShownOneAfterAnother() {
        let events = [event("b", startsIn: 0), event("a", startsIn: 0)]

        let first = plan(events)
        XCTAssertEqual(first.due?.event.id, "a")
        XCTAssertNil(first.next)

        let second = plan(events, handled: [first.due!.key], at: 9)
        XCTAssertEqual(second.due?.event.id, "b")

        let third = plan(events, handled: [first.due!.key, second.due!.key], at: 18)
        XCTAssertNil(third.due)
    }

    func testEarliestAlertIsNextWhenSeveralEventsAreAhead() {
        let result = plan([event("a", startsIn: 3600), event("b", startsIn: 1800)])

        XCTAssertNil(result.due)
        XCTAssertEqual(result.next, t0.addingTimeInterval(1800 - 5 * 60))
    }

    func testMovedEventIsAlertedAgainAtItsNewTime() {
        // Un evento que cambia de hora tiene otra identidad (el id lleva la hora de inicio).
        let moved = MeetingEvent(id: "a-new", title: "Reunión a", start: t0, tint: .blue, hasVideo: false, place: nil)
        let result = plan([moved], handled: ["a-old#soon", "a-old#now"])

        XCTAssertEqual(result.due?.kind, .now)
    }

    func testCustomLeadTime() {
        let result = MeetingSchedule.plan(events: [event(startsIn: 600)], handled: [], now: t0, lead: 120)

        XCTAssertEqual(result.next, t0.addingTimeInterval(480))
    }

    func testDetectsVideoCallLinksAnywhereInTheEvent() {
        XCTAssertTrue(MeetingLink.containsLink(in: [nil, "https://us02web.zoom.us/j/123456789", nil]))
        XCTAssertTrue(MeetingLink.containsLink(in: [nil, nil, "Únete: https://meet.google.com/abc-defg-hij"]))
        XCTAssertTrue(MeetingLink.containsLink(in: ["HTTPS://TEAMS.MICROSOFT.COM/l/meetup-join/xyz", nil, nil]))
        XCTAssertFalse(MeetingLink.containsLink(in: [nil, "Sala 3, planta 2", "Traer el portátil"]))
        XCTAssertFalse(MeetingLink.containsLink(in: [nil, nil, nil]))
    }
}
