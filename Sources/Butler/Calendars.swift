import EventKit
import SwiftUI

/// Календари Mac — только чтение через EventKit: повторы, часовые пояса и синхронизацию с Google и iCloud
/// делает система. Встречи кладутся в те же `Box`, что у ящиков Exchange, под ключом `mac:<calendarIdentifier>`,
/// и собираются тем же `assemble`.
@MainActor let store = EKEventStore()

/// Встречи Mac есть, только когда доступ дан полностью.
var hasCalendarAccess: Bool {
    EKEventStore.authorizationStatus(for: .event) == .fullAccess && !offlineMode
}

@MainActor func macCalendars() -> [EKCalendar] {
    hasCalendarAccess ? store.calendars(for: .event) : []
}

func key(_ c: EKCalendar) -> String {
    "mac:" + c.calendarIdentifier
}

/// Значок события на весь день: картинки у календаря в EventKit нет — только вид и название.
func symbol(_ c: EKCalendar) -> String? {
    symbol(type: c.type, title: c.title)
}

func symbol(type: EKCalendarType, title: String) -> String? {
    if type == .birthday { return "gift" }
    return title.localizedCaseInsensitiveContains("праздн") || title.localizedCaseInsensitiveContains("holiday") ? "flag" : nil
}

/// Встреча EventKit — как встреча ящика. Отклонённая не попадает никуда. Экземпляр серии — по исходной дате:
/// перенос его не меняет, поэтому «пропустить эту» ложится на один экземпляр.
func event(_ e: EKEvent) -> Event? {
    let me = e.attendees?.first { $0.isCurrentUser }
    if me?.participantStatus == .declined { return nil }
    let external = e.calendarItemExternalIdentifier ?? e.eventIdentifier ?? ""
    let series = e.hasRecurrenceRules ? external : nil
    let id = series.flatMap { s in e.occurrenceDate.map { s + "|" + $0.ISO8601Format() } } ?? external
    let attendees = e.attendees ?? []
    let response = e.organizer?.isCurrentUser == true || attendees.isEmpty ? "Organizer"
        : me?.participantStatus == .accepted ? "Accept"
        : me?.participantStatus == .tentative ? "Tentative" : "NoResponseReceived"
    let notes = e.notes?.trimmingCharacters(in: .whitespacesAndNewlines)
    return Event(id: id, changeKey: "", uid: series, subject: e.title ?? "", start: e.startDate, end: e.endDate,
                 isAllDay: e.isAllDay, organizerName: e.organizer?.name ?? "", organizerAddress: e.organizer.map(address) ?? "",
                 attendees: attendees.filter { !$0.isCurrentUser }.map { Person(name: $0.name ?? "", address: address($0)) },
                 response: response, isFree: e.availability == .free, isCancelled: e.status == .canceled,
                 joinURL: joinURL(location: e.location ?? "", html: [e.notes, e.url?.absoluteString].compactMap { $0 }.joined(separator: "\n")),
                 description: notes?.isEmpty == false ? notes : nil,
                 source: "\(e.calendar.source?.title ?? "") · \(e.calendar.title)", symbol: symbol(e.calendar))
}

/// Адрес участника — из ссылки `mailto:`; другой ссылки адресом не считаем.
private func address(_ p: EKParticipant) -> String {
    let link = p.url.absoluteString
    guard link.lowercased().hasPrefix("mailto:") else { return "" }
    return String(link.dropFirst(7)).removingPercentEncoding ?? ""
}

/// Встречи дня из включённых календарей — одним запросом, по боксам календарей. Без доступа или без
/// включённых календарей EventKit не трогается.
@MainActor func macBoxes(_ day: String, keys: [String]) -> [String: Box] {
    guard !keys.isEmpty, hasCalendarAccess, let (start, end) = bounds(day) else { return [:] }
    let calendars = macCalendars().filter { keys.contains(key($0)) }
    guard !calendars.isEmpty else { return [:] }
    var boxes: [String: Box] = [:]
    for e in store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: calendars)) {
        if let event = event(e) { boxes[key(e.calendar), default: Box()].events.append(event) }
    }
    return boxes
}
