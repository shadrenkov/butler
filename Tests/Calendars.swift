import Foundation
import Testing
@testable import Butler

// Календари Mac: склейка с Exchange и подпись источника, значок события дня. EventKit здесь не участвует —
// встречи Mac приходят в `assemble` уже теми же `Event`.

private func event(_ id: String, at start: Date, organizer: String = "ivanov@example.com", response: String = "NoResponseReceived",
                   source: String? = nil) -> Event {
    Event(id: id, changeKey: "", uid: nil, subject: "Встреча", start: start, end: start + 1800, isAllDay: false,
          organizerName: "Иванов Пётр", organizerAddress: organizer, attendees: [], response: response, isFree: false,
          isCancelled: false, joinURL: nil, description: nil, source: source)
}

@Test func exchangeCopyWinsOverMacCopy() {
    let at = bounds("2027-01-15")!.start + 10 * 3600
    let boxes = [
        "me@example.com": Box(events: [event("exchange", at: at)]),
        // Тот же ящик, подключённый к macOS: адрес организатора может прийти в другом регистре.
        "mac:X": Box(events: [event("mac", at: at, organizer: "Ivanov@Example.com", source: "Google · Работа")]),
    ]
    let day = assemble(boxes, order: ["me@example.com", "mac:X"], day: "2027-01-15", config: Config())
    #expect(day.map(\.eventId) == ["exchange"])
    #expect(day[0].source == "Exchange · me@example.com")
}

@Test func macMeetingKeepsItsSourceAndOwnNoteIsMine() {
    let at = bounds("2027-01-15")!.start + 10 * 3600
    let boxes = ["mac:X": Box(events: [event("note", at: at, organizer: "", response: "Organizer", source: "iCloud · Семья")])]
    let day = assemble(boxes, order: ["mac:X"], day: "2027-01-15", config: Config())
    #expect(day.map(\.source) == ["iCloud · Семья"])
    #expect(day[0].isOrganizer == true && day[0].isAccepted == true)
}

@Test func allDaySymbolByCalendarKind() {
    #expect(symbol(type: .birthday, title: "Дни рождения") == "gift")
    #expect(symbol(type: .subscription, title: "Праздники России") == "flag")
    #expect(symbol(type: .calDAV, title: "Holidays in Russia") == "flag")
    #expect(symbol(type: .calDAV, title: "Работа") == nil)
}
