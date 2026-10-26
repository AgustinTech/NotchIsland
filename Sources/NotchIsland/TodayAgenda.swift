import AppKit
import SwiftUI

// MARK: - Panel: Agenda / Recordatorios

enum TodaySegment {
    case agenda, reminders
}

/// Tarjeta principal de "Hoy". Un selector arriba alterna entre la agenda (hoy y mañana) y los
/// recordatorios pendientes. Sin elegir nada, enseña lo que tenga contenido.
struct AgendaPanel: View {
    @ObservedObject var model: CalendarModel
    @State private var chosen: TodaySegment?
    @Namespace private var segmentSpace

    private static let padTop: CGFloat = 9
    private static let padBottom: CGFloat = 8
    private static let headerHeight: CGFloat = 21
    private static let headerGap: CGFloat = 5

    var body: some View {
        // Reevalúa cada 30 s: la cuenta atrás, "Ahora" y los eventos que terminan se mantienen al día.
        TimelineView(.periodic(from: Date(), by: 30)) { context in
            let now = context.date
            let segment = activeSegment(now)

            GeometryReader { geo in
                let listHeight = geo.size.height - Self.padTop - Self.padBottom - Self.headerHeight - Self.headerGap
                let agenda = AgendaPlan(events: model.events.filter { $0.end > now }, height: listHeight)
                let reminders = ReminderPlan(reminders: model.reminders, height: listHeight)

                VStack(alignment: .leading, spacing: Self.headerGap) {
                    header(
                        segment,
                        now: now,
                        agendaCount: model.eventsAccess == .granted ? agenda.total : nil,
                        reminderCount: model.remindersAccess == .granted ? model.reminders.count : nil,
                        hidden: segment == .agenda ? agenda.hidden : reminders.hidden
                    )

                    ZStack(alignment: .top) {
                        if segment == .agenda {
                            AgendaList(model: model, plan: agenda, now: now)
                                .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
                        } else {
                            ReminderList(model: model, plan: reminders, now: now)
                                .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .clipped()
                }
                .padding(.horizontal, 10)
                .padding(.top, Self.padTop)
                .padding(.bottom, Self.padBottom)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
            }
            .todaySurface()
            .animation(.spring(response: 0.38, dampingFraction: 0.86), value: segment)
        }
    }

    private func activeSegment(_ now: Date) -> TodaySegment {
        if let chosen { return chosen }
        let hasEvents = model.eventsAccess == .granted && model.events.contains { $0.end > now }
        let hasReminders = model.remindersAccess == .granted && !model.reminders.isEmpty
        return (!hasEvents && hasReminders) ? .reminders : .agenda
    }

    // MARK: Cabecera

    private func header(_ segment: TodaySegment, now: Date, agendaCount: Int?, reminderCount: Int?, hidden: Int) -> some View {
        HStack(spacing: 1) {
            tab(.agenda, title: "Agenda", symbol: "calendar", count: agendaCount, selected: segment)
            tab(.reminders, title: "Recordatorios", symbol: "checklist", count: reminderCount, selected: segment)

            Spacer(minLength: 4)

            // Lo que no cabe se resume aquí (y abre la app); si todo cabe, la fecha de hoy.
            if hidden > 0 {
                TodayMoreButton(
                    count: hidden,
                    bundleID: segment == .agenda ? "com.apple.iCal" : "com.apple.reminders"
                )
                .transition(.opacity)
            } else {
                Text(now.formatted(.dateTime.weekday(.abbreviated).day()))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.35))
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.trailing, 3)
                    .transition(.opacity)
            }
        }
        .frame(height: Self.headerHeight)
        .animation(.easeOut(duration: 0.2), value: hidden)
    }

    private func tab(_ target: TodaySegment, title: String, symbol: String, count: Int?, selected: TodaySegment) -> some View {
        let isSelected = selected == target
        return Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { chosen = target }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 9.5, weight: .semibold))
                Text(title)
                    .font(.system(size: 10.5, weight: .semibold))
                    .lineLimit(1)
                if let count, count > 0 {
                    Text("\(count)")
                        .font(.system(size: 9, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(isSelected ? Color.black.opacity(0.85) : Color.white.opacity(0.7))
                        .padding(.horizontal, 4.5)
                        .frame(minWidth: 14, minHeight: 13)
                        .background(Capsule().fill(isSelected ? Color.white.opacity(0.9) : Color.white.opacity(0.14)))
                        .contentTransition(.numericText())
                }
            }
            .fixedSize()
            .foregroundStyle(Color.white.opacity(isSelected ? 1 : 0.45))
            .padding(.horizontal, 7)
            .frame(height: Self.headerHeight)
            .background {
                if isSelected {
                    Capsule()
                        .fill(Color.white.opacity(0.15))
                        .matchedGeometryEffect(id: "segment", in: segmentSpace)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(ScaleButtonStyle(pressed: 0.94))
    }
}

// MARK: - Reparto del espacio

/// Qué filas caben sin tener que desplazar nada (el gesto de dos dedos del notch cierra la isla,
/// así que aquí no hay desplazamiento vertical: lo que sobra se resume en la cabecera).
enum TodayPacking {
    static func fit(count: Int, available: CGFloat, row: CGFloat, gap: CGFloat, used: CGFloat = 0) -> Int {
        var height = used
        var shown = 0
        while shown < count {
            let next = height + (height > 0 ? gap : 0) + row
            if next > available + 0.5 { break }
            height = next
            shown += 1
        }
        return shown
    }
}

struct AgendaPlan {
    static let heroHeight: CGFloat = 40
    static let rowHeight: CGFloat = 20
    static let gap: CGFloat = 2

    let hero: AgendaEvent?
    let rows: [AgendaEvent]
    let hidden: Int

    var total: Int { (hero == nil ? 0 : 1) + rows.count + hidden }

    /// `events` ya viene ordenado (hoy antes que mañana, los de todo el día primero).
    init(events: [AgendaEvent], height: CGFloat) {
        // La primera cita con hora (la que está en curso o la siguiente) se destaca.
        let first = events.first { !$0.allDay }
        let rest = events.filter { $0.id != first?.id }
        let shown = TodayPacking.fit(
            count: rest.count,
            available: height,
            row: Self.rowHeight,
            gap: Self.gap,
            used: first == nil ? 0 : Self.heroHeight
        )
        hero = first
        rows = Array(rest.prefix(shown))
        hidden = rest.count - shown
    }
}

struct ReminderPlan {
    static let rowHeight: CGFloat = 20
    static let gap: CGFloat = 2

    let rows: [AgendaReminder]
    let hidden: Int

    init(reminders: [AgendaReminder], height: CGFloat) {
        let shown = TodayPacking.fit(count: reminders.count, available: height, row: Self.rowHeight, gap: Self.gap)
        rows = Array(reminders.prefix(shown))
        hidden = reminders.count - shown
    }
}

/// "+4 más" en la cabecera: abre la app correspondiente.
struct TodayMoreButton: View {
    let count: Int
    let bundleID: String
    @State private var hover = false

    var body: some View {
        Button {
            TodaySettings.openApp(bundleID)
        } label: {
            HStack(spacing: 3) {
                Text("+\(count) más")
                    .monospacedDigit()
                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 7.5, weight: .bold))
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Color.white.opacity(hover ? 0.9 : 0.55))
            .padding(.horizontal, 8)
            .frame(height: 19)
            .background(Capsule().fill(Color.white.opacity(hover ? 0.14 : 0.08)))
            .fixedSize()
        }
        .buttonStyle(ScaleButtonStyle(pressed: 0.92))
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.15), value: hover)
    }
}

// MARK: - Agenda

struct AgendaList: View {
    @ObservedObject var model: CalendarModel
    let plan: AgendaPlan
    let now: Date

    var body: some View {
        switch model.eventsAccess {
        case .unknown:
            TodayEmptyState(
                symbol: "calendar",
                tint: Color.white.opacity(0.4),
                title: "Esperando el permiso…",
                message: "Acepta el aviso del sistema para ver tu agenda."
            )
        case .denied:
            TodayEmptyState(
                symbol: "calendar.badge.exclamationmark",
                tint: Color.orange,
                title: "Sin acceso al calendario",
                message: "Permítelo en Ajustes del Sistema.",
                actionTitle: "Abrir Ajustes"
            ) { TodaySettings.openPrivacy("Privacy_Calendars") }
        case .granted:
            agenda
        }
    }

    @ViewBuilder
    private var agenda: some View {
        if plan.total == 0 {
            TodayEmptyState(
                symbol: "sun.max.fill",
                tint: Color(red: 1, green: 0.78, blue: 0.25),
                title: "Día libre",
                message: "Nada en tu agenda hoy ni mañana."
            )
        } else {
            VStack(spacing: AgendaPlan.gap) {
                if let hero = plan.hero {
                    AgendaHero(event: hero, now: now)
                        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                }
                ForEach(plan.rows) { event in
                    AgendaRow(event: event, now: now)
                        .frame(height: AgendaPlan.rowHeight)
                        .transition(.opacity.combined(with: .offset(y: 6)))
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: plan.rows.map { $0.id } + [plan.hero?.id ?? ""])
        }
    }
}

/// Texto "Mañana", "10:30"… según el día del evento.
private func isTomorrowOrLater(_ date: Date, now: Date) -> Bool {
    !Calendar.current.isDate(date, inSameDayAs: now) && date > now
}

private func clock(_ date: Date) -> String {
    date.formatted(.dateTime.hour().minute())
}

/// Cita destacada: la que está en curso o la siguiente, con su cuenta atrás.
struct AgendaHero: View {
    let event: AgendaEvent
    let now: Date
    @State private var hover = false

    private var live: Bool { event.start <= now }

    private var minutesToStart: Int {
        Int(event.start.timeIntervalSince(now) / 60)
    }

    private var timeText: String {
        if live { return "Hasta " + clock(event.end) }
        if isTomorrowOrLater(event.start, now: now) { return "Mañana · " + clock(event.start) }
        return clock(event.start) + " – " + clock(event.end)
    }

    private var remainingText: String? {
        guard live else { return nil }
        let minutes = max(1, Int(event.end.timeIntervalSince(now) / 60))
        if minutes >= 120 { return nil }
        return minutes >= 60 ? "quedan \(minutes / 60) h \(minutes % 60) min" : "quedan \(minutes) min"
    }

    private var badge: (text: String, color: Color)? {
        if live { return ("Ahora", Color.green) }
        let minutes = minutesToStart
        if minutes < 1 { return ("Ya", Color.orange) }
        if minutes < 60 { return ("En \(minutes) min", minutes <= 10 ? Color.orange : Color.white) }
        if minutes < 720, !isTomorrowOrLater(event.start, now: now) {
            return ("En \(minutes / 60) h \(minutes % 60) min", Color.white)
        }
        return nil
    }

    var body: some View {
        Button {
            TodaySettings.openApp("com.apple.iCal")
        } label: {
            HStack(spacing: 9) {
                Capsule()
                    .fill(event.tint)
                    .frame(width: 3.5)
                    .padding(.vertical, 1)

                VStack(alignment: .leading, spacing: 2) {
                    Text(event.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.white)
                        .lineLimit(1)

                    HStack(spacing: 4) {
                        Text(timeText)
                            .monospacedDigit()
                            .fixedSize()
                        if let remainingText {
                            Text("· " + remainingText)
                                .lineLimit(1)
                        } else if let location = event.location {
                            Text("· " + location)
                                .lineLimit(1)
                        }
                    }
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.white.opacity(0.58))
                }

                Spacer(minLength: 4)

                if let badge {
                    Text(badge.text)
                        .font(.system(size: 10, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(badge.color)
                        .padding(.horizontal, 8)
                        .frame(height: 19)
                        .background(Capsule().fill(badge.color.opacity(0.18)))
                        .fixedSize()
                        .contentTransition(.numericText())
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 40)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(event.tint.opacity(hover ? 0.26 : 0.17))
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(ScaleButtonStyle(pressed: 0.975))
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.15), value: hover)
        .animation(.easeInOut(duration: 0.3), value: badge?.text)
    }
}

/// Fila compacta de una cita.
struct AgendaRow: View {
    let event: AgendaEvent
    let now: Date
    @State private var hover = false

    private var live: Bool { event.start <= now && !event.allDay }

    private var timeText: String {
        let later = isTomorrowOrLater(event.start, now: now)
        if event.allDay { return later ? "Mañana" : "Todo el día" }
        return later ? "Mañana " + clock(event.start) : clock(event.start)
    }

    var body: some View {
        Button {
            TodaySettings.openApp("com.apple.iCal")
        } label: {
            HStack(spacing: 8) {
                Capsule()
                    .fill(event.tint)
                    .frame(width: 3, height: 12)

                Text(event.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.92))
                    .lineLimit(1)

                Spacer(minLength: 6)

                Text(live ? "Ahora" : timeText)
                    .font(.system(size: 10, weight: live ? .semibold : .regular))
                    .monospacedDigit()
                    .foregroundStyle(live ? Color.green : Color.white.opacity(0.4))
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, 8)
            .frame(maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.white.opacity(hover ? 0.07 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.15), value: hover)
    }
}

// MARK: - Recordatorios

struct ReminderList: View {
    @ObservedObject var model: CalendarModel
    let plan: ReminderPlan
    let now: Date

    var body: some View {
        switch model.remindersAccess {
        case .unknown:
            TodayEmptyState(
                symbol: "checklist",
                tint: Color.white.opacity(0.4),
                title: "Esperando el permiso…",
                message: "Acepta el aviso del sistema para ver tus recordatorios."
            )
        case .denied:
            TodayEmptyState(
                symbol: "exclamationmark.lock.fill",
                tint: Color.orange,
                title: "Sin acceso a Recordatorios",
                message: "Permítelo en Ajustes del Sistema.",
                actionTitle: "Abrir Ajustes"
            ) { TodaySettings.openPrivacy("Privacy_Reminders") }
        case .granted:
            list
        }
    }

    @ViewBuilder
    private var list: some View {
        if model.reminders.isEmpty {
            TodayEmptyState(
                symbol: "checkmark.circle.fill",
                tint: Color.green,
                title: "Todo al día",
                message: "No tienes recordatorios pendientes."
            )
        } else {
            VStack(spacing: ReminderPlan.gap) {
                ForEach(plan.rows) { reminder in
                    ReminderRow(
                        reminder: reminder,
                        done: model.completing.contains(reminder.id),
                        now: now
                    ) {
                        model.toggleReminder(reminder.id)
                    }
                    .frame(height: ReminderPlan.rowHeight)
                    .transition(
                        .asymmetric(
                            insertion: .opacity.combined(with: .offset(y: 6)),
                            removal: .opacity.combined(with: .scale(scale: 0.92, anchor: .leading))
                        )
                    )
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: plan.rows.map { $0.id })
        }
    }
}

struct ReminderRow: View {
    let reminder: AgendaReminder
    let done: Bool
    let now: Date
    let toggle: () -> Void
    @State private var hover = false

    private var dueLabel: (text: String, color: Color)? {
        guard let due = reminder.due else { return nil }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        if due < today {
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: due), to: today).day ?? 1
            return (days <= 1 ? "Ayer" : "Hace \(days) d", Color.red)
        }
        if reminder.hasTime {
            return (clock(due), due < now ? Color.red : Color.white.opacity(0.4))
        }
        return ("Hoy", Color.white.opacity(0.4))
    }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: toggle) {
                CheckCircle(tint: reminder.tint, done: done, hover: hover)
                    .frame(width: 26, height: 20, alignment: .leading)
                    .padding(.leading, 4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(ScaleButtonStyle(pressed: 0.82))

            Button {
                TodaySettings.openApp("com.apple.reminders")
            } label: {
                HStack(spacing: 6) {
                    Text(reminder.title)
                        .font(.system(size: 12, weight: .medium))
                        .strikethrough(done, color: Color.white.opacity(0.4))
                        .foregroundStyle(Color.white.opacity(done ? 0.35 : 0.92))
                        .lineLimit(1)

                    Spacer(minLength: 6)

                    if let label = dueLabel {
                        Text(label.text)
                            .font(.system(size: 10, weight: label.color == Color.red ? .semibold : .regular))
                            .monospacedDigit()
                            .foregroundStyle(done ? Color.white.opacity(0.25) : label.color)
                            .fixedSize()
                    }
                }
                .padding(.trailing, 7)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.white.opacity(hover ? 0.07 : 0))
        )
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.15), value: hover)
        .animation(.easeOut(duration: 0.2), value: done)
    }
}

/// Círculo de recordatorio: anillo del color de su lista que se rellena con una marca al completarlo.
struct CheckCircle: View {
    let tint: Color
    let done: Bool
    let hover: Bool

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(tint.opacity(done ? 0 : (hover ? 1 : 0.85)), lineWidth: 1.5)
            Circle()
                .fill(tint.opacity(hover && !done ? 0.2 : 0))
            Circle()
                .fill(tint)
                .scaleEffect(done ? 1 : 0.2)
                .opacity(done ? 1 : 0)
            Image(systemName: "checkmark")
                .font(.system(size: 8, weight: .heavy))
                .foregroundStyle(Color.black.opacity(0.8))
                .scaleEffect(done ? 1 : 0.2)
                .opacity(done ? 1 : 0)
        }
        .frame(width: 15, height: 15)
        .animation(.spring(response: 0.3, dampingFraction: 0.62), value: done)
        .animation(.easeOut(duration: 0.15), value: hover)
    }
}
