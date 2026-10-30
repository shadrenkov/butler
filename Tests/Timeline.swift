import Foundation
import Testing
@testable import Butler

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func meeting(_ id: String, from start: Double, minutes: Double, allDay: Bool = false) -> Meeting {
    Meeting(eventId: id, seriesId: nil, subject: id, start: t0 + start * 60, end: t0 + (start + minutes) * 60,
            isAllDay: allDay, organizerName: "", isVIP: false, isAccepted: nil, joinURL: nil,
            attendees: nil, description: nil, isOrganizer: nil, isFree: nil)
}

private func lanes(_ ms: [Meeting]) -> [String: String] {
    Dictionary(uniqueKeysWithValues: layout(ms)!.placed.map { ($0.meeting.eventId, "\($0.lane)/\($0.lanes)") })
}

@Test func simultaneousMeetingsSitSideBySide() {
    #expect(lanes([meeting("a", from: 0, minutes: 30), meeting("b", from: 0, minutes: 60)]) == ["a": "0/2", "b": "1/2"])
}

@Test func partialOverlapSharesTheGroup() {
    let result = lanes([meeting("a", from: 0, minutes: 60), meeting("b", from: 30, minutes: 60), meeting("c", from: 90, minutes: 30)])
    #expect(result == ["a": "0/2", "b": "1/2", "c": "0/1"])
}

@Test func backToBackMeetingsShareOneLane() {
    let result = lanes([meeting("a", from: 0, minutes: 30), meeting("b", from: 30, minutes: 30), meeting("c", from: 60, minutes: 30)])
    #expect(result == ["a": "0/1", "b": "0/1", "c": "0/1"])
}

@Test func freeTimeFromFifteenMinutes() {
    let day = layout([meeting("a", from: 0, minutes: 30), meeting("b", from: 60, minutes: 30), meeting("c", from: 100, minutes: 20)])!
    #expect(day.gaps.map { ($0.start, $0.end) }.elementsEqual([(t0 + 30 * 60, t0 + 60 * 60)], by: ==))
    #expect(day.start == t0 - 15 * 60)
    #expect(day.end == t0 + 135 * 60)
}

@Test func gapIsMeasuredFromTheLatestEndInTheGroup() {
    let day = layout([meeting("long", from: 0, minutes: 120), meeting("inner", from: 30, minutes: 30), meeting("after", from: 150, minutes: 30)])!
    #expect(day.gaps.count == 1)
    #expect(day.gaps.first?.start == t0 + 120 * 60)
}

@Test func dayWithoutTimedMeetingsHasNoScale() {
    #expect(layout([meeting("holiday", from: 0, minutes: 1440, allDay: true)]) == nil)
    #expect(layout([]) == nil)
}

@Test func everyMeetingGetsRoomForItsLinesAndNeverOverlaps() {
    let ms = [meeting("long", from: 0, minutes: 120), meeting("short", from: 120, minutes: 10),
              meeting("half", from: 130, minutes: 30), meeting("after", from: 200, minutes: 30)]
    let day = layout(ms)!
    let r = ruler(day, available: 500)
    #expect(r.y(t0 + 130 * 60) - r.y(t0 + 120 * 60) >= neededHeight(ms[1], lines: 3) - 0.001)
    #expect(r.y(t0 + 160 * 60) - r.y(t0 + 130 * 60) >= neededHeight(ms[2], lines: 3) - 0.001)
    #expect(r.y(t0 + 200 * 60) - r.y(t0 + 160 * 60) >= 24)
    #expect(r.height <= 501)
    let ys = r.stops.map(\.y)
    #expect(zip(ys, ys.dropFirst()).allSatisfy { $0 < $1 })
}

@Test func crowdedDayStillFitsWithFewerLines() {
    let ms = (0..<16).map { meeting("m\($0)", from: Double($0) * 30, minutes: 30) }
    let r = ruler(layout(ms)!, available: 700)
    #expect(r.height <= 701)
    #expect(r.y(t0 + 30 * 60) - r.y(t0) >= neededHeight(ms[0], lines: 2))

    let packed = (0..<24).map { meeting("p\($0)", from: Double($0) * 30, minutes: 30) }
    let one = ruler(layout(packed)!, available: 700)
    #expect(one.height <= 701)
    #expect(one.y(t0 + 30 * 60) - one.y(t0) >= neededHeight(packed[0], lines: 1))
}
