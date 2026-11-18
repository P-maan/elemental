import EventKit
import Foundation

/// Alerts from this Mac's own Calendar and Reminders, in the sky (18 Nov 2026, his ask:
/// "add option for more alerts like on-device reminders and calendar events"). Every
/// minute it looks at the next 15 minutes:
///   * a calendar event about to start glows blue and grows as it gets close, with a
///     soft notice pulse at its start;
///   * a reminder due now (or overdue today and not done) glows amber, with a pulse when due.
/// Read only - nothing is ever written to his calendars or reminders. It goes through the
/// same sky signals Zo uses, so it looks like everything else and clears itself.
final class DeviceAlerts: @unchecked Sendable {
    static let shared = DeviceAlerts()
    private let store = EKEventStore()
    private var timer: Timer?
    private var calOK = false, remOK = false
    private var pulsed = Set<String>()

    func start() {
        guard timer == nil else { return }
        store.requestFullAccessToEvents { ok, _ in self.calOK = ok }
        store.requestFullAccessToReminders { ok, _ in self.remOK = ok }
        let t = Timer(timeInterval: 60, repeats: true) { _ in self.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { self.tick() }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        Signals.shared.clear("zo.device.cal"); Signals.shared.clear("zo.device.rem")
    }

    var report: [String: Any] { ["calendar": calOK, "reminders": remOK, "running": timer != nil] }

    private func tick() {
        let now = Date()
        let f = DateFormatter(); f.dateFormat = "h:mm"
        if calOK {
            let pred = store.predicateForEvents(withStart: now.addingTimeInterval(-60), end: now.addingTimeInterval(15 * 60), calendars: nil)
            let next = store.events(matching: pred)
                .filter { !$0.isAllDay && $0.startDate >= now.addingTimeInterval(-60) && $0.status != .canceled }
                .sorted { $0.startDate < $1.startDate }.first
            if let e = next {
                let mins = max(0, e.startDate.timeIntervalSince(now) / 60)
                Signals.shared.set("zo.device.cal", value: Float(0.35 + 0.65 * (1 - min(1, mins / 15))),
                                   color: SIMD3<Float>(0.35, 0.6, 1.0),
                                   label: "\(e.title ?? "Event") \(f.string(from: e.startDate))", seconds: 120)
                let key = "cal|\(e.eventIdentifier ?? "")|\(e.startDate.timeIntervalSince1970)"
                if mins < 1, !pulsed.contains(key) { pulsed.insert(key); Pulse.shared.play(.notice) }
            } else { Signals.shared.clear("zo.device.cal") }
        }
        if remOK {
            let start = Calendar.current.startOfDay(for: now)
            let pred = store.predicateForIncompleteReminders(withDueDateStarting: start, ending: now.addingTimeInterval(10 * 60), calendars: nil)
            store.fetchReminders(matching: pred) { rems in
                let due = (rems ?? []).compactMap { r -> (EKReminder, Date)? in
                    guard let d = r.dueDateComponents?.date else { return nil }
                    return (r, d)
                }.sorted { $0.1 < $1.1 }
                DispatchQueue.main.async {
                    if let (r, d) = due.first {
                        Signals.shared.set("zo.device.rem", value: d <= now ? 0.9 : 0.55,
                                           color: SIMD3<Float>(1.0, 0.68, 0.25),
                                           label: r.title ?? "Reminder", seconds: 120)
                        let key = "rem|\(r.calendarItemIdentifier)"
                        if d <= now, !self.pulsed.contains(key) { self.pulsed.insert(key); Pulse.shared.play(.notice) }
                    } else { Signals.shared.clear("zo.device.rem") }
                }
            }
        }
        if pulsed.count > 300 { pulsed.removeAll() }
    }
}
