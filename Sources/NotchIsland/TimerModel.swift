import AppKit
import Combine
import Foundation

/// Lo que se enseña en un instante: los segundos y la parte del anillo que se dibuja.
struct TimerReading: Equatable {
    /// Segundos que faltan (cuenta atrás) o que han pasado (cronómetro).
    var seconds: Int
    /// Cuenta atrás: lo que queda (1 = entero, 0 = acabado). Cronómetro: vuelta de un minuto.
    var fraction: Double
}

/// Temporizador, Pomodoro y cronómetro de la pestaña Herramientas.
///
/// Guarda la FECHA DE FIN (la de inicio, en el cronómetro) en vez de ir restando segundos: así sobrevive
/// a un reinicio de la app y no hace falta ningún temporizador por segundo. Lo único que se programa es un
/// aviso único para la hora exacta en que termina. Las vistas se refrescan solas con `TimelineView`
/// (una vez por segundo, y solo mientras se ven y el contador corre); parado o en pausa no hay nada vivo.
final class TimerModel: ObservableObject {
    enum Mode: String, Codable, CaseIterable, Identifiable {
        case timer, pomodoro, stopwatch

        var id: String { rawValue }

        var title: String {
            switch self {
            case .timer: return "Temporizador"
            case .pomodoro: return "Pomodoro"
            case .stopwatch: return "Cronómetro"
            }
        }
    }

    enum Phase: String, Codable {
        case idle, running, paused, finished
    }

    /// Tramos del Pomodoro: 25 min de enfoque y 5 de descanso (15 tras el cuarto enfoque).
    enum Segment: String, Codable {
        case focus, shortBreak, longBreak

        var minutes: Int {
            switch self {
            case .focus: return 25
            case .shortBreak: return 5
            case .longBreak: return 15
            }
        }

        var title: String {
            switch self {
            case .focus: return "Enfoque"
            case .shortBreak: return "Descanso"
            case .longBreak: return "Descanso largo"
            }
        }

        var isBreak: Bool { self != .focus }
    }

    static let presets = [5, 10, 15, 25]
    static let maxMinutes = 180
    /// Enfoques por ciclo del Pomodoro (el cuarto va seguido de un descanso largo).
    static let cycle = 4
    /// Lo que se ensancha el notch cerrado a cada lado mientras corre.
    static let liveSide: CGFloat = 52

    @Published private(set) var mode: Mode = .timer
    @Published private(set) var phase: Phase = .idle
    /// Duración elegida en el temporizador (segundos).
    @Published private(set) var duration: TimeInterval = 5 * 60
    @Published private(set) var segment: Segment = .focus
    /// Enfoques completados hoy.
    @Published private(set) var pomodoros = 0
    /// Corriendo: fecha de fin (cuenta atrás) o de inicio (cronómetro).
    @Published private(set) var anchor: Date?

    /// En pausa: lo que faltaba (cuenta atrás) o lo transcurrido (cronómetro).
    private var frozen: TimeInterval = 0
    /// Duración total de la cuenta atrás en marcha (crece con "+1 min").
    private var runTotal: TimeInterval = 0
    private var pomodoroDay = Date()

    /// Se llama (en el hilo principal) al terminar, con el texto del aviso.
    var onFinish: ((String) -> Void)?

    private var finishTimer: Timer?
    private var sound: NSSound?
    private var wakeToken: NSObjectProtocol?
    private let defaults: UserDefaults
    private let storageKey = "timerState"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        restore()
        // Con el Mac dormido el aviso puede llegar tarde: al despertar se revisa la hora de fin.
        wakeToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.finishIfDue()
        }
    }

    deinit {
        finishTimer?.invalidate()
        if let wakeToken { NSWorkspace.shared.notificationCenter.removeObserver(wakeToken) }
    }

    // MARK: - Estado derivado

    var isActive: Bool { phase == .running || phase == .paused }

    /// El notch cerrado enseña el contador mientras corre o está en pausa.
    var showsLive: Bool { isActive }

    /// Segundos de la cuenta atrás cuando está parada (lo que se ve antes de empezar).
    var idleSeconds: TimeInterval {
        switch mode {
        case .timer: return duration
        case .pomodoro: return TimeInterval(segment.minutes * 60)
        case .stopwatch: return 0
        }
    }

    var total: TimeInterval { phase == .idle || phase == .finished ? idleSeconds : max(runTotal, 1) }

    /// Título corto: "Temporizador", "Enfoque", "Descanso", "Cronómetro".
    var label: String {
        switch mode {
        case .timer: return "Temporizador"
        case .pomodoro: return segment.title
        case .stopwatch: return "Cronómetro"
        }
    }

    /// Texto del aviso al terminar (el de la línea inferior del notch).
    var finishTitle: String {
        switch mode {
        case .timer: return "Temporizador terminado"
        case .pomodoro: return segment.isBreak ? "Descanso terminado" : "Enfoque terminado"
        case .stopwatch: return "Cronómetro"
        }
    }

    /// Hora a la que suena (solo corriendo y contando atrás).
    var endDate: Date? {
        guard phase == .running, mode != .stopwatch else { return nil }
        return anchor
    }

    /// Puntos llenos del ciclo del Pomodoro (0...4).
    var cycleProgress: Int {
        if segment == .longBreak { return Self.cycle }
        return pomodoros % Self.cycle
    }

    func reading(at date: Date) -> TimerReading {
        if mode == .stopwatch {
            let elapsed: TimeInterval
            switch phase {
            case .running: elapsed = max(0, date.timeIntervalSince(anchor ?? date))
            case .paused: elapsed = frozen
            default: elapsed = 0
            }
            return TimerReading(
                seconds: Int(elapsed.rounded(.down)),
                fraction: elapsed.truncatingRemainder(dividingBy: 60) / 60
            )
        }

        let remaining: TimeInterval
        switch phase {
        case .running: remaining = max(0, (anchor ?? date).timeIntervalSince(date))
        case .paused: remaining = frozen
        case .idle: remaining = idleSeconds
        case .finished: remaining = 0
        }
        // El margen evita que un segundo exacto (300,0000001) se enseñe como 301.
        return TimerReading(
            seconds: max(0, Int((remaining - 0.0005).rounded(.up))),
            fraction: min(1, remaining / total)
        )
    }

    // MARK: - Acciones

    func toggle() {
        switch phase {
        case .idle, .finished: start()
        case .running: pause()
        case .paused: resume()
        }
    }

    func start() {
        let now = Date()
        if mode == .stopwatch {
            anchor = now
            frozen = 0
        } else {
            runTotal = idleSeconds
            anchor = now.addingTimeInterval(runTotal)
        }
        phase = .running
        scheduleFinish()
        save()
    }

    func pause() {
        guard phase == .running, let anchor else { return }
        let now = Date()
        frozen = mode == .stopwatch ? max(0, now.timeIntervalSince(anchor)) : max(0, anchor.timeIntervalSince(now))
        self.anchor = nil
        phase = .paused
        cancelFinish()
        save()
    }

    func resume() {
        guard phase == .paused else { return }
        let now = Date()
        anchor = mode == .stopwatch ? now.addingTimeInterval(-frozen) : now.addingTimeInterval(frozen)
        phase = .running
        scheduleFinish()
        save()
    }

    /// Vuelve al principio (el Pomodoro, al primer enfoque). Conserva el modo y la duración elegida.
    func reset() {
        cancelFinish()
        anchor = nil
        frozen = 0
        if mode == .pomodoro { segment = .focus }
        phase = .idle
        save()
    }

    func setMode(_ newMode: Mode) {
        guard newMode != mode, phase == .idle || phase == .finished else { return }
        cancelFinish()
        anchor = nil
        mode = newMode
        segment = .focus
        phase = .idle
        save()
    }

    /// Cambia la duración del temporizador parado (minutos, entre 1 y 180).
    func setMinutes(_ minutes: Int) {
        guard mode == .timer, phase == .idle else { return }
        let clamped = min(max(minutes, 1), Self.maxMinutes)
        guard TimeInterval(clamped * 60) != duration else { return }
        duration = TimeInterval(clamped * 60)
        save()
    }

    /// "+1 min" / "-1 min": parado cambia la duración; corriendo o en pausa alarga la cuenta atrás.
    func nudge(minutes: Int) {
        guard mode == .timer else { return }
        switch phase {
        case .idle:
            setMinutes(Int(duration / 60) + minutes)
        case .running:
            guard minutes > 0, let anchor else { return }
            self.anchor = anchor.addingTimeInterval(TimeInterval(minutes * 60))
            runTotal += TimeInterval(minutes * 60)
            scheduleFinish()
            save()
        case .paused:
            guard minutes > 0 else { return }
            frozen += TimeInterval(minutes * 60)
            runTotal += TimeInterval(minutes * 60)
            save()
        case .finished:
            break
        }
    }

    // MARK: - Fin

    private func scheduleFinish() {
        cancelFinish()
        guard phase == .running, mode != .stopwatch, let anchor else { return }
        let timer = Timer(fire: anchor, interval: 0, repeats: false) { [weak self] _ in
            self?.finishIfDue()
        }
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common)
        finishTimer = timer
    }

    private func cancelFinish() {
        finishTimer?.invalidate()
        finishTimer = nil
    }

    private func finishIfDue() {
        guard phase == .running, mode != .stopwatch, let anchor else { return }
        let late = Date().timeIntervalSince(anchor)
        if late >= -0.02 {
            complete(late: late, announce: true, autoContinue: true)
        } else {
            scheduleFinish()
        }
    }

    /// `announce`: suena y avisa en el notch (salvo que llegue muy tarde, p. ej. tras dormir el Mac).
    /// `autoContinue`: en el Pomodoro, el descanso empieza solo al terminar el enfoque.
    private func complete(late: TimeInterval, announce: Bool, autoContinue: Bool) {
        cancelFinish()
        anchor = nil
        frozen = 0
        let title = finishTitle

        switch mode {
        case .timer:
            phase = .finished
        case .pomodoro:
            if segment == .focus {
                if !Calendar.current.isDateInToday(pomodoroDay) { pomodoros = 0 }
                pomodoroDay = Date()
                pomodoros += 1
                segment = pomodoros % Self.cycle == 0 ? .longBreak : .shortBreak
                phase = .idle
                if autoContinue { start() }
            } else {
                segment = .focus
                phase = .idle
            }
        case .stopwatch:
            return
        }
        save()

        if announce && late < 20 {
            playSound()
            onFinish?(title)
        }
    }

    private func playSound() {
        sound?.stop()
        sound = NSSound(named: "Glass")
        sound?.play()
    }

    // MARK: - Guardado

    private struct Stored: Codable {
        var mode: Mode
        var phase: Phase
        var duration: Double
        var runTotal: Double
        var anchor: Date?
        var frozen: Double
        var segment: Segment
        var pomodoros: Int
        var pomodoroDay: Date
    }

    private func save() {
        let stored = Stored(
            mode: mode, phase: phase, duration: duration, runTotal: runTotal, anchor: anchor,
            frozen: frozen, segment: segment, pomodoros: pomodoros, pomodoroDay: pomodoroDay
        )
        if let data = try? JSONEncoder().encode(stored) {
            defaults.set(data, forKey: storageKey)
        }
    }

    private func restore() {
        guard let data = defaults.data(forKey: storageKey),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return }

        mode = stored.mode
        phase = stored.phase
        duration = min(max(stored.duration, 60), TimeInterval(Self.maxMinutes * 60))
        runTotal = stored.runTotal
        anchor = stored.anchor
        frozen = stored.frozen
        segment = stored.segment
        pomodoroDay = stored.pomodoroDay
        pomodoros = Calendar.current.isDateInToday(stored.pomodoroDay) ? stored.pomodoros : 0

        guard phase == .running else { return }
        guard mode != .stopwatch else { return }
        if let anchor, anchor > Date() {
            scheduleFinish()
        } else {
            // Terminó mientras la app estaba cerrada: se da por acabado sin sonido ni aviso.
            complete(late: .infinity, announce: false, autoContinue: false)
        }
    }
}
