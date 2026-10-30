import Foundation

// Модель состояний встречи: фаза по времени, решение
// пользователя и напоминание. Всё видимое — вид карточки, часы, окно и звук — вычисляется из них.

/// Когда начинать напоминание о встрече. О VIP — раньше, но никогда не позже, чем об обычной.
func remindAt(_ m: Meeting, config: Config) -> Date {
    m.start - (m.isVIP ? max(config.vipReminderOffsetSeconds, config.reminderOffsetSeconds) : config.reminderOffsetSeconds)
}

enum Phase { case ahead, soon, ongoing, past }

/// «Скоро» — за 10 минут до начала: с этого момента у карточки есть кнопка подключения.
func phase(_ m: Meeting, now: Date) -> Phase {
    if now >= m.end { return .past }
    if now >= m.start { return .ongoing }
    return now >= m.start - 600 ? .soon : .ahead
}

/// По встрече всё решено: пользователь подключился, пропустил её, игнорирует серию или в Outlook она «свободна».
func isSettled(_ m: Meeting, _ state: State) -> Bool {
    state.decisions[m.eventId] != nil || state.ignored[m.ignoreKey] != nil || m.isFree == true
}

/// Состояние напоминаний в памяти: до какого момента молчать, откладывал ли пользователь сам и
/// нажал ли «ОК».
struct Reminders {
    var quietUntil: [String: Date] = [:]
    /// Пользователь хоть раз сам отложил — предел в 10 минут после начала больше не действует.
    var userSnoozed: Set<String> = []
    /// «ОК» выключает будильник: напоминание больше не звенит, опоздание не показывается.
    var acknowledged: Set<String> = []

    /// Неотвеченное напоминание живёт до 10-й минуты после начала встречи, а отложенное мной — дольше.
    private func alive(_ m: Meeting, now: Date) -> Bool {
        !acknowledged.contains(m.reminderKey) && (userSnoozed.contains(m.reminderKey) || now < m.start + 600)
    }

    /// Встречи, о которых напоминание звенит прямо сейчас.
    func reminding(_ meetings: [Meeting], now: Date, state: State, config: Config) -> [Meeting] {
        meetings
            .filter { m in
                !m.isAllDay && !isSettled(m, state)
                    && remindAt(m, config: config) <= now && now < m.end && alive(m, now: now)
                    && quietUntil[m.reminderKey].map { $0 <= now } ?? true
            }
            .sorted { $0.start < $1.start }
    }

    /// Встречи, на которые пользователь опаздывает: уже идут, решения нет, напоминание не выключено и не истекло.
    func late(_ meetings: [Meeting], now: Date, state: State) -> [Meeting] {
        meetings
            .filter { m in
                !m.isAllDay && !isSettled(m, state) && m.start <= now && now < m.end && alive(m, now: now)
            }
            .sorted { $0.start < $1.start }
    }

    mutating func acknowledge(_ meetings: [Meeting]) {
        acknowledged.formUnion(meetings.map(\.reminderKey))
    }

    mutating func snooze(_ meetings: [Meeting], minutes: Int, now: Date, byUser: Bool) {
        for m in meetings {
            quietUntil[m.reminderKey] = now + Double(minutes * 60)
            if byUser { userSnoozed.insert(m.reminderKey) }
        }
    }
}

/// До какой встречи идёт отсчёт: ближайшая ещё не начавшаяся, по которой ничего не решено.
func countdownTarget(_ meetings: [Meeting], now: Date, state: State) -> Meeting? {
    meetings
        .filter { !$0.isAllDay && $0.start > now && !isSettled($0, state) }
        .min { $0.start < $1.start }
}

/// `12:45`, а от часа — `1:20:00`. Секунды округляются вверх, чтобы ноль совпал с началом встречи.
func countdownText(_ seconds: TimeInterval) -> String {
    let s = Int(seconds.rounded(.up))
    return s >= 3600
        ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
        : String(format: "%d:%02d", s / 60, s % 60)
}

/// Часы в строке меню: опоздание — сколько прошло от начала самой ранней опаздываемой встречи; иначе —
/// отсчёт до следующей, если до неё не больше 4 часов; иначе часов нет, только иконка.
struct Clock: Equatable {
    let text: String
    let isLate: Bool
    let isVIP: Bool
}

func clock(late: [Meeting], next: Meeting?, now: Date) -> Clock? {
    if let first = late.first {
        let elapsed = now.timeIntervalSince(first.start).rounded(.down)
        return Clock(text: countdownText(elapsed), isLate: true, isVIP: first.isVIP)
    }
    guard let next, next.start.timeIntervalSince(now) <= 4 * 3600 else { return nil }
    return Clock(text: countdownText(next.start.timeIntervalSince(now)), isLate: false, isVIP: next.isVIP)
}

/// Первая встреча дня, ради которой встают: не на весь день и не решённая.
func firstMeeting(_ meetings: [Meeting], state: State) -> Meeting? {
    meetings.filter { !$0.isAllDay && !isSettled($0, state) }.min { $0.start < $1.start }
}

/// Будильник в строке меню: время первой встречи рабочего дня — за `wakeUpHours` до неё, а за `wakeUpBlinkHours`
/// это время мигает.
/// `firsts` — первые встречи сегодня и завтра: после полуночи завтрашняя становится сегодняшней, а уже
/// начавшийся день уступает следующему.
struct WakeUp: Equatable {
    let start: Date
    let blinks: Bool
}

func wakeUp(_ firsts: [Meeting], now: Date, config: Config) -> WakeUp? {
    guard let first = firsts.first(where: { $0.start > now }), first.start.timeIntervalSince(now) <= config.wakeUpHours * 3600 else { return nil }
    return WakeUp(start: first.start, blinks: first.start.timeIntervalSince(now) <= config.wakeUpBlinkHours * 3600)
}

/// Вид карточки — первое подходящее сверху вниз; VIP-картон сочетается с любым видом.
enum Look { case ringing, skipped, ignored, past, late, current, normal }

func look(_ m: Meeting, now: Date, state: State, ringing: [Meeting], late: [Meeting]) -> Look {
    if ringing.contains(where: { $0.id == m.id }) { return .ringing }
    if state.decisions[m.eventId]?.kind == .skipped || state.decisions[m.eventId] == nil && m.isFree == true { return .skipped }
    if state.ignored[m.ignoreKey] != nil { return .ignored }
    switch phase(m, now: now) {
    case .past: return .past
    case .ongoing: return late.contains { $0.id == m.id } ? .late : .current
    case .ahead, .soon: return .normal
    }
}

/// Кнопка подключения — только у встреч, которые скоро начнутся или идут, при любом решении.
func showsJoin(_ m: Meeting, now: Date) -> Bool {
    guard m.joinURL != nil else { return false }
    let p = phase(m, now: now)
    return p == .soon || p == .ongoing
}
