import AppKit
import SwiftUI

// Календарь на месяц: сетка с точками VIP поверх стопки дней, важные встречи
// выбранного дня, загрузка месяца с индикатором, отметки дней и производственный календарь.

// MARK: - Месяцы и сетка

/// `2026-10-24` → `2026-10`.
func monthOf(_ day: String) -> String {
    String(day.prefix(7))
}

private func firstDay(_ month: String) -> Date? {
    bounds(month + "-01")?.start
}

/// Месяц со сдвигом: −1 — предыдущий, +1 — следующий.
func shiftMonth(_ month: String, by offset: Int) -> String {
    guard let start = firstDay(month), let date = Calendar.current.date(byAdding: .month, value: offset, to: start) else { return month }
    return monthOf(dayString(date))
}

/// Сколько месяцев от `from` до `to`: следующий — 1, прошлый — −1.
func monthsBetween(_ from: String, _ to: String) -> Int {
    guard let a = firstDay(from), let b = firstDay(to) else { return 0 }
    return Calendar.current.dateComponents([.month], from: a, to: b).month ?? 0
}

/// «Октябрь 2026».
func monthTitle(_ month: String) -> String {
    guard let start = firstDay(month) else { return month }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "ru_RU")
    formatter.dateFormat = "LLLL yyyy"
    let text = formatter.string(from: start)
    return text.prefix(1).uppercased() + text.dropFirst()
}

/// Сетка месяца: шесть недель с понедельника — карточка не прыгает по высоте. Края заполнены днями соседних
/// месяцев.
func grid(_ month: String) -> [[String]] {
    guard let start = firstDay(month) else { return [] }
    // `weekday`: 1 — воскресенье, 2 — понедельник.
    let lead = (Calendar.current.component(.weekday, from: start) + 5) % 7
    return (0..<6).map { week in
        (0..<7).map { column in
            Calendar.current.date(byAdding: .day, value: week * 7 + column - lead, to: start).map(dayString) ?? ""
        }
    }
}

// MARK: - Чтение месяца

/// Прочитанный месяц: боксы ящиков, время попытки и итог — в памяти, не дольше 10 минут без перечитывания.
struct MonthRead {
    var boxes: [String: Box] = [:]
    var at: Date
    var failure: Failure?
    /// Какие дни покрыло чтение — вся сетка месяца, с краями соседних.
    var days: ClosedRange<String>?
}

/// Идущее чтение месяца — для индикатора: по ящику сколько встреч дочитать (`nil` — ещё идёт `FindItem`).
struct MonthLoad {
    struct Read { var stale: Int?; var fetched = 0; var listedAt: Date?; var doneAt: Date? }
    let month: String
    let started: Date
    var reads: [String: Read]
    /// Доля, уже показанная полоской на последнем шаге: полоска не откатывается ниже неё.
    var shown = 0.0
}

/// Сколько обычно длится чтение месяца: экспоненциальные средние, вес новой загрузки 0,3.
struct LoadStats: Codable {
    /// Секунды на `FindItem` месяца.
    var find: Double?
    /// Секунды `GetItem` на одну встречу.
    var perItem: Double?
    /// Секунды на месяц целиком — самый долгий ящик.
    var month: Double?

    mutating func add(_ load: MonthLoad, now: Date) {
        func average(_ old: Double?, _ new: Double) -> Double { old.map { $0 * 0.7 + new * 0.3 } ?? new }
        let reads = load.reads.values
        let finds = reads.compactMap { $0.listedAt?.timeIntervalSince(load.started) }
        if !finds.isEmpty { find = average(find, finds.reduce(0, +) / Double(finds.count)) }
        // Мелкие дочитывания шумят: время на встречу берётся только по заметным.
        let items = reads.compactMap { r -> Double? in
            guard let stale = r.stale, stale >= 10, let listed = r.listedAt, let done = r.doneAt else { return nil }
            return done.timeIntervalSince(listed) / Double(stale)
        }
        if !items.isEmpty { perItem = average(perItem, items.reduce(0, +) / Double(items.count)) }
        month = average(month, now.timeIntervalSince(load.started))
    }
}

/// Какая доля месяца загружена. `nil` — оценить нечем: неопределённое движение. Доля растёт со
/// временем к ожидаемой длительности, не ниже уже показанной и не выше 0,95, пока чтение не кончилось.
func estimate(elapsed: TimeInterval, reads: [MonthLoad.Read], stats: LoadStats, shown: Double) -> Double? {
    let known = reads.compactMap(\.stale)
    let expected: Double
    if known.isEmpty {
        guard let month = stats.month else { return nil }
        expected = month
    } else {
        // Ящики читаются параллельно: ждём самый долгий; кто ещё без `FindItem` — как самый большой из известных.
        expected = (stats.find ?? 1.5) + (stats.perItem ?? 0.04) * Double(known.max() ?? 0)
    }
    return min(max(shown, elapsed / max(expected, 0.1)), 0.95)
}

// MARK: - Производственный календарь

/// Производственный календарь года с isdayoff.ru: цифра на день, `1` — нерабочий.
struct Workdays: Codable {
    var days: String
    var at: Date
    var tried: Date?
}

/// Ответ isdayoff.ru, если он годный: цифра на каждый день года и ничего больше.
func workdays(from text: String, year: Int) -> String? {
    guard let start = bounds(String(format: "%04d-01-01", year))?.start,
          let count = Calendar.current.range(of: .day, in: .year, for: start)?.count else { return nil }
    let days = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return days.count == count && days.allSatisfy({ $0.isASCII && $0.isNumber }) ? days : nil
}

/// Нерабочий ли день: по производственному календарю, без него — суббота и воскресенье.
func nonWorking(_ day: String, workdays: [String: Workdays]) -> Bool {
    guard let start = bounds(day)?.start else { return false }
    if let days = workdays[String(day.prefix(4))]?.days, let ordinal = Calendar.current.ordinality(of: .day, in: .year, for: start),
       ordinal <= days.count {
        return days[days.index(days.startIndex, offsetBy: ordinal - 1)] == "1"
    }
    return [1, 7].contains(Calendar.current.component(.weekday, from: start))
}

/// Год производственного календаря: получить, если его нет или он старше 30 дней, — не чаще раза в сутки.
/// Отказ сервиса гасит только подкраску праздников.
@MainActor func fetchWorkdays(_ year: String, state: State) async -> Workdays? {
    let old = state.workdays[year]
    let now = Date.now
    guard now.timeIntervalSince(old?.at ?? .distantPast) > 30 * 86_400,
          now.timeIntervalSince(old?.tried ?? .distantPast) > 86_400,
          !offlineMode, let number = Int(year),
          let url = URL(string: "https://isdayoff.ru/api/getdata?year=\(year)&cc=ru") else { return nil }
    var request = URLRequest(url: url)
    request.timeoutInterval = 10
    if let (data, response) = try? await URLSession.shared.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200,
       let days = workdays(from: String(decoding: data, as: UTF8.self), year: number) {
        return Workdays(days: days, at: now, tried: now)
    }
    return Workdays(days: old?.days ?? "", at: old?.at ?? .distantPast, tried: now)
}

// MARK: - Карточка месяца

/// «4 встречи», «5 встреч», «1 встреча».
private func meetingsCount(_ n: Int) -> String {
    let (ten, hundred) = (n % 10, n % 100)
    let word = ten == 1 && hundred != 11 ? "встреча" : (2...4).contains(ten) && !(12...14).contains(hundred) ? "встречи" : "встреч"
    return "\(n) \(word)"
}

/// Карточка месяца: заголовок с листанием, сетка, важные встречи выбранного дня, внизу —
/// индикатор загрузки, «Отметить день», «Открыть день», огонёк и шестерёнка.
struct MonthView: View {
    let app: App
    /// В картинке для буфера обмена прокрутки нет: `ImageRenderer` её не рисует.
    var scrolls = true

    var body: some View {
        let month = app.shownMonth
        let current = today()
        // Встречи дней месяца собираются один раз на кадр, а не в каждой клетке.
        let meetings = Dictionary(uniqueKeysWithValues: grid(month).joined().map { ($0, app.monthMeetings($0)) })
        let failed = app.months[month]?.failure != nil
        VStack(alignment: .leading, spacing: 8) {
            header(month, current: current)
            // Разлинованная сетка, как в бумажном календаре: снаружи скруглённая рамка, внутри пунктир того же
            // цвета, что часы на шкале. Первый ряд — дни недели: ниже, залит цветом линий, буквы цветом листа.
            // Клетки чужих месяцев пустые, но в линейку.
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    ForEach(["пн", "вт", "ср", "чт", "пт", "сб", "вс"], id: \.self) { name in
                        Text(name).font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(["сб", "вс"].contains(name) ? ink(0xF7C8B8) : Ink.window).frame(maxWidth: .infinity)
                    }
                }
                .frame(height: 18)
                .background(ink(0xBDB09E))
                VStack(spacing: 0) {
                    ForEach(Array(grid(month).enumerated()), id: \.offset) { _, week in
                        HStack(spacing: 0) {
                            ForEach(Array(week.enumerated()), id: \.offset) { _, day in
                                Cell(app: app, day: day, month: month, meetings: meetings[day] ?? nil, failed: failed)
                                    .frame(maxWidth: .infinity)
                                .frame(height: 44)
                            }
                        }
                    }
                }
                // Прошедшие дни съедает «змейка»: по неделе — затемнённая колбаска в высоту цифр от понедельника до
                // воскресенья или до сегодня; сегодня на ней — светлое окошко.
                .overlay { Snake(weeks: grid(month), current: current).allowsHitTesting(false) }
                .overlay {
                    GeometryReader { geo in
                        let (w, h) = (geo.size.width / 7, geo.size.height / 6)
                        Path { path in
                            for column in 1..<7 {
                                path.move(to: CGPoint(x: w * CGFloat(column), y: 0))
                                path.addLine(to: CGPoint(x: w * CGFloat(column), y: geo.size.height))
                            }
                            for row in 1..<6 {
                                path.move(to: CGPoint(x: 0, y: h * CGFloat(row)))
                                path.addLine(to: CGPoint(x: geo.size.width, y: h * CGFloat(row)))
                            }
                        }
                        .stroke(ink(0xBDB09E), style: StrokeStyle(lineWidth: 1.2, lineCap: .round, dash: [0, 3]))
                    }
                    .allowsHitTesting(false)
                }
            }
            // Своя виньетка у таблицы: края темнее середины, как у листа, только заметнее.
            .overlay {
                EllipticalGradient(colors: [.clear, .black.opacity(0.055)], center: .center,
                                   startRadiusFraction: 0.3, endRadiusFraction: 0.75)
                    .blendMode(.multiply)
                    .allowsHitTesting(false)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(ink(0xBDB09E), lineWidth: 1))
            // Черты под сеткой нет: разлинованная сетка и так отделяет её от выбранного дня. Вокруг — воздух,
            // чтобы таблица не прилипала к краям карточки, заголовку и списку.
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            // Низ карточки — с теми же полями по бокам, что у сетки.
            Selected(app: app, meetings: meetings[app.selectedDay] ?? app.monthMeetings(app.selectedDay), scrolls: scrolls)
                .padding(.horizontal, 8)
            Spacer(minLength: 0)
            footer(month)
        }
        .font(Ink.body)
        .foregroundStyle(Ink.secondary)
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Ink.window)
    }

    private func header(_ month: String, current: String) -> some View {
        HStack(spacing: 2) {
            Button { app.shiftMonth(-1) } label: { Image(systemName: "chevron.left") }.help("Предыдущий месяц")
            // Ширина постоянная, чтобы стрелки не сдвигались вместе с длиной названия.
            Text(monthTitle(month)).font(Ink.title).foregroundStyle(Ink.primary).frame(width: 110)
            Button { app.shiftMonth(1) } label: { Image(systemName: "chevron.right") }.help("Следующий месяц")
            Spacer()
            if month != monthOf(current) {
                Button("Сегодня") { app.showMonth(monthOf(current), selecting: current) }
            }
            // «Готово» текстом: крестик на карточке дня прячет всё окно, а здесь снимается только календарь.
            Button("Готово") { app.closeMonth() }
                .keyboardShortcut(app.settingsOpen ? nil : .cancelAction)
                .foregroundStyle(Ink.primary)
            Group {
                Button("") { app.moveSelection(-1) }.keyboardShortcut(key(.leftArrow))
                Button("") { app.moveSelection(1) }.keyboardShortcut(key(.rightArrow))
                Button("") { app.moveSelection(-7) }.keyboardShortcut(key(.upArrow))
                Button("") { app.moveSelection(7) }.keyboardShortcut(key(.downArrow))
                Button("") { app.toggleMark(app.selectedDay) }.keyboardShortcut(key(.space))
                Button("") { app.openDay(app.selectedDay) }.keyboardShortcut(key(.return))
            }
            .frame(width: 0)
            .opacity(0)
        }
        .buttonStyle(Hover(padding: 6))
    }


    private func key(_ key: KeyEquivalent) -> KeyboardShortcut? {
        app.settingsOpen ? nil : KeyboardShortcut(key, modifiers: [])
    }

    private func footer(_ month: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let failure = app.months[month]?.failure {
                Text("Месяц не загружен: \(failure.text)").foregroundStyle(Ink.alert).lineLimit(1).padding(.horizontal, 8)
            } else if let load = app.monthLoad, load.month == month {
                Progress(app: app, load: load).padding(.horizontal, 8)
            }
            // Кругляши — как действия во всплывашке встречи: отметка включённая — красная, как VIP.
            HStack(alignment: .bottom, spacing: 12) {
                let marked = app.config.markedDays.contains(app.selectedDay)
                Action(symbol: "circle", title: "Отметить день", color: marked ? 0xCF5F4C : 0xF3EBDD,
                       hoverColor: marked ? 0xB84F3E : 0xE6D8C2, iconColor: marked ? .white : Ink.secondary) {
                    app.toggleMark(app.selectedDay)
                }
                .fixedSize()
                .padding(.leading, 8)
                Action(symbol: "calendar.day.timeline.left", title: "Открыть день") { app.openDay(app.selectedDay) }
                    .fixedSize()
                Spacer()
                HStack(spacing: 2) {
                    Indicator(app: app)
                    Button { app.openSettings() } label: { Image(systemName: "gearshape") }
                        .buttonStyle(Hover(padding: 4))
                        .foregroundStyle(Ink.tertiary)
                        .help("Настройки")
                }
                // Как у карточки дня: значки в 12 pt от краёв.
                .padding(.trailing, -4)
                .padding(.bottom, -2)
            }
        }
    }
}

/// Важные встречи выбранного дня — теми же плашками, что на шкале, списком по времени. Отдельный вид: плашкам нужно
/// текущее время, и раз в секунду перерисовывается только список, а не вся сетка с пересборкой 42 дней.
private struct Selected: View {
    let app: App
    let meetings: [Meeting]?
    let scrolls: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(dayTitle(app.selectedDay) ?? "").font(Ink.title).foregroundStyle(Ink.primary)
            if let meetings {
                if scrolls {
                    ScrollView { list(meetings) }.scrollBounceBehavior(.basedOnSize)
                } else {
                    list(meetings)
                }
            } else {
                Text(app.months[monthOf(app.selectedDay)]?.failure != nil ? "Встречи дня не загружены" : "Загружаю…")
                    .foregroundStyle(Ink.tertiary)
            }
        }
    }

    private func list(_ meetings: [Meeting]) -> some View {
        let vip = meetings.filter { important($0, app.state) }
        let others = meetings.filter { !$0.isAllDay }.count - vip.count
        return VStack(alignment: .leading, spacing: 4) {
            if vip.isEmpty { Text("Важных встреч нет").foregroundStyle(Ink.tertiary) }
            ForEach(vip) { m in
                Card(app: app, meeting: m,
                     look: look(m, now: app.now, state: app.state, ringing: app.reminding, late: app.late),
                     showsJoin: showsJoin(m, now: app.now),
                     opening: app.opening == m.id,
                     height: rowHeight * 3 + 6)
            }
            if others > 0 { Text("и ещё \(meetingsCount(others))").foregroundStyle(Ink.tertiary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Важная встреча — та, что на шкале красная: VIP, со временем и не пропущенная (пропущенные и свободные — серые).
/// Пропуск от часов не зависит, поэтому время не передаётся: сетка месяца не перерисовывается каждую секунду.
func important(_ m: Meeting, _ state: State) -> Bool {
    guard m.isVIP && !m.isAllDay else { return false }
    return ![.skipped, .ignored].contains(look(m, now: .distantPast, state: state, ringing: [], late: []))
}

/// Клетка дня: число и под ним точки важных встреч. Признаки: нерабочий — цвет числа, прошедший —
/// под «змейкой», сегодня — окошко в ней, число как у всех, выбранный — рамка, выходной и праздник — ещё и тёплый фон клетки, отмеченный — кружок карандашом, под мышью —
/// подсветка, как у всего, что нажимается.
private struct Cell: View {
    let app: App
    let day: String
    /// Месяц карточки: дни соседних месяцев на краях сетки — очень бледные.
    let month: String
    let meetings: [Meeting]?
    let failed: Bool
    @SwiftUI.State private var hovering = false
    /// Курсор ссылки над выбранным днём: следующий щелчок откроет его.
    @SwiftUI.State private var linkable = false

    var body: some View {
        let holiday = nonWorking(day, workdays: app.state.workdays)
        let faint = monthOf(day) != month
        let digits = holiday ? Ink.alert.opacity(faint ? 0.17 : 0.6) : ink(0x6A4E39).opacity(faint ? 0.17 : 0.7)
        let vip = meetings?.filter { important($0, app.state) }.count
        VStack(spacing: 4) {
            Text(String(Int(day.suffix(2)) ?? 0))
                // Жирные коричневые чернила, а не чёрный: зерно листа проступает и сквозь них.
                .font(.system(size: 13, weight: .heavy))
                .monospacedDigit()
                .foregroundStyle(digits)
                .frame(width: 28, height: 22)
                .overlay {
                    if app.config.markedDays.contains(day) {
                        Pencil().stroke(ink(0xCF5F4C).opacity(0.85), style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
                    }
                }
            dots(vip).opacity(faint ? 0.25 : 1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            // Выходные и праздники — клетка целиком чуть тёплым тоном, подсветка под мышью — поверх.
            if holiday { weekendTint.opacity(0.6) }
            RoundedRectangle(cornerRadius: 3).fill(hovering ? .black.opacity(0.05) : .clear).padding(2)
        }
        .overlay {
            // Выбранный день — рамкой цвета его цифр; сегодня видно по окошку в «змейке».
            if day == app.selectedDay { RoundedRectangle(cornerRadius: 4).strokeBorder(digits, lineWidth: 1.5).padding(2) }
        }
        .contentShape(Rectangle())
        .onHover { inside in
            hovering = inside
            linkable = inside && day == app.selectedDay
        }
        .pointerStyle(linkable ? .link : nil)
        // Выбранный день открывается, другой выбирается — двойной щелчок поэтому открывает любой день. Курсор
        // ставится, не дожидаясь движения мыши: выбрали — ссылка, открыли — обычный над карточкой дня.
        .onTapGesture {
            // День соседнего месяца: сначала его месяц ложится на стопку, день выбран уже в нём.
            guard !faint else {
                app.showMonth(monthOf(day), selecting: day)
                return
            }
            let opening = day == app.selectedDay
            linkable = !opening
            app.select(day)
            // После щелчка окно перерисовывается и сбрасывает курсор в стрелку до первого движения мыши — ставим
            // нужный курсор ещё раз, уже после перерисовки.
            Task { @MainActor in
                for delay in [0, 50, 150] {
                    try? await Task.sleep(for: .milliseconds(delay))
                    (linkable && hovering ? NSCursor.pointingHand : NSCursor.arrow).set()
                }
            }
        }
    }

    @ViewBuilder private func dots(_ vip: Int?) -> some View {
        HStack(spacing: 2) {
            if let vip {
                ForEach(0..<min(vip, 5), id: \.self) { _ in Circle().fill(ink(0xCF5F4C)).frame(width: 4, height: 4) }
                if vip > 5 { Text("\(vip)").font(.system(size: 7)).foregroundStyle(ink(0xCF5F4C)) }
            } else if failed {
                Circle().fill(Ink.faded.opacity(0.4)).frame(width: 4, height: 4)
            } else {
                // Все заполнители мерцают вместе: фаза — от общих часов, а не от появления клетки. Мерцают, только пока
                // месяц читается, и 20 раз в секунду, а не 60: иначе окно перерисовывается без конца и тратит процессор.
                TimelineView(.animation(minimumInterval: 1.0 / 20, paused: app.monthLoad == nil)) { context in
                    let phase = sin(context.date.timeIntervalSinceReferenceDate * 2 * .pi / 1.2)
                    Circle().fill(Ink.faded).frame(width: 4, height: 4).opacity(0.45 + 0.35 * phase)
                }
            }
        }
        .frame(height: 5)
    }
}

/// Розоватый тон выходных и праздников — фон клеток; буквы «сб», «вс» в шапке — того же тона, только ярче.
private let weekendTint = ink(0xF4E3DB)

/// «Змейка» прошедших дней: в каждой неделе, где есть прошедшие дни, — колбаска в высоту цифр от понедельника до
/// воскресенья, а в неделе с сегодняшним днём — до него, с вырезанным светлым окошком вокруг его числа. Темнит
/// умножением: цифры под ней видны.
private struct Snake: View {
    let weeks: [[String]]
    let current: String

    var body: some View {
        GeometryReader { geo in
            let (w, h) = (geo.size.width / 7, geo.size.height / CGFloat(max(weeks.count, 1)))
            Path { path in
                for (row, week) in weeks.enumerated() {
                    guard let first = week.first, first <= current else { continue }
                    let today = week.firstIndex(of: current)
                    let last = today ?? week.lastIndex { $0 < current } ?? 0
                    // Число в клетке: 22 pt по центру содержимого высотой 31 (число, зазор 4, точки 5).
                    let top = CGFloat(row) * h + (h - 31) / 2 - 1
                    path.addRoundedRect(in: CGRect(x: 4, y: top, width: CGFloat(last + 1) * w - 8, height: 24),
                                        cornerSize: CGSize(width: 12, height: 12))
                    if let today {
                        path.addRoundedRect(in: CGRect(x: CGFloat(today) * w + w / 2 - 16, y: top + 3, width: 32, height: 18),
                                            cornerSize: CGSize(width: 9, height: 9))
                    }
                }
            }
            .fill(ink(0xEAE2D5), style: FillStyle(eoFill: true))
            .blendMode(.multiply)
        }
    }
}

/// Кружок от руки: радиус чуть гуляет, а конец заходит за начало и ложится чуть шире — как обвели карандашом.
struct Pencil: Shape {
    func path(in rect: CGRect) -> Path {
        let steps = 60, extra = 9
        var path = Path()
        for i in 0...(steps + extra) {
            let t = Double(i) / Double(steps) * 2 * .pi - 2.2
            let spiral = 0.97 + 0.09 * Double(i) / Double(steps + extra)
            let wobble = 1 + 0.035 * sin(3 * t + 0.7) + 0.025 * sin(5 * t + 2)
            let point = CGPoint(x: rect.midX + rect.width / 2 * spiral * wobble * cos(t),
                                y: rect.midY + rect.height / 2 * spiral * wobble * sin(t))
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }
}

/// Полоска загрузки — без чисел, только сколько примерно сделано; пока оценить нечем — бегущий отрезок.
private struct Progress: View {
    let app: App
    let load: MonthLoad

    var body: some View {
        TimelineView(.periodic(from: load.started, by: 0.2)) { context in
            let elapsed = context.date.timeIntervalSince(load.started)
            let guess = estimate(elapsed: elapsed, reads: Array(load.reads.values), stats: app.state.loadStats, shown: load.shown)
            HStack(spacing: 6) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Ink.faded.opacity(0.3))
                        if let guess {
                            Capsule().fill(Ink.accent).frame(width: geo.size.width * guess)
                        } else {
                            let x = (elapsed.truncatingRemainder(dividingBy: 1.4) / 1.4) * (geo.size.width + 40) - 40
                            Capsule().fill(Ink.accent).frame(width: 40).offset(x: x)
                        }
                    }
                    .clipShape(Capsule())
                }
                .frame(height: 3)
            }
        }
    }
}
