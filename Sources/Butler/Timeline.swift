import SwiftUI

/// Встреча на шкале: её дорожка и сколько дорожек в группе пересекающихся с ней встреч.
struct Placed {
    let meeting: Meeting
    let lane: Int
    let lanes: Int
}

/// Свободный промежуток между встречами — от 15 минут.
struct Gap {
    let start: Date
    let end: Date
}

/// Раскладка дня: рабочий день — от первой до последней встречи со временем (с полями по 15 минут),
/// пересекающиеся встречи — по дорожкам рядом, свободные промежутки — между ними.
func layout(_ meetings: [Meeting]) -> (start: Date, end: Date, placed: [Placed], gaps: [Gap])? {
    let timed = meetings.filter { !$0.isAllDay }.sorted { ($0.start, $0.end) < ($1.start, $1.end) }
    guard let first = timed.first else { return nil }
    var placed: [Placed] = []
    var gaps: [Gap] = []
    var group: [(meeting: Meeting, lane: Int)] = []
    var laneEnds: [Date] = []
    var groupEnd = first.start

    func closeGroup() {
        placed += group.map { Placed(meeting: $0.meeting, lane: $0.lane, lanes: laneEnds.count) }
        group = []
        laneEnds = []
    }

    for m in timed {
        if !group.isEmpty && m.start >= groupEnd {
            if m.start.timeIntervalSince(groupEnd) >= 15 * 60 { gaps.append(Gap(start: groupEnd, end: m.start)) }
            closeGroup()
        }
        if let lane = laneEnds.firstIndex(where: { $0 <= m.start }) {
            laneEnds[lane] = m.end
            group.append((m, lane))
        } else {
            laneEnds.append(m.end)
            group.append((m, laneEnds.count - 1))
        }
        groupEnd = max(groupEnd, m.end)
    }
    closeGroup()
    return (first.start - 15 * 60, groupEnd + 15 * 60, placed, gaps)
}

/// Строка текста в окне, зазор между карточками рядом и отступ карточки от линии часа сверху и снизу.
let rowHeight: CGFloat = 13
let cardGap: CGFloat = 4
let cardMargin: CGFloat = 1

/// Сколько места нужно встрече на шкале: от 30 минут — три строки (время, название, организатор),
/// короче — две; плюс отступы карточки и зазор до соседней.
func neededHeight(_ m: Meeting, lines: Int) -> CGFloat {
    let rows = m.end.timeIntervalSince(m.start) >= 30 * 60 ? lines : min(lines, 2)
    return CGFloat(rows) * rowHeight + 6 + 1 + 2 * cardMargin
}

/// Время → высота на шкале. Внутри встречи — пропорционально, но каждая встреча получает не меньше
/// места, чем нужно её строкам, свободный промежуток — под подпись, края дня — под отметки начала
/// и конца. Поэтому карточки и подписи никогда не наезжают друг на друга.
struct Ruler {
    let stops: [(time: Date, y: CGFloat)]

    var height: CGFloat { stops.last?.y ?? 0 }

    func y(_ time: Date) -> CGFloat {
        guard let i = stops.firstIndex(where: { $0.time >= time }) else { return height }
        guard i > 0 else { return stops[0].y }
        let (a, b) = (stops[i - 1], stops[i])
        return a.y + (b.y - a.y) * CGFloat(time.timeIntervalSince(a.time) / b.time.timeIntervalSince(a.time))
    }
}

func ruler(_ day: (start: Date, end: Date, placed: [Placed], gaps: [Gap]), available: CGFloat) -> Ruler {
    let meetings = day.placed.map(\.meeting)
    let times = Set([day.start, day.end] + meetings.flatMap { [$0.start, $0.end] }).sorted()

    func build(k: CGFloat, lines: Int) -> Ruler {
        var y: CGFloat = 0
        var stops = [(time: times[0], y: y)]
        for (a, b) in zip(times, times.dropFirst()) {
            let length = b.timeIntervalSince(a)
            var need = CGFloat(length / 60) * k
            for m in meetings where m.start <= a && b <= m.end {
                need = max(need, neededHeight(m, lines: lines) * CGFloat(length / m.end.timeIntervalSince(m.start)))
            }
            if day.gaps.contains(where: { $0.start <= a && b <= $0.end }) { need = max(need, 24) }
            if a == day.start || b == day.end { need = max(need, 20) }
            y += need
            stops.append((b, y))
        }
        return Ruler(stops: stops)
    }

    // Масштаб подбирается так, чтобы день занял доступную высоту. Не влезает и при сжатии — встречи
    // теряют строку организатора, а в совсем плотный день остаются одной строкой «время · название».
    var k = min(2.4, available / CGFloat(day.end.timeIntervalSince(day.start) / 60))
    var result = build(k: k, lines: 3)
    for lines in [3, 2, 1] {
        result = build(k: k, lines: lines)
        for _ in 0..<8 where result.height > available {
            k *= available / result.height
            result = build(k: k, lines: lines)
        }
        if result.height <= available + 1 { return result }
    }
    return result
}

/// `04:00` во втором, домашнем часовом поясе.
func homeTime(_ date: Date, config: Config) -> String {
    date.formatted(Date.VerbatimFormatStyle(
        format: "\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)",
        timeZone: TimeZone(identifier: config.homeTimeZone) ?? .current, calendar: .current))
}

/// « · GMT-3 04:00» или « · GMT-3 04:00–07:00» — время во втором, домашнем часовом поясе, голубым.
/// Второй пояс выключен в настройках — пусто.
func homeLabel(_ start: Date, to end: Date? = nil, config: Config) -> Text {
    guard config.showHomeTime else { return Text("") }
    let zone = TimeZone(identifier: config.homeTimeZone)?.abbreviation() ?? ""
    let times = [start, end].compactMap { $0 }.map { homeTime($0, config: config) }
    return Text(" · ").foregroundStyle(Ink.secondary) + Text(zone + " " + times.joined(separator: "–")).foregroundStyle(Ink.home)
}

/// Ширина окна: до трёх дорожек — 400, 4-я и 5-я добавляют по 120; дальше карточки однострочные.
func windowWidth(lanes: Int) -> CGFloat {
    400 + CGFloat(max(0, min(lanes, 5) - 3)) * 120
}

/// «45 мин», «1 ч», «1 ч 15 мин».
func durationText(_ seconds: TimeInterval) -> String {
    let minutes = Int(seconds / 60)
    let (h, m) = (minutes / 60, minutes % 60)
    return h == 0 ? "\(m) мин" : m == 0 ? "\(h) ч" : "\(h) ч \(m) мин"
}

/// Шкала дня: часы, карточки по дорожкам, «свободно» и время второго пояса в строку.
struct Scale: View {
    let app: App
    let meetings: [Meeting]
    let isToday: Bool
    let available: CGFloat

    private let gutter: CGFloat = 42

    var body: some View {
        if let day = layout(meetings) {
            let ruler = ruler(day, available: available)
            let lanes = day.placed.map(\.lanes).max() ?? 1
            let width = windowWidth(lanes: lanes) - 24
            let first = day.start + 15 * 60, last = day.end - 15 * 60
            let showsNow = isToday && app.now > day.start && app.now < day.end
            ZStack(alignment: .topLeading) {
                // Получасовой пунктир бледнее часового и без подписи: от чуть левее плашек до чуть правее них.
                ForEach(hours(from: day.start - 1800, to: day.end - 1800).map { $0 + 1800 }, id: \.self) { half in
                    Path { $0.move(to: CGPoint(x: gutter - 6, y: 0.5)); $0.addLine(to: CGPoint(x: width + 6, y: 0.5)) }
                        .stroke(ink(0xC9BDAB), style: StrokeStyle(lineWidth: 1.2, lineCap: .round, dash: [0, 3]))
                        .frame(width: width, height: 1)
                        .offset(y: ruler.y(half))
                }
                ForEach(hours(from: day.start, to: day.end), id: \.self) { hour in
                    // Пунктир часа — от левого края, время — сразу под ним. Точки темнее сплошной линии, иначе пропадают.
                    Path { $0.move(to: CGPoint(x: 0, y: 0.5)); $0.addLine(to: CGPoint(x: width, y: 0.5)) }
                        .stroke(ink(0xBDB09E), style: StrokeStyle(lineWidth: 1.2, lineCap: .round, dash: [0, 3]))
                        .frame(width: width, height: 1)
                        .offset(y: ruler.y(hour))
                    // Метка текущего времени налезла на подпись часа — остаётся только она.
                    let label = ruler.y(hour) + 2, now = ruler.y(app.now)
                    if !showsNow || now + rowHeight / 2 <= label || now - rowHeight / 2 >= label + rowHeight {
                        Text(hhmm(hour)).font(Ink.body).monospacedDigit().foregroundStyle(Ink.tertiary)
                            .offset(y: ruler.y(hour) + 2)
                    }
                }
                edge(first).offset(x: gutter, y: ruler.y(first) - rowHeight - 3)
                edge(last).offset(x: gutter, y: ruler.y(last) + 3)
                ForEach(day.gaps, id: \.start) { gap in
                    free(gap)
                        .frame(width: width - gutter, height: ruler.y(gap.end) - ruler.y(gap.start))
                        .offset(x: gutter, y: ruler.y(gap.start))
                }
                if showsNow {
                    // Текущее время — как подпись часа, только цвета своей линии и серединой на ней.
                    Text(hhmm(app.now)).font(Ink.body).monospacedDigit().foregroundStyle(Ink.accent)
                        .frame(height: rowHeight)
                        .offset(y: ruler.y(app.now) - rowHeight / 2)
                    HStack(spacing: 0) {
                        Circle().fill(Ink.accent).frame(width: 6, height: 6)
                        Rectangle().fill(Ink.accent).frame(height: 1.5)
                    }
                    .frame(width: width - gutter + 3)
                    .offset(x: gutter - 3, y: ruler.y(app.now) - 3)
                    .zIndex(2)
                }
                ForEach(day.placed, id: \.meeting.id) { placed in
                    let laneWidth = (width - gutter - cardGap * CGFloat(placed.lanes - 1)) / CGFloat(placed.lanes)
                    let top = ruler.y(placed.meeting.start), bottom = ruler.y(placed.meeting.end)
                    // Линия часа занимает 1 pt под своей отметкой — сверху карточка отступает и от неё.
                    card(placed.meeting, height: bottom - top - 1 - 2 * cardMargin, oneLine: lanes > 5)
                        .frame(width: laneWidth)
                        .offset(x: gutter + CGFloat(placed.lane) * (laneWidth + cardGap), y: top + 1 + cardMargin)
                        .zIndex(1)
                }
            }
            .frame(width: width, height: ruler.height, alignment: .topLeading)
        }
    }

    private func card(_ m: Meeting, height: CGFloat, oneLine: Bool) -> some View {
        Card(app: app, meeting: m,
             look: look(m, now: app.now, state: app.state, ringing: app.reminding, late: app.late),
             showsJoin: showsJoin(m, now: app.now),
             opening: app.opening == m.id,
             height: oneLine ? min(height, rowHeight + 8) : height)
    }

    /// Начало и конец рабочего дня: «10:00 · GMT-3 04:00».
    private func edge(_ date: Date) -> some View {
        (Text(hhmm(date)).foregroundStyle(Ink.secondary) + homeLabel(date, config: app.config))
            .font(Ink.body).monospacedDigit().frame(height: rowHeight)
    }

    /// «свободно 1 ч · GMT-3 07:00–08:00» по центру промежутка.
    private func free(_ gap: Gap) -> some View {
        (Text("свободно \(durationText(gap.end.timeIntervalSince(gap.start)))").foregroundStyle(Ink.secondary)
            + homeLabel(gap.start, to: gap.end, config: app.config))
            .font(Ink.body).monospacedDigit().lineLimit(1)
            // Подложка цвета листа закрывает пунктир под надписью; зерно и виньетка ложатся поверх неё, как на лист.
            .padding(.horizontal, 4)
            .background(Ink.window)
    }


    private func hours(from start: Date, to end: Date) -> [Date] {
        var hour = Calendar.current.nextDate(after: start, matching: DateComponents(minute: 0), matchingPolicy: .nextTime)!
        var result: [Date] = []
        while hour < end {
            result.append(hour)
            hour += 3600
        }
        return result
    }
}
