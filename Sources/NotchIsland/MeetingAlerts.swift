import AppKit
import Combine
import EventKit
import SwiftUI

// MARK: - Datos

/// Un evento del calendario, reducido a lo que hace falta para avisar de él.
struct MeetingEvent: Equatable {
    let id: String
    let title: String
    let start: Date
    let tint: Color
    /// Lleva un enlace de videollamada (Zoom, Meet, Teams…).
    let hasVideo: Bool
    let place: String?
}

/// Aviso del notch cerrado: faltan unos minutos para el evento, o empieza ahora.
struct MeetingAlert: Equatable {
    enum Kind: Equatable {
        case soon(minutes: Int)
        case now
    }

    let event: MeetingEvent
    let kind: Kind

    /// Evento + momento: identifica el aviso para no repetirlo.
    var key: String {
        switch kind {
        case .soon: return event.id + "#soon"
        case .now: return event.id + "#now"
        }
    }

    /// Segundos que se queda en pantalla.
    var duration: Double { kind == .now ? 8 : 6.5 }
}

// MARK: - Cuándo avisar

/// La lógica de los avisos, sin EventKit ni temporizadores: dados los eventos, lo ya avisado y la
/// hora, dice qué enseñar ahora y cuándo volver a mirar.
enum MeetingSchedule {
    /// Primer aviso: tanto antes de que empiece.
    static let lead: TimeInterval = 5 * 60
    /// Un aviso que llega más tarde que esto (el Mac dormía) ya no sirve y se descarta.
    static let grace: TimeInterval = 2 * 60
    /// Hasta dónde se mira en el calendario.
    static let horizon: TimeInterval = 24 * 3600

    struct Plan: Equatable {
        /// El aviso que toca enseñar ya (si hay varios a la vez, el más antiguo; el resto sale después).
        var due: MeetingAlert?
        /// Cuándo toca el siguiente aviso que aún no ha llegado.
        var next: Date?
    }

    static func plan(events: [MeetingEvent], handled: Set<String>, now: Date, lead: TimeInterval = lead) -> Plan {
        var due: [(fire: Date, alert: MeetingAlert)] = []
        var next: Date?

        for event in events {
            let minutes = max(1, Int((event.start.timeIntervalSince(now) / 60).rounded()))
            for isStart in [false, true] {
                let fire = isStart ? event.start : event.start.addingTimeInterval(-lead)
                let alert = MeetingAlert(event: event, kind: isStart ? .now : .soon(minutes: minutes))
                guard !handled.contains(alert.key) else { continue }

                if fire > now {
                    next = min(next ?? fire, fire)
                } else if now.timeIntervalSince(fire) <= grace, isStart || now < event.start {
                    due.append((fire, alert))
                }
            }
        }

        due.sort {
            ($0.fire, $0.alert.event.start, $0.alert.event.id) < ($1.fire, $1.alert.event.start, $1.alert.event.id)
        }
        return Plan(due: due.first?.alert, next: next)
    }
}

// MARK: - Enlaces de videollamada

enum MeetingLink {
    private static let hosts = [
        "zoom.us", "zoom.com", "meet.google.com", "teams.microsoft.com", "teams.live.com",
        "webex.com", "whereby.com", "facetime.apple.com", "gotomeeting.com", "bluejeans.com", "meet.jit.si"
    ]

    /// El enlace puede estar en la URL, en el lugar o en las notas del evento.
    static func isVideoCall(_ event: EKEvent) -> Bool {
        containsLink(in: [event.url?.absoluteString, event.location, event.notes])
    }

    static func containsLink(in fields: [String?]) -> Bool {
        fields.contains { field in
            guard let text = field?.lowercased() else { return false }
            return hosts.contains { text.contains($0) }
        }
    }
}

// MARK: - Avisos de reuniones

/// Avisa en el notch cerrado poco antes de que empiece un evento del calendario y otra vez al empezar.
///
/// Un solo temporizador, armado para el siguiente aviso (nada de sondeos); se rearma al cambiar el
/// calendario, al despertar el Mac, al activar o desactivar el aviso y al concederse el acceso al
/// calendario. Solo lee el calendario si el permiso ya está concedido: nunca lo pide (eso lo hace la
/// pestaña "Hoy"). EventKit se lee en una cola propia para no bloquear el hilo principal.
final class MeetingAlertCenter {
    /// Enseña el aviso. Devuelve `false` si ahora no se puede (la isla está abierta): se reintenta enseguida.
    var onAlert: ((MeetingAlert) -> Bool)?
    /// Antelación del primer aviso.
    var lead = MeetingSchedule.lead
    /// De dónde salen los eventos (`nil` = sin acceso al calendario). Por defecto, EventKit.
    var loadEvents: ((Date) -> [MeetingEvent]?)?

    private let defaults: UserDefaults
    private let queue = DispatchQueue(label: "notchisland.meetings", qos: .utility)
    private var store: EKEventStore?   // se crea al primer uso con permiso; solo se toca desde `queue`
    private var timer: DispatchSourceTimer?
    private var debounce: DispatchWorkItem?
    private var generation = 0
    private var quietUntil = Date.distantPast   // mientras se ve un aviso no sale otro
    private var handled: [String: Date]   // aviso -> inicio del evento, para olvidarlo al día siguiente
    private var wasEnabled = true
    private var started = false
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    private var cancellables = Set<AnyCancellable>()

    private static let handledKey = "meetingAlertsHandled"
    /// Aunque no haya nada a la vista, se vuelve a mirar de vez en cuando.
    private static let longestSleep: TimeInterval = 6 * 3600

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.dictionary(forKey: Self.handledKey) as? [String: Double] ?? [:]
        handled = saved.mapValues { Date(timeIntervalSince1970: $0) }
    }

    deinit {
        timer?.cancel()
        for (center, token) in observers { center.removeObserver(token) }
    }

    private var enabled: Bool {
        (defaults.object(forKey: "meetingAlerts") as? Bool) ?? true
    }

    func start(calendar: CalendarModel) {
        guard !started else { return }
        started = true
        wasEnabled = enabled

        // Cualquier almacén vale: también se entera de los cambios que ve la pestaña "Hoy".
        observe(.EKEventStoreChanged, in: .default) { [weak self] in self?.refreshSoon() }
        observe(NSWorkspace.didWakeNotification, in: NSWorkspace.shared.notificationCenter) { [weak self] in
            self?.refreshSoon()
        }
        observe(UserDefaults.didChangeNotification, in: .default) { [weak self] in
            guard let self, self.enabled != self.wasEnabled else { return }
            self.wasEnabled = self.enabled
            self.refresh()
        }

        // El permiso se concede desde la pestaña "Hoy": a partir de ahí hay calendario que vigilar.
        calendar.$eventsAccess
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] access in
                guard let self, access == .granted else { return }
                self.queue.async { self.store = nil }   // uno creado antes del permiso no sirve
                self.refresh()
            }
            .store(in: &cancellables)

        refresh()
    }

    private func observe(_ name: Notification.Name, in center: NotificationCenter, _ handler: @escaping () -> Void) {
        observers.append((center, center.addObserver(forName: name, object: nil, queue: .main) { _ in handler() }))
    }

    /// EventKit avisa varias veces seguidas al sincronizar: se agrupan.
    private func refreshSoon() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    /// Vuelve a leer el calendario y rearma el temporizador.
    func refresh() {
        timer?.cancel()
        timer = nil
        generation += 1
        guard enabled else { return }

        let gen = generation
        let now = Date()
        let source = loadEvents
        queue.async { [weak self] in
            guard let self else { return }
            let events = source?(now) ?? self.fetchEvents(now: now)
            DispatchQueue.main.async {
                guard gen == self.generation else { return }   // llegó una lectura más reciente
                self.schedule(events, now: Date())
            }
        }
    }

    private func schedule(_ events: [MeetingEvent]?, now: Date) {
        guard let events else { return }

        let plan = MeetingSchedule.plan(events: events, handled: Set(handled.keys), now: now, lead: lead)
        var wake = plan.next
        if let alert = plan.due {
            if now < quietUntil {
                wake = quietUntil                            // todavía se ve el aviso anterior
            } else if onAlert?(alert) == true {
                remember(alert, now: now)
                announce(alert)
                quietUntil = now.addingTimeInterval(alert.duration + 1)
                wake = quietUntil                            // y entonces, lo que quede
            } else {
                wake = now.addingTimeInterval(3)             // la isla está abierta: se reintenta enseguida
            }
        }
        arm(at: min(wake ?? .distantFuture, now.addingTimeInterval(Self.longestSleep)))
    }

    /// Lo avisado se recuerda (también entre ejecuciones) hasta el día siguiente.
    private func remember(_ alert: MeetingAlert, now: Date) {
        handled[alert.key] = alert.event.start
        let cutoff = now.addingTimeInterval(-86_400)
        handled = handled.filter { $0.value > cutoff }
        defaults.set(handled.mapValues { $0.timeIntervalSince1970 }, forKey: Self.handledKey)
    }

    /// VoiceOver no ve el notch: el aviso se dice en voz alta.
    private func announce(_ alert: MeetingAlert) {
        let when: String
        switch alert.kind {
        case .soon(let minutes): when = minutes == 1 ? "En 1 minuto" : "En \(minutes) minutos"
        case .now: when = "Ahora"
        }
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [
                .announcement: "\(when): \(alert.event.title)",
                .priority: NSAccessibilityPriorityLevel.high.rawValue
            ]
        )
    }

    /// Reloj de pared: si el Mac duerme y la hora pasa, salta al despertar.
    private func arm(at date: Date) {
        timer?.cancel()
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(wallDeadline: .now() + max(0, date.timeIntervalSinceNow), leeway: .milliseconds(250))
        source.setEventHandler { [weak self] in self?.refresh() }
        source.resume()
        timer = source
    }

    // MARK: EventKit

    private func fetchEvents(now: Date) -> [MeetingEvent]? {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return nil }
        let store = self.store ?? EKEventStore()
        self.store = store

        let from = now.addingTimeInterval(-MeetingSchedule.grace)
        let predicate = store.predicateForEvents(
            withStart: from, end: now.addingTimeInterval(MeetingSchedule.horizon), calendars: nil
        )
        return store.events(matching: predicate).compactMap { event in
            guard !event.isAllDay, event.status != .canceled, event.startDate >= from else { return nil }
            let declined = event.attendees?.contains { $0.isCurrentUser && $0.participantStatus == .declined } ?? false
            guard !declined else { return nil }

            let title = (event.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return MeetingEvent(
                id: "\(event.eventIdentifier ?? title)-\(Int(event.startDate.timeIntervalSince1970))",
                title: title.isEmpty ? "Sin título" : title,
                start: event.startDate,
                tint: Color.listTint(event.calendar?.cgColor),
                hasVideo: MeetingLink.isVideoCall(event),
                place: CalendarModel.shortPlace(event.location)
            )
        }
    }
}
