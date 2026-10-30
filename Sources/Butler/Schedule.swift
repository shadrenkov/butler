import AppKit

/// Встреча, как её видит Butler: собрана из копий во всех ящиках (`assemble`).
struct Meeting: Codable, Identifiable, Equatable {
    let eventId: String
    let seriesId: String?
    let subject: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let organizerName: String
    var isVIP: Bool
    /// Пользователь организатор или принял приглашение; нет поля — не принята.
    let isAccepted: Bool?
    let joinURL: URL?
    /// Участники без владельца и организатора.
    let attendees: [String]?
    let description: String?
    let isOrganizer: Bool?
    /// В Outlook помечена «Показывать как: Свободен» — считается пропущенной.
    let isFree: Bool?

    var isRecurring: Bool { seriesId != nil }

    var id: String { reminderKey }
    /// Игнорируется вся серия, а у одиночной встречи — она сама.
    var ignoreKey: String { seriesId ?? eventId }
    /// Перенос даёт новый ключ — и напоминание о встрече сработает снова.
    var reminderKey: String { "\(eventId)|\(start.timeIntervalSince1970)" }

    enum CodingKeys: String, CodingKey {
        case eventId = "event_id", seriesId = "series_id", subject, start, end
        case isAllDay = "is_all_day", organizerName = "organizer_name", isVIP = "is_vip", isAccepted = "is_accepted"
        case joinURL = "join_url", attendees, description, isOrganizer = "is_organizer", isFree = "is_free"
    }
}

/// День расписания.
struct Day: Codable {
    let date: String
    let events: [Meeting]

    enum CodingKeys: String, CodingKey {
        case date, events
    }
}

/// День за окном кэша неактуален, если его чтение кончилось ошибкой или данным больше 15 минут: он
/// перечитывается раз в 10 минут, пока показан. Данных нет вовсе — `nil`: это не устаревшее расписание, а
/// неполученное.
func staleness(fetchedAt: Date?, error: String?, now: Date) -> (since: Date, reason: String)? {
    guard let fetchedAt else { return nil }
    if let error { return (fetchedAt, error) }
    return now.timeIntervalSince(fetchedAt) > 900 ? (fetchedAt, "давно нет обновлений") : nil
}

/// Ссылка для подключения — её открывают на моём Mac, а «Место» и текст приглашения пишет кто угодно.
/// Поэтому только `https`, хост МТС Линк сравнивается как хост, а не как подстрока. Ссылка МТС Линк из
/// «Места», потом из текста; нет её нигде — первая ссылка из «Места», но не из текста: там подписи и логотипы.
func joinURL(location: String, html: String) -> URL? {
    let inLocation = links(location)
    let meeting = { (link: String) in URL(string: link).map(MTSLink.isLink) == true }
    return (inLocation.first(where: meeting) ?? links(html).first(where: meeting) ?? inLocation.first).flatMap(URL.init(string:))
}

private func links(_ text: String) -> [String] {
    let unescaped = text.replacingOccurrences(of: "&amp;", with: "&")
    return unescaped.matches(of: /https:\/\/[^\s<>"'()\[\]]+/).map { String(unescaped[$0.range]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?»…")) }
}

/// Строки, с которых начинается блок, который МТС Линк дописывает под приглашением, — всё ниже не слова
/// организатора.
private let linkBlockOpeners = ["meeting id", "mts link meeting link", "sip link", "идентификатор мероприятия",
                                "идентификатор встречи", "ссылка на встречу", "ссылка для подключения", "подключение по sip",
                                "подключение по телефону", "для подключения к конференции"]

/// Что написал организатор: текст до блока МТС Линк, без строк из одной ссылки, не длиннее 4000 знаков.
/// Текстовое тело Exchange оставляет следы HTML — картинки `[cid:…]`, адрес ссылки в угловых скобках
/// после её текста, черту из подчёркиваний, отбивку пробелами — они убираются.
func invitationText(_ text: String) -> String? {
    var kept: [String] = []
    for raw in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
        let line = raw.replacing(/\[cid:[^\]]*\]/, with: "")
            .replacing(/<(mailto:|https?:\/\/)[^>]*>/, with: "")
            .replacing(/[ \t]{2,}/, with: " ")
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.wholeMatch(of: /_{5,}/) != nil { continue }
        if linkBlockOpeners.contains(where: trimmed.lowercased().hasPrefix) { break }
        if trimmed.wholeMatch(of: /https?:\/\/\S+/.ignoresCase()) != nil { continue }
        // Пустые строки подряд — одна.
        if trimmed.isEmpty && kept.last?.isEmpty != false { continue }
        kept.append(trimmed.isEmpty ? "" : line)
    }
    let result = String(kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines).prefix(4000))
    return result.isEmpty ? nil : result
}

struct Problem: LocalizedError {
    let errorDescription: String?
    init(_ text: String) { errorDescription = text }
}

/// Дата в формате контракта: `YYYY-MM-DD` по местному времени.
func dayString(_ date: Date) -> String {
    Date.ISO8601FormatStyle(timeZone: .current).year().month().day().format(date)
}

/// Часы Butler: настоящие, а с `--now 2026-10-23T13:28` — сдвинутые, чтобы прожить другой день заранее.
nonisolated(unsafe) var clockShift: TimeInterval = 0

func currentTime() -> Date {
    .now + clockShift
}

func today() -> String {
    dayString(currentTime())
}

/// Местные сутки дня `YYYY-MM-DD`: от полуночи до следующей полуночи — день перевода часов тоже целый.
func bounds(_ day: String) -> (start: Date, end: Date)? {
    let parser = DateFormatter()
    parser.dateFormat = "yyyy-MM-dd"
    guard let start = parser.date(from: day).map(Calendar.current.startOfDay),
          let end = Calendar.current.date(byAdding: .day, value: 1, to: start) else { return nil }
    return (start, end)
}

/// День для шкалы из кэшей всех ящиков: встречи, задевающие
/// сутки, без отменённых; одна встреча из нескольких ящиков — одна карточка из ящика выше по списку, но
/// принята она, если принята в любом, и своя, если своя в любом.
func assemble(_ boxes: [String: Box], order: [String], day: String, config: Config) -> [Meeting] {
    guard let (from, to) = bounds(day) else { return [] }
    struct Key: Hashable { let start: Date, end: Date, isAllDay: Bool, subject: String, organizer: String }
    var kept: [Key: Event] = [:]
    var accepted: Set<Key> = []
    var organized: Set<Key> = []
    for address in order {
        for e in boxes[address]?.events ?? [] where e.start < to && e.end > from && !e.isCancelled {
            let key = Key(start: e.start, end: e.end, isAllDay: e.isAllDay, subject: e.subject, organizer: e.organizerAddress)
            if kept[key] == nil { kept[key] = e }
            if e.response == "Organizer" || e.response == "Accept" { accepted.insert(key) }
            if e.response == "Organizer" { organized.insert(key) }
        }
    }
    let own = Set(order.map { $0.lowercased() })
    let meetings = kept.map { key, e in
        Meeting(eventId: e.id, seriesId: e.uid, subject: e.subject, start: e.start, end: e.end, isAllDay: e.isAllDay,
                organizerName: e.organizerName, isVIP: false, isAccepted: accepted.contains(key), joinURL: e.joinURL,
                attendees: e.attendees.filter {
                    let address = $0.address.lowercased()
                    return !own.contains(address) && address != e.organizerAddress.lowercased()
                }.map { $0.name.isEmpty ? $0.address : $0.name },
                description: e.description, isOrganizer: organized.contains(key), isFree: e.isFree)
    }
    return marked(meetings.sorted { ($0.start, $0.eventId) < ($1.start, $1.eventId) }, config)
}

/// Человек VIP, если в его имени есть запись списка: «Иванов Пётр» находит «Иванов Пётр Сергеевич».
func isVIPOrganizer(_ name: String, _ config: Config) -> Bool {
    config.vipOrganizers.contains { name.localizedCaseInsensitiveContains($0) }
}

/// VIP по правилу: кто-то из списка VIP организует встречу или участвует в ней.
func isVIPByRule(_ m: Meeting, _ config: Config) -> Bool {
    isVIPOrganizer(m.organizerName, config) || (m.attendees ?? []).contains { isVIPOrganizer($0, config) }
}

/// Правило даёт начальную разметку, ручная отметка серии (встречи) с карточки — главнее: можно и сделать VIP,
/// и снять VIP, который дало правило. Считается в Butler, без обращения к серверу.
func marked(_ meetings: [Meeting], _ config: Config) -> [Meeting] {
    meetings.map { m in
        var m = m
        m.isVIP = config.vipMeetings[m.ignoreKey].map { $0.vip ?? true } ?? isVIPByRule(m, config)
        return m
    }
}

let pollInterval: TimeInterval = 60

/// Проверять, не пора ли обновить ящики, сразу, раз в минуту, после выхода из сна (`true`) и в полночь;
/// пора ли на самом деле, решает `isDue`.
@MainActor
func startPolling(_ refresh: @escaping @MainActor @Sendable (Bool) -> Void) {
    refresh(false)
    let timer = Timer(timeInterval: pollInterval, repeats: true) { _ in MainActor.assumeIsolated { refresh(false) } }
    RunLoop.main.add(timer, forMode: .common)
    NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
        MainActor.assumeIsolated { refresh(true) }
    }
    NotificationCenter.default.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { _ in
        MainActor.assumeIsolated { refresh(false) }
    }
}
