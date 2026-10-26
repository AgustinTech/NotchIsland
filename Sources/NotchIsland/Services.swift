import AppKit
import CoreLocation
import EventKit
import Foundation
import IOBluetooth
import SwiftUI

// MARK: - Agrupa los servicios de la pestaña "Hoy"

/// Los permisos (calendario, recordatorios, ubicación) se piden solo cuando abres la pestaña "Hoy" por primera vez.
final class Services {
    let calendar = CalendarModel()
    let weather = WeatherModel()
    let devices = DevicesModel()
    let clipboard = ClipboardModel()
    let quick = QuickActions()
    private var started = false

    func activate() {
        if !started {
            started = true
            calendar.start()
        } else {
            calendar.reload()
        }
        weather.start()
        devices.refresh()
    }

    /// Al salir de la pestaña el tiempo deja de actualizarse (nada se queda trabajando en segundo plano).
    func deactivate() {
        weather.stop()
    }
}

// MARK: - Calendario y recordatorios (EventKit)

/// Estado de un permiso del sistema: `unknown` mientras el aviso está pendiente.
enum AccessState {
    case unknown, granted, denied
}

struct AgendaEvent: Identifiable, Equatable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let allDay: Bool
    let location: String?
    let tint: Color
}

struct AgendaReminder: Identifiable, Equatable {
    let id: String
    let title: String
    let due: Date?
    let hasTime: Bool
    let list: String
    let tint: Color
}

extension Color {
    /// Color de un calendario o lista, con brillo suficiente para leerse sobre el negro de la isla.
    static func listTint(_ cgColor: CGColor?) -> Color {
        guard let cgColor,
              let base = NSColor(cgColor: cgColor)?.usingColorSpace(.sRGB) else { return Color.blue }
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        base.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return Color(hue: Double(hue), saturation: Double(min(1, max(saturation, 0.35))), brightness: Double(max(brightness, 0.78)))
    }
}

/// Eventos de hoy y mañana + recordatorios pendientes. Todo el acceso a EventKit va en una cola
/// propia: nunca bloquea el hilo principal (ni siquiera mientras el sistema pregunta por el permiso).
final class CalendarModel: ObservableObject {
    @Published var events: [AgendaEvent] = []
    @Published var reminders: [AgendaReminder] = []
    @Published var eventsAccess: AccessState = .unknown
    @Published var remindersAccess: AccessState = .unknown
    /// Recordatorios marcados como hechos que aún pueden deshacerse (se confirman al cabo de un momento).
    @Published var completing: Set<String> = []

    private let store = EKEventStore()
    private let queue = DispatchQueue(label: "notchisland.eventkit", qos: .userInitiated)
    private var reminderObjects: [String: EKReminder] = [:]   // solo se toca desde `queue`
    private var pendingCompletion: [String: DispatchWorkItem] = [:]
    private var observer: NSObjectProtocol?
    private var reloadWork: DispatchWorkItem?
    private var eventEndTimer: Timer?

    // MARK: Permisos

    func start() {
        observer = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: store, queue: .main
        ) { [weak self] _ in
            self?.reloadSoon()
        }

        // Primero el calendario y después los recordatorios, para no apilar dos avisos del sistema.
        requestEvents { [weak self] in
            self?.requestReminders { self?.reload() }
        }
    }

    private func requestEvents(then next: @escaping () -> Void) {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .notDetermined:
            store.requestFullAccessToEvents { granted, _ in
                DispatchQueue.main.async {
                    self.eventsAccess = granted ? .granted : .denied
                    next()
                }
            }
        case .fullAccess:
            eventsAccess = .granted
            next()
        default:
            eventsAccess = .denied
            next()
        }
    }

    private func requestReminders(then next: @escaping () -> Void) {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .notDetermined:
            store.requestFullAccessToReminders { granted, _ in
                DispatchQueue.main.async {
                    self.remindersAccess = granted ? .granted : .denied
                    next()
                }
            }
        case .fullAccess:
            remindersAccess = .granted
            next()
        default:
            remindersAccess = .denied
            next()
        }
    }

    // MARK: Lectura

    /// Agrupa avisos seguidos del sistema (EventKit puede lanzar varios de golpe al sincronizar).
    private func reloadSoon() {
        reloadWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reload() }
        reloadWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func reload() {
        let eventStatus = EKEventStore.authorizationStatus(for: .event)
        let reminderStatus = EKEventStore.authorizationStatus(for: .reminder)

        // Si el permiso cambió en Ajustes del Sistema, se refleja aquí al volver a abrir la pestaña.
        if eventStatus != .notDetermined {
            let access: AccessState = eventStatus == .fullAccess ? .granted : .denied
            if eventsAccess != access { eventsAccess = access }
        }
        if reminderStatus != .notDetermined {
            let access: AccessState = reminderStatus == .fullAccess ? .granted : .denied
            if remindersAccess != access { remindersAccess = access }
        }

        queue.async { [weak self] in
            guard let self else { return }
            if eventStatus == .fullAccess { self.loadEvents() }
            if reminderStatus == .fullAccess { self.loadReminders() }
        }
    }

    private func loadEvents() {
        let calendar = Calendar.current
        let now = Date()
        let today = calendar.startOfDay(for: now)
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: today),
              let limit = calendar.date(byAdding: .day, value: 2, to: today) else { return }

        let predicate = store.predicateForEvents(withStart: today, end: limit, calendars: nil)
        let found = store.events(matching: predicate)
            .filter { event in
                guard event.status != .canceled, event.endDate > now else { return false }
                let declined = event.attendees?.contains { $0.isCurrentUser && $0.participantStatus == .declined } ?? false
                return !declined
            }
            .sorted { a, b in
                let dayA = a.startDate >= tomorrow ? 1 : 0
                let dayB = b.startDate >= tomorrow ? 1 : 0
                if dayA != dayB { return dayA < dayB }
                if a.isAllDay != b.isAllDay { return a.isAllDay }
                return a.startDate < b.startDate
            }
            .prefix(24)
            .map { event in
                let title = (event.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                return AgendaEvent(
                    id: "\(event.eventIdentifier ?? title)-\(Int(event.startDate.timeIntervalSince1970))",
                    title: title.isEmpty ? "Sin título" : title,
                    start: event.startDate,
                    end: event.endDate,
                    allDay: event.isAllDay,
                    location: CalendarModel.shortPlace(event.location),
                    tint: Color.listTint(event.calendar?.cgColor)
                )
            }
        let result = Array(found)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.events != result { self.events = result }

            // El calendario no avisa cuando un evento termina solo por el paso del tiempo.
            self.eventEndTimer?.invalidate()
            self.eventEndTimer = nil
            if let end = result.filter({ !$0.allDay }).map({ $0.end }).min() {
                let timer = Timer(fire: end.addingTimeInterval(1), interval: 0, repeats: false) { [weak self] _ in
                    self?.reload()
                }
                RunLoop.main.add(timer, forMode: .common)
                self.eventEndTimer = timer
            }
        }
    }

    /// Lugar corto y legible: enlaces de videollamada se resumen; direcciones largas se descartan.
    static func shortPlace(_ raw: String?) -> String? {
        guard var place = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !place.isEmpty else { return nil }
        let lowered = place.lowercased()
        if lowered.hasPrefix("http") {
            let calls = ["zoom.us", "meet.google", "teams.microsoft", "teams.live", "webex", "whereby"]
            return calls.contains { lowered.contains($0) } ? "Videollamada" : nil
        }
        place = place.components(separatedBy: .newlines).first ?? place
        if let comma = place.firstIndex(of: ",") { place = String(place[..<comma]) }
        place = place.trimmingCharacters(in: .whitespaces)
        return (place.isEmpty || place.count > 26) ? nil : place
    }

    private func loadReminders() {
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        store.fetchReminders(matching: predicate) { [weak self] found in
            guard let self, let found else { return }
            self.queue.async { self.publish(reminders: found) }
        }
    }

    /// Vencidos y de hoy primero (por hora), después los que no tienen fecha. Los de días futuros no se muestran.
    private func publish(reminders found: [EKReminder]) {
        let calendar = Calendar.current
        let now = Date()
        let today = calendar.startOfDay(for: now)
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) else { return }

        struct Entry {
            let reminder: EKReminder
            let due: Date?
            let hasTime: Bool
            let rank: Int
        }

        var entries: [Entry] = []
        for reminder in found {
            let components = reminder.dueDateComponents
            let due = components.flatMap { calendar.date(from: $0) }
            let hasTime = components?.hour != nil
            if let due {
                if due >= tomorrow { continue }
                let overdue = hasTime ? due < now : due < today
                entries.append(Entry(reminder: reminder, due: due, hasTime: hasTime, rank: overdue ? 0 : 1))
            } else {
                entries.append(Entry(reminder: reminder, due: nil, hasTime: false, rank: 2))
            }
        }

        entries.sort { a, b in
            if a.rank != b.rank { return a.rank < b.rank }
            if let x = a.due, let y = b.due {
                if a.hasTime != b.hasTime { return !a.hasTime }
                return x < y
            }
            return (a.reminder.title ?? "").localizedStandardCompare(b.reminder.title ?? "") == .orderedAscending
        }

        var objects: [String: EKReminder] = [:]
        let items: [AgendaReminder] = entries.prefix(40).map { entry in
            let id = entry.reminder.calendarItemIdentifier
            objects[id] = entry.reminder
            let title = (entry.reminder.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return AgendaReminder(
                id: id,
                title: title.isEmpty ? "Sin título" : title,
                due: entry.due,
                hasTime: entry.hasTime,
                list: entry.reminder.calendar?.title ?? "",
                tint: Color.listTint(entry.reminder.calendar?.cgColor)
            )
        }
        reminderObjects = objects

        DispatchQueue.main.async {
            // Los que están en espera de confirmarse se quedan donde están hasta entonces.
            if self.reminders != items { self.reminders = items }
        }
    }

    // MARK: Completar recordatorios

    /// Primer toque: marca el recordatorio como hecho. Si no se vuelve a tocar en ~1 s, se guarda en el
    /// sistema y desaparece de la lista; un segundo toque lo deshace.
    func toggleReminder(_ id: String) {
        if completing.contains(id) {
            pendingCompletion[id]?.cancel()
            pendingCompletion[id] = nil
            completing.remove(id)
            return
        }

        completing.insert(id)
        if UserDefaults.standard.bool(forKey: "haptics") {
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        }
        let work = DispatchWorkItem { [weak self] in self?.commitCompletion(id) }
        pendingCompletion[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    private func commitCompletion(_ id: String) {
        pendingCompletion[id] = nil
        queue.async { [weak self] in
            guard let self else { return }
            var saved = true
            if let reminder = self.reminderObjects[id] {
                reminder.isCompleted = true
                do {
                    try self.store.save(reminder, commit: true)
                } catch {
                    saved = false
                }
            }
            DispatchQueue.main.async {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                    if saved { self.reminders.removeAll { $0.id == id } }
                    self.completing.remove(id)
                }
            }
        }
    }
}

// MARK: - Tiempo (ubicación aproximada + Open-Meteo)

struct HourForecast: Identifiable, Equatable {
    let date: Date
    let temperature: Int
    let symbol: String
    var id: Date { date }
}

final class WeatherModel: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var temperature: Int?
    @Published var symbol = "cloud.sun.fill"
    @Published var summary = ""
    @Published var place = ""
    @Published var high: Int?
    @Published var low: Int?
    @Published var hours: [HourForecast] = []
    @Published var denied = false
    @Published var failed = false

    private let manager = CLLocationManager()
    private var timer: Timer?
    private var lastFetch = Date.distantPast
    private var active = false

    func start() {
        guard !active else { return }
        active = true
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        } else {
            handleAuthorization()
        }
    }

    func stop() {
        active = false
        timer?.invalidate()
        timer = nil
        manager.stopUpdatingLocation()
    }

    func retry() {
        failed = false
        if active { manager.requestLocation() }
    }

    /// Actualiza si los datos tienen más de 15 minutos (o si falló antes) y mantiene el refresco cada 30 min.
    private func handleAuthorization() {
        guard active else { return }
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            denied = false
            if failed || Date().timeIntervalSince(lastFetch) > 900 { manager.requestLocation() }
            if timer == nil {
                timer = Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { [weak self] _ in
                    self?.manager.requestLocation()
                }
            }
        case .denied, .restricted:
            denied = true
            timer?.invalidate()
            timer = nil
        default:
            break
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        handleAuthorization()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard active, let location = locations.last else { return }
        fetch(location)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if temperature == nil { failed = true }
    }

    private func fetch(_ location: CLLocation) {
        let lat = location.coordinate.latitude
        let lon = location.coordinate.longitude
        let urlString = "https://api.open-meteo.com/v1/forecast?latitude=\(lat)&longitude=\(lon)"
            + "&current=temperature_2m,weather_code,is_day"
            + "&hourly=temperature_2m,weather_code,is_day"
            + "&daily=temperature_2m_max,temperature_2m_min"
            + "&timezone=auto&forecast_days=2"
        guard let url = URL(string: urlString) else { return }

        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let current = json["current"] as? [String: Any],
                  let temp = (current["temperature_2m"] as? NSNumber)?.doubleValue,
                  let code = (current["weather_code"] as? NSNumber)?.intValue else {
                DispatchQueue.main.async {
                    if self?.temperature == nil { self?.failed = true }
                }
                return
            }
            let isDay = ((current["is_day"] as? NSNumber)?.intValue ?? 1) == 1
            let described = WeatherModel.describe(code: code, day: isDay)
            let daily = json["daily"] as? [String: Any]
            let high = ((daily?["temperature_2m_max"] as? [NSNumber])?.first)?.doubleValue
            let low = ((daily?["temperature_2m_min"] as? [NSNumber])?.first)?.doubleValue
            let hours = WeatherModel.parseHours(json)

            DispatchQueue.main.async {
                guard let self else { return }
                self.lastFetch = Date()
                self.failed = false
                self.temperature = Int(temp.rounded())
                self.symbol = described.symbol
                self.summary = described.text
                self.high = high.map { Int($0.rounded()) }
                self.low = low.map { Int($0.rounded()) }
                self.hours = hours
            }
        }.resume()

        CLGeocoder().reverseGeocodeLocation(location) { [weak self] marks, _ in
            if let name = marks?.first?.locality {
                DispatchQueue.main.async {
                    self?.place = name
                }
            }
        }
    }

    /// Previsión hora a hora (hoy y mañana). Open-Meteo da las horas en la zona del lugar.
    private static func parseHours(_ json: [String: Any]) -> [HourForecast] {
        guard let hourly = json["hourly"] as? [String: Any],
              let times = hourly["time"] as? [String],
              let temps = hourly["temperature_2m"] as? [NSNumber],
              let codes = hourly["weather_code"] as? [NSNumber] else { return [] }
        let days = hourly["is_day"] as? [NSNumber] ?? []

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        let offset = (json["utc_offset_seconds"] as? NSNumber)?.intValue ?? TimeZone.current.secondsFromGMT()
        formatter.timeZone = TimeZone(secondsFromGMT: offset)

        var result: [HourForecast] = []
        for index in 0..<min(times.count, temps.count, codes.count) {
            guard let date = formatter.date(from: times[index]) else { continue }
            let day = index < days.count ? days[index].intValue == 1 : true
            result.append(HourForecast(
                date: date,
                temperature: Int(temps[index].doubleValue.rounded()),
                symbol: describe(code: codes[index].intValue, day: day).symbol
            ))
        }
        return result
    }

    static func describe(code: Int, day: Bool) -> (symbol: String, text: String) {
        switch code {
        case 0: return (day ? "sun.max.fill" : "moon.stars.fill", "Despejado")
        case 1, 2: return (day ? "cloud.sun.fill" : "cloud.moon.fill", "Poco nuboso")
        case 3: return ("cloud.fill", "Nublado")
        case 45, 48: return ("cloud.fog.fill", "Niebla")
        case 51...57: return ("cloud.drizzle.fill", "Llovizna")
        case 61...67: return ("cloud.rain.fill", "Lluvia")
        case 71...77: return ("cloud.snow.fill", "Nieve")
        case 80...82: return ("cloud.heavyrain.fill", "Chubascos")
        case 85, 86: return ("cloud.snow.fill", "Nevadas")
        case 95...99: return ("cloud.bolt.rain.fill", "Tormenta")
        default: return ("cloud.fill", "Variable")
        }
    }
}

// MARK: - Dispositivos Bluetooth con batería (AirPods, ratón…)

struct BatteryPart: Hashable {
    let label: String
    let percent: Int
}

struct BTDevice: Identifiable {
    let id: String
    let name: String
    let icon: String
    let parts: [BatteryPart]
}

final class DevicesModel: ObservableObject {
    @Published var devices: [BTDevice] = []
    private var lastRefresh = Date.distantPast

    func refresh(force: Bool = false, completion: (() -> Void)? = nil) {
        guard force || Date().timeIntervalSince(lastRefresh) > 30 else {
            completion?()
            return
        }
        lastRefresh = Date()

        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
            process.arguments = ["SPBluetoothDataType", "-json"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice

            do { try process.run() } catch {
                DispatchQueue.main.async { completion?() }
                return
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            let parsed = DevicesModel.parse(data)
            DispatchQueue.main.async {
                self.devices = parsed
                completion?()
            }
        }
    }

    private static func parse(_ data: Data) -> [BTDevice] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sections = root["SPBluetoothDataType"] as? [[String: Any]] else { return [] }

        func percent(_ props: [String: Any], _ key: String) -> Int? {
            guard let raw = props[key] as? String else { return nil }
            let digits = raw.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)
            return Int(digits)
        }

        var result: [BTDevice] = []
        for section in sections {
            guard let connected = section["device_connected"] as? [[String: Any]] else { continue }
            for entry in connected {
                for (name, value) in entry {
                    guard let props = value as? [String: Any] else { continue }

                    var parts: [BatteryPart] = []
                    if let v = percent(props, "device_batteryLevelLeft") { parts.append(BatteryPart(label: "I", percent: v)) }
                    if let v = percent(props, "device_batteryLevelRight") { parts.append(BatteryPart(label: "D", percent: v)) }
                    if let v = percent(props, "device_batteryLevelCase") { parts.append(BatteryPart(label: "Estuche", percent: v)) }
                    if let v = percent(props, "device_batteryLevelMain") { parts.append(BatteryPart(label: "", percent: v)) }
                    guard !parts.isEmpty else { continue }

                    result.append(BTDevice(
                        id: name,
                        name: name,
                        icon: icon(name: name, minor: props["device_minorType"] as? String),
                        parts: parts
                    ))
                }
            }
        }
        return result
    }

    static func icon(name: String, minor: String?) -> String {
        let lowered = name.lowercased()
        if lowered.contains("airpods max") { return "airpods.max" }
        if lowered.contains("airpods pro") { return "airpods.pro" }
        if lowered.contains("airpods") { return "airpods" }
        switch (minor ?? "").lowercased() {
        case "headphones", "headset": return "headphones"
        case "mouse": return "computermouse.fill"
        case "keyboard": return "keyboard.fill"
        default: return "dot.radiowaves.left.and.right"
        }
    }
}


// MARK: - Aviso al conectar un dispositivo Bluetooth

final class BluetoothWatcher: NSObject {
    var onConnect: ((String) -> Void)?
    private var registration: IOBluetoothUserNotification?
    private var thread: Thread?

    /// IOBluetooth se queda esperando el permiso de Bluetooth del sistema. Si eso pasara en el hilo
    /// principal, TODA la app se congelaría hasta contestar el aviso (sin hover ni animaciones).
    /// Por eso se registra en un hilo propio, que además mantiene vivo su run loop para recibir avisos.
    func start() {
        guard thread == nil else { return }
        let worker = Thread { [weak self] in
            guard let self else { return }
            self.registration = IOBluetoothDevice.register(
                forConnectNotifications: self,
                selector: #selector(self.deviceConnected(_:device:))
            )
            Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in }
            RunLoop.current.run()
        }
        worker.name = "notchisland.bluetooth"
        worker.qualityOfService = .utility
        worker.start()
        thread = worker
    }

    @objc private func deviceConnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        guard let name = device.name else { return }
        DispatchQueue.main.async { self.onConnect?(name) }
    }
}

extension DevicesModel {
    /// Icono y batería de un dispositivo ya leído (si lo hay).
    func info(for name: String) -> (icon: String, percent: Int?) {
        if let device = devices.first(where: { $0.name == name }) {
            return (device.icon, device.parts.map { $0.percent }.min())
        }
        return (DevicesModel.icon(name: name, minor: nil), nil)
    }
}
