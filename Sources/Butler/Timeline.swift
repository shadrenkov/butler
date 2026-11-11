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

/// Пустое место в дорожке: в группе пересекающихся встреч эта дорожка свободна, пока соседние заняты.
struct Hole {
    let start: Date
    let end: Date
    let lane: Int
    let lanes: Int
}

func holes(_ placed: [Placed]) -> [Hole] {
    var result: [Hole] = []
    var group: [Placed] = []
    var groupEnd = Date.distantPast

    func close() {
        guard let lanes = group.first?.lanes, lanes > 1 else { return }
        let start = group.map(\.meeting.start).min()!
        for lane in 0..<lanes {
            var free = start
            for p in group.filter({ $0.lane == lane }).sorted(by: { $0.meeting.start < $1.meeting.start }) {
                if p.meeting.start > free { result.append(Hole(start: free, end: p.meeting.start, lane: lane, lanes: lanes)) }
                free = max(free, p.meeting.end)
            }
            if free < groupEnd { result.append(Hole(start: free, end: groupEnd, lane: lane, lanes: lanes)) }
        }
    }

    // Группы — как в `layout`: встреча, начавшаяся не раньше конца предыдущих, открывает новую.
    for p in placed.sorted(by: { ($0.meeting.start, $0.meeting.end) < ($1.meeting.start, $1.meeting.end) }) {
        if !group.isEmpty && p.meeting.start >= groupEnd {
            close()
            group = []
        }
        group.append(p)
        groupEnd = max(groupEnd, p.meeting.end)
    }
    close()
    return result
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
            // Поля дня — ровно под подпись края, при любом масштабе: иначе в редкий день над шкалой пустая строка.
            if a == day.start || b == day.end { need = 20 }
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

/// « · 04:00» или « · 04:00–07:00» — время во втором, домашнем часовом поясе: без подписи, его видно по голубому.
/// Второй пояс выключен в настройках — пусто.
func homeLabel(_ start: Date, to end: Date? = nil, config: Config) -> Text {
    guard config.showHomeTime else { return Text("") }
    let times = [start, end].compactMap { $0 }.map { homeTime($0, config: config) }
    return Text(" · ").foregroundStyle(Ink.secondary) + Text(times.joined(separator: "–")).foregroundStyle(Ink.home)
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
            // Под концом дня — место под полоску пейзажа, если день и без него помещается целиком: все карточки
            // остаются в полные строки.
            let short = ruler(day, available: available - 100)
            let roomy = app.config.pictures && day.placed.allSatisfy { short.y($0.meeting.end) - short.y($0.meeting.start) >= neededHeight($0.meeting, lines: 3) - 0.5 }
            let ruler = roomy ? short : ruler(day, available: available)
            let lanes = day.placed.map(\.lanes).max() ?? 1
            let width = windowWidth(lanes: lanes) - 24
            let art = app.config.pictures ? artwork(day, ruler: ruler, width: width) : Artwork()
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
                // Пейзажи — под подписями и карточками.
                pieces(art.under)
                edge(first).offset(x: gutter, y: ruler.y(first) - rowHeight - 3)
                edge(last).offset(x: gutter, y: ruler.y(last) + 3)
                ForEach(day.gaps, id: \.start) { gap in
                    let height = ruler.y(gap.end) - ruler.y(gap.start)
                    free(gap, lines: labelLines(height))
                        .frame(width: width - gutter, height: height)
                        .offset(x: gutter, y: ruler.y(gap.start))
                }
                // Вставки — поверх подписи перерыва, если задевают её: акварель сквозь печать.
                pieces(art.middle)
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
                // Кляксы — поверх карточек, как брызги чернил на листе; щелчков не ловят.
                pieces(art.over).allowsHitTesting(false).zIndex(1.5)
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

    /// Начало и конец рабочего дня: «10:00 · 04:00».
    private func edge(_ date: Date) -> some View {
        (Text(hhmm(date)).foregroundStyle(Ink.secondary) + homeLabel(date, config: app.config))
            .font(Ink.body).monospacedDigit().frame(height: rowHeight)
    }

    /// Рисунок на шкале: где, повёрнут ли, заполняет ли рамку, обрезаясь.
    struct Piece {
        let name: String
        let rect: CGRect
        var fills = false
        var angle = 0.0
        var opacity = 1.0
        /// Побледнеть в правом нижнем углу — под индикатором и шестерёнкой, чтобы они не терялись в деталях.
        var fadesCorner = false
    }

    /// Рисунки дня по слоям: пейзаж под подписями, вставки над подписями, кляксы над карточками.
    struct Artwork {
        var under: [Piece] = []
        var middle: [Piece] = []
        var over: [Piece] = []
    }

    /// Где и что рисовать. Под концом дня — пейзаж во всю ширину карточки, до её нижнего края: подпись конца,
    /// индикатор и шестерёнка лежат поверх. Перерыв от часа — вставка у края, по очереди справа и слева, а в большом — под надписью. Пустая дорожка от 30 минут рядом с
    /// пропущенной встречей — вставка посередине. И две-три большие бледные кляксы, каждая в своей полосе по
    /// высоте, по очереди слева и справа. Вид рисунка за день не повторяется.
    private func artwork(_ day: (start: Date, end: Date, placed: [Placed], gaps: [Gap]), ruler: Ruler, width: CGFloat) -> Artwork {
        var art = Artwork()
        var choice = Choice(day: day.start)
        let lane = width - gutter

        let top = ruler.y(day.end - 15 * 60)
        // Шкала кончается на 12 pt выше края карточки — у её нижнего поля.
        let room = available + 12 - top
        if room >= 60, let name = choice.pick(landscapes, perDay: 1, at: day.end) {
            // Заполняет высоту, обрезаясь по бокам, — но не больше чем вдвое: в совсем короткий день сверху поле.
            let height = min(room, (width + 24) / 2)
            art.under.append(Piece(name: name, rect: CGRect(x: -12, y: top + room - height, width: width + 24, height: height), fills: true,
                                   fadesCorner: true))
        }

        var spots: [(rect: CGRect, time: Date)] = []
        // Большой перерыв — вставка под надписью, посередине. Иначе у самого края, подальше от надписи, по очереди:
        // в одном перерыве справа, в следующем слева.
        var side = 0
        for gap in day.gaps where gap.end.timeIntervalSince(gap.start) >= 3600 {
            let height = ruler.y(gap.end) - ruler.y(gap.start)
            let middle = ruler.y(gap.start) + height / 2
            let label = CGFloat(labelLines(height)) * rowHeight
            let under = height / 2 - label / 2 - 10
            if under >= 80 {
                let size = min(under, 100)
                spots.append((CGRect(x: gutter + (lane - size) / 2, y: middle + label / 2 + 4, width: size, height: size), gap.start))
            } else {
                let size = min(height - 10, 100)
                spots.append((CGRect(x: side % 2 == 0 ? width - 2 - size : gutter + 2, y: middle - size / 2, width: size, height: size), gap.start))
                side += 1
            }
        }
        for hole in holes(day.placed) where hole.end.timeIntervalSince(hole.start) >= 1800 {
            let skipped = day.placed.contains { p in
                p.lanes == hole.lanes && p.lane != hole.lane && p.meeting.start < hole.end && p.meeting.end > hole.start
                    && [.skipped, .ignored].contains(look(p.meeting, now: app.now, state: app.state, ringing: app.reminding, late: app.late))
            }
            guard skipped else { continue }
            let laneWidth = (lane - cardGap * CGFloat(hole.lanes - 1)) / CGFloat(hole.lanes)
            let height = ruler.y(hole.end) - ruler.y(hole.start)
            let size = min(height - 10, laneWidth - 10, 100)
            spots.append((CGRect(x: gutter + CGFloat(hole.lane) * (laneWidth + cardGap) + (laneWidth - size) / 2,
                                 y: ruler.y(hole.start) + (height - size) / 2, width: size, height: size), hole.start))
        }
        // Самые просторные места — первыми: им достаются рисунки, если видов на всех не хватит.
        for spot in spots.filter({ $0.rect.width >= 44 }).sorted(by: { $0.rect.width > $1.rect.width }) {
            if let name = choice.pick(vignettes, perDay: 3, at: spot.time) { art.middle.append(Piece(name: name, rect: spot.rect)) }
        }

        let count = 2 + Int(choice.next() * 2)
        let band = ruler.height / CGFloat(count)
        let half = lane / 2
        let right = choice.next() < 0.5
        for i in 0..<count {
            guard let name = choice.pick(blots, perDay: 3, at: day.start + 13 * 3600) else { break }
            let size = 100 + choice.next() * 80
            let x = gutter + ((i % 2 == 0) == right ? half : 0) + choice.next() * max(0, half - size)
            let y = band * CGFloat(i) + choice.next() * max(0, band - size)
            art.over.append(Piece(name: name, rect: CGRect(x: x, y: y, width: size, height: size), angle: Double(choice.next()) * 360, opacity: 0.25))
        }
        return art
    }

    private func pieces(_ list: [Piece]) -> some View {
        ForEach(Array(list.enumerated()), id: \.offset) { _, piece in
            Picture(name: piece.name, fills: piece.fills)
                .frame(width: piece.rect.width, height: piece.rect.height)
                .clipped()
                .mask {
                    if piece.fadesCorner {
                        RadialGradient(stops: [.init(color: .black.opacity(0.4), location: 0), .init(color: .black.opacity(0.4), location: 0.4),
                                               .init(color: .black, location: 1)],
                                       center: .bottomTrailing, startRadius: 0, endRadius: 90)
                    } else {
                        Rectangle()
                    }
                }
                .rotationEffect(.degrees(piece.angle))
                .opacity(piece.opacity)
                .offset(x: piece.rect.minX, y: piece.rect.minY)
        }
    }

    /// Сколько строк у надписи промежутка: в высоком — две, если есть время второго пояса и рисунки, которым это
    /// освобождает место.
    private func labelLines(_ height: CGFloat) -> Int {
        app.config.pictures && app.config.showHomeTime && height >= 44 ? 2 : 1
    }

    /// «свободно 1 ч · 07:00–08:00» по центру промежутка; в высоком промежутке — в две строки, время второго пояса
    /// второй строкой: по бокам остаётся больше места под рисунки.
    private func free(_ gap: Gap, lines: Int) -> some View {
        let duration = Text("свободно \(durationText(gap.end.timeIntervalSince(gap.start)))").foregroundStyle(Ink.secondary)
        return Group {
            if lines == 2 {
                VStack(spacing: 0) {
                    duration
                    Text("\(homeTime(gap.start, config: app.config))–\(homeTime(gap.end, config: app.config))").foregroundStyle(Ink.home)
                }
            } else {
                duration + homeLabel(gap.start, to: gap.end, config: app.config)
            }
        }
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
