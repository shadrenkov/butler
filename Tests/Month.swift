import Foundation
import Testing
@testable import Butler

// Календарь на месяц: сетка, точки VIP, оценка загрузки, производственный календарь. Сервер не участвует.

@Test func gridStartsOnMondayAndAlwaysHasSixWeeks() {
    let october = grid("2026-10")
    #expect(october.count == 6 && october.allSatisfy { $0.count == 7 })
    // 1 октября 2026 — четверг; края сетки — дни сентября и ноября.
    #expect(october[0] == ["2026-09-28", "2026-09-29", "2026-09-30", "2026-10-01", "2026-10-02", "2026-10-03", "2026-10-04"])
    #expect(october[4].last == "2026-11-01" && october[5].last == "2026-11-08")
    #expect(grid("2028-02").joined().filter { monthOf($0) == "2028-02" }.count == 29)
    // Февраль 2027 начинается в понедельник и умещается в четыре недели — сетка всё равно в шесть строк.
    #expect(grid("2027-02")[0][0] == "2027-02-01" && grid("2027-02")[5][6] == "2027-03-14")
}

@Test func monthsShiftAcrossTheYear() {
    #expect(shiftMonth("2026-12", by: 1) == "2027-01")
    #expect(shiftMonth("2026-01", by: -1) == "2025-12")
    #expect(monthsBetween("2026-10", "2027-01") == 3 && monthsBetween("2026-10", "2026-08") == -2)
    #expect(monthTitle("2026-10") == "Октябрь 2026")
}

@Test func dotsCountVIPMeetingsByRuleAndByHand() {
    let (start, _) = bounds("2026-11-10")!
    func meeting(_ id: String, _ hour: Double, organizer: String, uid: String? = nil) -> Event {
        Event(id: id, changeKey: "1", uid: uid, subject: id, start: start + hour * 3600, end: start + hour * 3600 + 1800,
              isAllDay: false, organizerName: organizer, organizerAddress: "\(id)@example.com", attendees: [],
              response: "Accept", isFree: false, isCancelled: false, joinURL: nil, description: nil)
    }
    let boxes = ["me@example.com": Box(events: [
        meeting("boss", 10, organizer: "Иванов Пётр Сергеевич"),
        meeting("unmarked", 11, organizer: "Иванов Пётр Сергеевич", uid: "series"),
        meeting("marked", 12, organizer: "Сидоров Иван"),
        meeting("plain", 13, organizer: "Сидоров Иван"),
    ])]
    var config = Config()
    config.vipOrganizers = ["Иванов Пётр"]
    let json = #"{"series": {"subject": "unmarked", "vip": false}, "marked": {"subject": "marked"}}"#
    config.vipMeetings = try! JSONDecoder().decode([String: Config.Hidden].self, from: Data(json.utf8))
    let day = assemble(boxes, order: ["me@example.com"], day: "2026-11-10", config: config)
    #expect(day.filter(\.isVIP).map(\.eventId) == ["boss", "marked"])
}

@Test func loadEstimateNeverGoesBackOrFinishesEarly() {
    let stats = LoadStats(find: 1.5, perItem: 0.05, month: 6)
    // Ни статистики, ни ответа FindItem — оценить нечем.
    #expect(estimate(elapsed: 1, reads: [MonthLoad.Read()], stats: LoadStats(), shown: 0) == nil)
    let early = estimate(elapsed: 1, reads: [MonthLoad.Read()], stats: stats, shown: 0)!
    let later = estimate(elapsed: 3, reads: [MonthLoad.Read()], stats: stats, shown: early)!
    #expect(later > early)
    #expect(estimate(elapsed: 100, reads: [MonthLoad.Read()], stats: stats, shown: 0)! == 0.95)
    // FindItem вернул много встреч — ожидание выросло, но полоска не откатывается ниже показанной.
    #expect(estimate(elapsed: 3, reads: [MonthLoad.Read(stale: 400)], stats: stats, shown: later)! == later)
}

@Test func workdaysComeFromTheProductionCalendarOrWeekends() {
    let year = String(repeating: "1", count: 11) + String(repeating: "0", count: 354)
    #expect(workdays(from: year + "\n", year: 2026) == year)
    #expect(workdays(from: String(year.dropLast()), year: 2026) == nil)
    #expect(workdays(from: String(year.dropLast()) + "x", year: 2026) == nil)
    let known = ["2026": Workdays(days: year, at: .now)]
    #expect(nonWorking("2026-01-01", workdays: known) && nonWorking("2026-01-11", workdays: known))
    // По календарю 2026 года нерабочих после 11 января нет — даже суббота рабочая.
    #expect(!nonWorking("2026-01-17", workdays: known))
    // Без календаря — суббота и воскресенье.
    #expect(nonWorking("2027-01-16", workdays: known) && !nonWorking("2027-01-18", workdays: known))
}
