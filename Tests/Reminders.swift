import Foundation
import Testing
@testable import Butler

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func meeting(_ id: String, at start: Date = t0, minutes: Double = 30, series: String? = nil,
                     allDay: Bool = false, vip: Bool = false, link: Bool = false, free: Bool? = nil) -> Meeting {
    Meeting(eventId: id, seriesId: series, subject: id, start: start, end: start + minutes * 60, isAllDay: allDay,
            organizerName: "", isVIP: vip, isAccepted: nil, joinURL: link ? URL(string: "https://my.mts-link.ru/j/1") : nil,
            attendees: nil, description: nil, isOrganizer: nil, isFree: free)
}

private func config(offset: Double = 0, vip: Double = 60) -> Config {
    var c = Config()
    c.reminderOffsetSeconds = offset
    c.vipReminderOffsetSeconds = vip
    return c
}

private func state(skipped: [String] = [], joined: [String] = [], ignored: [String] = []) -> State {
    var s = State()
    s.ignored = Dictionary(uniqueKeysWithValues: ignored.map { ($0, $0) })
    for id in skipped { s.decisions[id] = State.Decision(kind: .skipped, day: "2027-01-15") }
    for id in joined { s.decisions[id] = State.Decision(kind: .joined, day: "2027-01-15") }
    return s
}

private func ids(_ r: Reminders, _ ms: [Meeting], at now: Date, state s: State = State(), config c: Config = config()) -> [String] {
    r.reminding(ms, now: now, state: s, config: c).map(\.eventId)
}

@Test func remindsFromStartMinusOffset() {
    let m = [meeting("a")]
    #expect(ids(Reminders(), m, at: t0 - 1).isEmpty)
    #expect(ids(Reminders(), m, at: t0) == ["a"])
    #expect(ids(Reminders(), m, at: t0 - 20, config: config(offset: 20)) == ["a"])
    #expect(ids(Reminders(), m, at: t0 - 21, config: config(offset: 20)).isEmpty)
}

@Test func unansweredReminderExpiresTenMinutesAfterStart() {
    let m = [meeting("a", minutes: 60)]
    #expect(ids(Reminders(), m, at: t0 + 599) == ["a"])
    #expect(ids(Reminders(), m, at: t0 + 600).isEmpty)
    #expect(Reminders().late(m, now: t0 + 600, state: State()).isEmpty)
}

@Test func autoSnoozeKeepsTheLimitButUserSnoozeLiftsIt() {
    let m = [meeting("a", minutes: 60)]
    var auto = Reminders()
    auto.snooze(m, minutes: 5, now: t0 + 400, byUser: false)
    #expect(ids(auto, m, at: t0 + 700).isEmpty)

    var user = Reminders()
    user.snooze(m, minutes: 5, now: t0 + 400, byUser: true)
    #expect(ids(user, m, at: t0 + 699).isEmpty)
    #expect(ids(user, m, at: t0 + 700) == ["a"])
    #expect(user.late(m, now: t0 + 1800, state: State()).map(\.eventId) == ["a"])
    #expect(ids(user, m, at: t0 + 3600).isEmpty)
}

@Test func decisionsAndIgnoreSilenceTheReminder() {
    let ms = [meeting("a"), meeting("b"), meeting("c", series: "s")]
    let s = state(skipped: ["a"], joined: ["b"], ignored: ["s"])
    #expect(ids(Reminders(), ms, at: t0, state: s).isEmpty)
    #expect(Reminders().late(ms, now: t0 + 60, state: s).isEmpty)
    #expect(countdownTarget(ms, now: t0 - 60, state: s) == nil)
}

@Test func allDayIsNeverRemindedNorCounted() {
    let m = [meeting("a", allDay: true)]
    #expect(ids(Reminders(), m, at: t0).isEmpty)
    #expect(countdownTarget(m, now: t0 - 60, state: State()) == nil)
}

@Test func lateOnlyAfterStart() {
    let m = [meeting("a")]
    #expect(Reminders().late(m, now: t0 - 1, state: State()).isEmpty)
    #expect(Reminders().late(m, now: t0 + 1, state: State()).map(\.eventId) == ["a"])
}

@Test func clockShowsLatenessFromEarliestElseCountdown() {
    let early = meeting("early", vip: true)
    let later = meeting("later", at: t0 + 60)
    #expect(clock(late: [early, later], next: nil, now: t0 + 135) == Clock(text: "2:15", isLate: true, isVIP: true))
    #expect(clock(late: [], next: later, now: t0 - 705) == Clock(text: "12:45", isLate: false, isVIP: false))
    #expect(clock(late: [], next: nil, now: t0) == nil)
    // Дальше 4 часов отсчёт не нужен — только иконка.
    #expect(clock(late: [], next: later, now: t0 + 60 - 4 * 3600) == Clock(text: "4:00:00", isLate: false, isVIP: false))
    #expect(clock(late: [], next: later, now: t0 + 59 - 4 * 3600) == nil)
}

@Test func countdownFormat() {
    #expect(countdownText(765) == "12:45")
    #expect(countdownText(764.2) == "12:45")
    #expect(countdownText(4800) == "1:20:00")
    #expect(countdownText(59) == "0:59")
}

@Test func lookPicksFirstMatchingView() {
    let s = state(skipped: ["skippedPast"])
    #expect(look(meeting("skippedPast", at: t0 - 7200), now: t0, state: s, ringing: [], late: []) == .skipped)
    #expect(look(meeting("past", at: t0 - 7200), now: t0, state: s, ringing: [], late: []) == .past)

    let ongoing = meeting("ongoing", at: t0 - 60)
    #expect(look(ongoing, now: t0, state: State(), ringing: [ongoing], late: [ongoing]) == .ringing)
    #expect(look(ongoing, now: t0, state: State(), ringing: [], late: [ongoing]) == .late)
    #expect(look(ongoing, now: t0, state: State(), ringing: [], late: []) == .current)
}

@Test func joinButtonTenMinutesAheadAndWhileOngoing() {
    let m = meeting("a", link: true)
    #expect(!showsJoin(m, now: t0 - 660))
    #expect(showsJoin(m, now: t0 - 540))
    #expect(showsJoin(m, now: t0 + 60))
    #expect(!showsJoin(m, now: t0 + 1800))
    #expect(!showsJoin(meeting("noLink"), now: t0))
}

@Test func movedMeetingRemindsAgain() {
    var r = Reminders()
    r.snooze([meeting("a")], minutes: 60, now: t0, byUser: true)
    #expect(ids(r, [meeting("a", at: t0 + 600)], at: t0 + 600) == ["a"])
}

@Test func vipIsRemindedEarlierButNeverLater() {
    #expect(remindAt(meeting("v", vip: true), config: config()) == t0 - 60)
    #expect(remindAt(meeting("v", vip: true), config: config(offset: 90, vip: 60)) == t0 - 90)
    #expect(remindAt(meeting("n"), config: config(offset: 20)) == t0 - 20)
}

@Test func freeInOutlookIsSkipped() {
    let m = meeting("free", free: true)
    #expect(Reminders().reminding([m], now: t0, state: State(), config: Config()).isEmpty)
    #expect(look(m, now: t0 - 3600, state: State(), ringing: [], late: []) == .skipped)
}

@Test func okStopsRingingAndLateness() {
    let m = meeting("ok")
    var r = Reminders()
    r.snooze([m], minutes: 5, now: t0, byUser: true)
    #expect(r.late([m], now: t0 + 60, state: State()).count == 1)
    r.acknowledge([m])
    #expect(r.reminding([m], now: t0 + 400, state: State(), config: Config()).isEmpty)
    #expect(r.late([m], now: t0 + 60, state: State()).isEmpty)
}

// Свежесть дня за окном кэша: молчащее предупреждение — пропущенная встреча.

@Test func freshDataWithoutErrorIsNotStale() {
    #expect(staleness(fetchedAt: t0, error: nil, now: t0 + 900) == nil)
    #expect(staleness(fetchedAt: nil, error: "нет сети", now: t0) == nil)
}

@Test func errorWarnsAtOnceFromLastGoodData() {
    let s = staleness(fetchedAt: t0, error: "нет сети или VPN", now: t0 + 60)
    #expect(s?.since == t0)
    #expect(s?.reason == "нет сети или VPN")
}

@Test func staleAfterFifteenMinutes() {
    #expect(staleness(fetchedAt: t0, error: nil, now: t0 + 901)?.reason == "давно нет обновлений")
}

@Test func wakeUpShowsFirstMeetingAheadAndBlinksLaterByConfig() {
    let today = meeting("today", at: t0)
    let tomorrow = meeting("tomorrow", at: t0 + 86_400)
    var c = Config()
    #expect(wakeUp([today, tomorrow], now: t0 - 12 * 3600 - 1, config: c) == nil)
    #expect(wakeUp([today, tomorrow], now: t0 - 12 * 3600, config: c) == WakeUp(start: t0, blinks: false))
    #expect(wakeUp([today, tomorrow], now: t0 - 9 * 3600, config: c) == WakeUp(start: t0, blinks: true))
    // Первая встреча сегодня уже началась — будильник ставится на завтра.
    #expect(wakeUp([today, tomorrow], now: t0 + 86_400 - 9 * 3600, config: c)?.start == t0 + 86_400)
    #expect(wakeUp([today], now: t0, config: c) == nil)
    (c.wakeUpHours, c.wakeUpBlinkHours) = (8, 6.5)
    #expect(wakeUp([today], now: t0 - 8 * 3600 - 1, config: c) == nil)
    #expect(wakeUp([today], now: t0 - 7 * 3600, config: c) == WakeUp(start: t0, blinks: false))
    #expect(wakeUp([today], now: t0 - 6.5 * 3600, config: c) == WakeUp(start: t0, blinks: true))
}

@Test func firstMeetingSkipsAllDayAndSettled() {
    let s = state(skipped: ["early"])
    let ms = [meeting("late", at: t0 + 3600), meeting("early", at: t0), meeting("day", at: t0 - 3600, allDay: true)]
    #expect(firstMeeting(ms, state: s)?.eventId == "late")
}
