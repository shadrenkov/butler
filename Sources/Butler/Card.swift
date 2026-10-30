import SwiftUI

// Карточка встречи и всплывающие подробности.

func ink(_ hex: UInt32) -> Color {
    Color(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
}

/// Один шрифт — системный, 10 pt — везде; различаются только начертание и цвет.
enum Ink {
    static let title = Font.system(size: 10, weight: .semibold)
    static let body = Font.system(size: 10)

    static let primary = ink(0x3A2E22)
    static let secondary = ink(0x6F604F)
    static let tertiary = ink(0x9C8B77)
    static let faded = ink(0xB0A595)
    static let alert = ink(0xC23B26)
    static let accent = ink(0xD9652B)
    static let home = ink(0x0A8FE0)
    static let window = ink(0xFAF7F2)
}

/// Зерно бумаги: мелкий шум вокруг среднего серого, один раз на запуск. Тайл 128 pt — повтор не бросается в глаза.
private let grain: CGImage = {
    let size = 256
    let pixels = Data((0..<size * size).map { _ in UInt8.random(in: 78...178) })
    return CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: size,
                   space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(), provider: CGDataProvider(data: pixels as CFData)!,
                   decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
}()

extension View {
    /// Лист бумаги: зерно и виньетка — края на 5% темнее середины. Поверх всего: зерно проступает и
    /// сквозь плашки встреч, как сквозь типографскую краску. Зерно — мягким светом: светлее и темнее поровну, лист
    /// не сереет и не теряет тепла.
    func paper() -> some View {
        overlay {
            Image(decorative: grain, scale: 2).resizable(resizingMode: .tile)
                .opacity(0.85).blendMode(.softLight).allowsHitTesting(false)
            RadialGradient(colors: [.clear, .black.opacity(0.05)], center: .center, startRadius: 0, endRadius: 600)
                .blendMode(.multiply).allowsHitTesting(false)
        }
    }
}

/// Картон карточки: VIP — книжный красноватый, свои встречи — зелёный, остальные — жёлтый.
private enum Stock { case vip, mine, other }

private func stock(_ m: Meeting) -> Stock {
    m.isVIP ? .vip : m.isOrganizer == true ? .mine : .other
}

/// Заливка карточки: активность — яркостью (звенит → идёт → обычная), вид встречи — цветом картона.
private func fill(_ look: Look, _ stock: Stock) -> Color {
    let (vip, mine, other): (UInt32, UInt32, UInt32) = switch look {
    case .ringing: (0xEE9688, 0xC4CB9F, 0xFFBE55)
    case .current, .late: (0xF3B0A5, 0xD0D5B4, 0xFFC96A)
    case .normal: (0xF7DAD4, 0xE5E6D6, 0xF8E6C6)
    case .past: (0xF3E9E6, 0xECECE5, 0xF0EBE3)
    // Пропущенная — одна или вся серия — просто бледно-серая, без надписей.
    case .skipped, .ignored: (0xEAE9E7, 0xEAE9E7, 0xEAE9E7)
    }
    return ink(stock == .vip ? vip : stock == .mine ? mine : other)
}

private func glow(_ stock: Stock) -> Color {
    ink(stock == .vip ? 0xCF5F4C : stock == .mine ? 0xA9B47E : 0xFFAA33)
}

private func isInactive(_ look: Look) -> Bool {
    [.past, .skipped, .ignored].contains(look)
}

/// Имя VIP-контакта во всплывашке — книжным красным, остальные — как текст вокруг.
private let vipName = ink(0xB84F3E)

/// Участники на виду и сколько ушло под «и ещё 23»: по алфавиту, VIP-контакты — всегда на виду.
func shownAttendees(_ names: [String], limit: Int, config: Config) -> (shown: [String], rest: Int) {
    let sorted = names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    var room = limit - sorted.filter { isVIPOrganizer($0, config) }.count
    let shown = sorted.filter { name in
        if isVIPOrganizer(name, config) { return true }
        room -= 1
        return room >= 0
    }
    return (shown, names.count - shown.count)
}

/// «Иванов Иван Иванович» → «Иванов Иван»: отчество не нужно.
func shortName(_ name: String) -> String {
    let words = name.split(separator: " ")
    guard words.count >= 3 else { return name }
    let patronymic = ["вич", "вна", "чна", "ична", "оглы", "кызы"]
    return words.filter { word in !patronymic.contains { word.lowercased().hasSuffix($0) } }.joined(separator: " ")
}

/// Карточка: строки сверху вниз — время, название, организатор — сколько помещается по высоте.
/// Значки и кнопки живут только в строке времени, справа, и никогда не закрывают текст.
struct Card: View {
    let app: App
    let meeting: Meeting
    let look: Look
    let showsJoin: Bool
    let opening: Bool
    let height: CGFloat

    @SwiftUI.State private var hoverCard = false
    @SwiftUI.State private var showsInfo = false

    private var rows: Int { max(1, Int((height - 6) / rowHeight)) }
    private var text: Color { isInactive(look) ? Ink.faded : Ink.primary }
    private var quiet: Color { isInactive(look) ? Ink.faded : Ink.secondary }
    /// Звенит или идёт прямо сейчас — у такой карточки кромка чётче.
    private var isActive: Bool { [.ringing, .current, .late].contains(look) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if rows == 1 {
                HStack(spacing: 4) {
                    (Text("\(hhmm(meeting.start)) · ").font(Ink.body).monospacedDigit().foregroundStyle(quiet)
                        + Text(meeting.subject).font(Ink.title).foregroundStyle(text))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    icons
                }
                .frame(height: rowHeight)
            } else {
                timeRow
                Text(meeting.subject).font(Ink.title).foregroundStyle(text)
                    .lineLimit(max(1, rows - 2))
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                if rows >= 3 {
                    Group {
                        if opening {
                            OpeningCaption(link: meeting.joinURL)
                        } else if meeting.isOrganizer != true {
                            Text(shortName(meeting.organizerName)).font(Ink.body).foregroundStyle(quiet).lineLimit(1)
                        }
                    }
                    .frame(height: rowHeight)
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: height, alignment: .top)
        .background(paper)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .shadow(color: look == .ringing ? glow(stock(meeting)).opacity(0.55) : .clear, radius: 4)
        .contentShape(Rectangle())
        .onHover { hoverCard = $0 }
        .onTapGesture { showsInfo.toggle() }
        .popover(isPresented: $showsInfo, arrowEdge: .leading) {
            Info(app: app, meeting: meeting, look: look, showsJoin: showsJoin)
        }
    }

    /// Плашка напечатана на листе: ровная заливка без бликов и тени, край чуть темнее — как у оттиска.
    /// У VIP край насыщенно-красный (у прошедшей — бледнее), у пропущенной — серый, как у всех.
    /// Под мышью край темнеет: по карточке можно кликнуть.
    private var paper: some View {
        let shape = RoundedRectangle(cornerRadius: 5)
        let strong = hoverCard || showsInfo || isActive
        let vip = stock(meeting) == .vip && ![.skipped, .ignored].contains(look)
        let edge = vip ? ink(strong ? 0xB84F3E : 0xCF5F4C).opacity(look == .past ? 0.45 : 1)
                       : .black.opacity(hoverCard || showsInfo ? 0.4 : isActive ? 0.3 : isInactive(look) ? 0.10 : 0.18)
        return shape.fill(fill(look, stock(meeting)))
            .overlay(shape.strokeBorder(edge, lineWidth: strong ? 1 : 0.75))
    }

    private var timeRow: some View {
        HStack(spacing: 4) {
            // В узкой дорожке — только начало.
            ViewThatFits(in: .horizontal) {
                Text("\(hhmm(meeting.start))–\(hhmm(meeting.end))")
                Text(hhmm(meeting.start))
            }
            .font(Ink.body).monospacedDigit().lineLimit(1).foregroundStyle(quiet)
            mark
            Spacer(minLength: 4)
            icons
        }
        .frame(height: rowHeight)
    }

    @ViewBuilder private var mark: some View {
        switch look {
        case .late: Text("опаздываю").font(Ink.body).foregroundStyle(Ink.alert).lineLimit(1)
        default: EmptyView()
        }
    }

    /// Справа в строке времени: при наведении — «не пойду» или «вернуть», затем подключение и повторение.
    private var icons: some View {
        HStack(spacing: 2) {
            if hoverCard {
                // «Свободную» в Outlook не вернуть: её пропуск записан там, а не в Butler.
                if look != .past && look != .ignored && meeting.isFree != true {
                    let skipped = look == .skipped
                    // Колокольчик: звенит — можно пропустить, зачёркнут — пропущена, можно вернуть.
                    IconButton(symbol: skipped ? "bell.slash" : "bell",
                               help: skipped ? "Вернуть" : "Пропустить",
                               hoverColor: skipped ? Ink.accent : Ink.alert) {
                        skipped ? app.unskip(meeting) : app.skip(meeting)
                    }
                    .font(.system(size: 12))
                }
            }
            if showsJoin || opening {
                JoinIcon(countdown: app.linkCountdown?.ids.contains(meeting.id) == true ? app.linkCountdown?.progress : nil,
                         opening: opening, pulseFrom: look == .ringing ? app.chimeAt : nil) {
                    app.join(meeting)
                }
            }
            if meeting.isRecurring {
                Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(Ink.tertiary).help("Повторяющаяся встреча")
                    .padding(.horizontal, 2)
            }
        }
        .font(Ink.body)
        .fixedSize()
    }
}

private struct IconButton: View {
    let symbol: String
    let help: String
    var color = Ink.secondary
    let hoverColor: Color
    let action: () -> Void
    @SwiftUI.State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).foregroundStyle(hovering ? hoverColor : color)
        }
        .buttonStyle(Hover(padding: 2))
        .help(help)
        .onHover { hovering = $0 }
    }
}

/// Кругляш из того же картона, что и карточки: свет сверху, чёткая кромка, светлая грань и тень.
/// Под мышью темнеет, растёт и поднимается.
private struct Disc: View {
    let symbol: String
    var count = 1
    let size: CGFloat
    let color: UInt32
    let hoverColor: UInt32
    var iconColor = Color.white
    @SwiftUI.State private var hovering = false

    var body: some View {
        // Несколько значков — рядом и чуть мельче, чтобы уместились в кругляш; начертание плотнее, чтобы линии
        // были той же толщины, что у одиночных значков.
        HStack(spacing: 1) {
            ForEach(0..<count, id: \.self) { _ in Image(systemName: symbol) }
        }
            .font(.system(size: size * (count > 1 ? 0.32 : 0.4), weight: count > 1 ? .medium : .regular))
            .foregroundStyle(iconColor)
            .frame(width: size, height: size)
            .background {
                Circle().fill(ink(hovering ? hoverColor : color))
                    .overlay(Circle().fill(LinearGradient(colors: [.white.opacity(0.35), .clear], startPoint: .top, endPoint: .center)))
                    .overlay(Circle().strokeBorder(.black.opacity(hovering ? 0.4 : 0.22), lineWidth: 0.75))
                    .overlay(Circle().inset(by: 1).stroke(.white.opacity(0.45), lineWidth: 0.5))
                    .shadow(color: .black.opacity(hovering ? 0.3 : 0.15), radius: hovering ? 3 : 1, y: hovering ? 2 : 1)
            }
            .contentShape(Circle())
            .scaleEffect(hovering ? 1.12 : 1)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .onHover { hovering = $0 }
    }
}

/// Подключиться — маленькая камера в строке времени. Всё, что Butler делает с МТС Линк сам, видно на ней:
/// пока встреча звенит, от неё в такт звуку расходятся волны; перед автооткрытием вокруг заполняется
/// кольцо отсчёта; пока Butler открывает встречу, кольцо вращается.
private struct JoinIcon: View {
    let countdown: Double?
    let opening: Bool
    let pulseFrom: Date?
    let action: () -> Void

    var body: some View {
        IconButton(symbol: "video.fill", help: "Подключиться", color: Ink.accent, hoverColor: Ink.alert, action: action)
            .background {
                TimelineView(.animation(paused: pulseFrom == nil && !opening)) { context in
                    ZStack {
                        if let pulseFrom {
                            let elapsed = context.date.timeIntervalSince(pulseFrom)
                            let t = elapsed < 0 ? 1 : elapsed.truncatingRemainder(dividingBy: 2) / 1.2
                            Circle().stroke(Ink.accent, lineWidth: 1.5)
                                .frame(width: 14, height: 14)
                                .scaleEffect(1 + 0.7 * min(t, 1))
                                .opacity(t < 1 ? 0.8 * (1 - t) : 0)
                        }
                        if opening {
                            Circle().trim(from: 0, to: 0.7)
                                .stroke(Ink.accent, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                                .frame(width: 16, height: 16)
                                .rotationEffect(.degrees(context.date.timeIntervalSinceReferenceDate * 360))
                        } else if let countdown {
                            Circle().stroke(Ink.accent.opacity(0.25), lineWidth: 1.5).frame(width: 16, height: 16)
                            Circle().trim(from: 0, to: countdown)
                                .stroke(Ink.accent, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                                .frame(width: 16, height: 16)
                                .animation(.linear(duration: 1), value: countdown)
                        }
                    }
                }
            }
            .help(opening ? "Butler открывает встречу" : countdown != nil ? "Скоро Butler сам откроет МТС Линк" : "Подключиться")
    }
}

/// Действие во всплывающих подробностях: крупный кругляш и подпись под ним.
struct Action: View {
    let symbol: String
    /// Сколько значков рядом: два колокольчика — вся серия.
    var count = 1
    let title: String
    var color: UInt32 = 0xF3EBDD
    var hoverColor: UInt32 = 0xE6D8C2
    var iconColor = Ink.secondary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Disc(symbol: symbol, count: count, size: 32, color: color, hoverColor: hoverColor, iconColor: iconColor)
                Text(title).font(Ink.body).foregroundStyle(Ink.secondary).multilineTextAlignment(.center).fixedSize()
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }
}

private struct OpeningCaption: View {
    let link: URL?
    @SwiftUI.State private var done = false

    var body: some View {
        let target = link.map(MTSLink.isLink) == true ? "в МТС Линк" : "в браузере"
        Text(done ? "Открыто" : "Открываю \(target)…").font(Ink.body).foregroundStyle(Ink.accent).lineLimit(1)
            .task {
                try? await Task.sleep(for: .seconds(1.2))
                done = true
            }
    }
}

/// Описание встречи со ссылками: только то, что написано как `http://`, `https://` или почта. Текст приходит из чужих
/// приглашений: `file:`, `ftp:` и слова вроде `notes.md`, в которых детектор тоже видит адрес, ссылками не становятся.
func linked(_ text: String) -> AttributedString {
    var result = AttributedString(text)
    let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    for match in detector?.matches(in: text, range: NSRange(text.startIndex..., in: text)) ?? [] {
        guard let url = match.url, let found = Range(match.range, in: text), let range = Range(found, in: result) else { continue }
        let written = text[found].lowercased()
        guard url.scheme == "mailto" || written.hasPrefix("http://") || written.hasPrefix("https://") else { continue }
        result[range].link = url
    }
    return result
}

/// Описание встречи. `NSTextView`, а не `Text`: выделяемый `Text` над ссылкой показывает текстовый курсор.
private struct Description: NSViewRepresentable {
    let text: String

    final class Field: NSTextView {
        override func clicked(onLink link: Any, at charIndex: Int) {
            if let url = link as? URL { MTSLink.open(url) }
        }
    }

    func makeNSView(context: Context) -> NSTextView {
        let view = Field()
        view.isEditable = false
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.linkTextAttributes = [.foregroundColor: NSColor(Ink.accent), .underlineStyle: NSUnderlineStyle.single.rawValue,
                                   .cursor: NSCursor.pointingHand]
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        guard view.string != text else { return }
        let string = NSMutableAttributedString(linked(text))
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 1
        string.addAttributes([.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor(Ink.primary), .paragraphStyle: style],
                             range: NSRange(location: 0, length: string.length))
        view.textStorage?.setAttributedString(string)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: NSTextView, context: Context) -> CGSize? {
        guard let container = view.textContainer, let manager = view.layoutManager else { return nil }
        let width = proposal.width ?? 376
        container.size = NSSize(width: width, height: .greatestFiniteMagnitude)
        manager.ensureLayout(for: container)
        return CGSize(width: width, height: ceil(manager.usedRect(for: container).height))
    }
}

/// Кругляш VIP: залит, когда VIP.
@MainActor private func vipAction(_ vip: Bool, title: String, action: @escaping () -> Void) -> Action {
    Action(symbol: vip ? "star.fill" : "star", title: title, color: vip ? 0xCF5F4C : 0xF3EBDD, hoverColor: vip ? 0xB84F3E : 0xE6D8C2,
           iconColor: vip ? .white : Ink.secondary, action: action)
}

/// Имена в строку, как текст: что не влезает, целиком уходит на следующую строку.
private struct Flow: Layout {
    private func places(_ subviews: Subviews, width: CGFloat) -> (points: [CGPoint], size: CGSize) {
        let space: CGFloat = 2.3 // ширина пробела в тексте этого размера
        var points: [CGPoint] = []
        var (x, y, height, right): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                (x, y, height) = (0, y + height, 0)
            }
            points.append(CGPoint(x: x, y: y))
            right = max(right, x + size.width)
            height = max(height, size.height)
            x += size.width + space
        }
        return (points, CGSize(width: right, height: y + height))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        places(subviews, width: proposal.width ?? .infinity).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let points = places(subviews, width: bounds.width).points
        for (view, point) in zip(subviews, points) {
            view.place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }

    /// Значок слева стоит на базовой линии первой строки.
    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGFloat? {
        guide == .firstTextBaseline ? subviews.first.map { bounds.minY + $0.dimensions(in: .unspecified)[.firstTextBaseline] } : nil
    }
}

/// Организатор или участник: под мышью подсвечивается, щелчок открывает маленькую всплывашку с кругляшом VIP.
/// `name` — полное имя, его видит список VIP, `title` — как оно показано.
private struct Contact: View {
    let app: App
    let name: String
    let title: String
    @SwiftUI.State private var hovering = false
    @SwiftUI.State private var open = false

    var body: some View {
        let vip = isVIPOrganizer(name, app.config)
        Text(title)
            .foregroundStyle(vip ? vipName : Ink.secondary)
            // Подсветка шире имени, но строку не раздвигает.
            .background {
                RoundedRectangle(cornerRadius: 3).fill(hovering || open ? ink(0xE6D8C2) : .clear)
                    .padding(.horizontal, -2)
                    .padding(.vertical, -1)
            }
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture { open.toggle() }
            .popover(isPresented: $open, arrowEdge: .bottom) {
                vipAction(vip, title: vip ? "Убрать из VIP" : "Добавить в VIP") { app.toggleVIP(name) }
                    .frame(width: 96)
                    .padding(12)
                    .background(Ink.window)
            }
    }
}

/// Всплывающие подробности: время по календарю и во втором поясе, участники, описание, редкие действия.
private struct Info: View {
    let app: App
    let meeting: Meeting
    let look: Look
    let showsJoin: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // «10:00–13:00 · GMT-3 04:00–07:00» — как этикетки на шкале.
            (Text("\(hhmm(meeting.start))–\(hhmm(meeting.end))").foregroundStyle(Ink.secondary)
                + homeLabel(meeting.start, to: meeting.end, config: app.config))
                .font(Ink.title).monospacedDigit()
            if !meeting.organizerName.isEmpty {
                // Звезда у организатора — сделать его VIP или убрать из VIP.
                let vip = isVIPOrganizer(meeting.organizerName, app.config)
                HStack(spacing: 4) {
                    Image(systemName: "person").foregroundStyle(Ink.tertiary)
                    Contact(app: app, name: meeting.organizerName, title: meeting.organizerName)
                    // Маленькая кнопка, как «Пропустить» на карточке в основном окне.
                    IconButton(symbol: vip ? "star.fill" : "star",
                               help: vip ? "Убрать организатора из VIP" : "Сделать организатора VIP",
                               color: vip ? ink(0xCF5F4C) : Ink.tertiary, hoverColor: vip ? Ink.secondary : ink(0xCF5F4C)) {
                        app.toggleVIP(meeting.organizerName)
                    }
                }
                .font(Ink.body)
            }
            if let names = meeting.attendees, !names.isEmpty {
                let (shown, rest) = shownAttendees(names, limit: 40, config: app.config)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Image(systemName: "person.2").foregroundStyle(Ink.tertiary)
                    Flow {
                        ForEach(shown.indices, id: \.self) { index in
                            HStack(spacing: 0) {
                                Contact(app: app, name: shown[index], title: shortName(shown[index]))
                                if index < shown.count - 1 { Text(",").foregroundStyle(Ink.secondary) }
                            }
                        }
                        if rest > 0 { Text("и ещё \(rest)").foregroundStyle(Ink.secondary) }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
                .font(Ink.body)
            }
            if let text = meeting.description {
                ScrollView {
                    Description(text: text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 280)
                .fixedSize(horizontal: false, vertical: true)
            }
            if meeting.attendees?.isEmpty != false && meeting.description == nil {
                Text("Ни описания, ни участников").font(Ink.body).foregroundStyle(Ink.tertiary)
            }
            Divider()
            actions
        }
        .padding(12)
        .frame(width: 400)
        .background(Ink.window)
    }

    /// Внизу — крупные кругляши: подключиться; пропустить или вернуть эту встречу; у серии — пропустить
    /// или вернуть все её встречи; VIP — серия или встреча; скрыть.
    private var actions: some View {
        // Второй строкой: в одну подпись про серию не влезает в свою долю ряда.
        let all = meeting.isRecurring ? "\nвсю серию" : ""
        return HStack(alignment: .top, spacing: 0) {
            if showsJoin {
                Action(symbol: "video.fill", title: "Подключиться", color: 0xE0743A, hoverColor: 0xC2531F, iconColor: .white) {
                    app.join(meeting)
                }
            }
            if app.state.ignored[meeting.ignoreKey] != nil {
                Action(symbol: "bell.slash", count: meeting.isRecurring ? 2 : 1, title: "Вернуть" + all) { app.unignore(meeting.ignoreKey) }
            } else {
                // «Свободную» в Outlook не вернуть: её пропуск записан там, а не в Butler.
                if look == .skipped && meeting.isFree != true {
                    Action(symbol: "bell.slash", title: "Вернуть") { app.unskip(meeting) }
                } else if look != .past && look != .skipped {
                    Action(symbol: "bell", title: "Пропустить") { app.skip(meeting) }
                }
                if meeting.isRecurring {
                    Action(symbol: "bell", count: 2, title: "Пропустить" + all) { app.ignore(meeting) }
                }
            }
            // Залит, когда встреча VIP — по правилу или вручную; нажатие переопределяет правило.
            let vip = meeting.isVIP
            vipAction(vip, title: "VIP") { app.toggleVIPMeeting(meeting) }
                .help(meeting.isRecurring ? (vip ? "Серия больше не VIP" : "Все встречи серии — VIP")
                                          : (vip ? "Встреча больше не VIP" : "Эта встреча — VIP"))
            Action(symbol: "trash", title: "Скрыть" + all) { app.hide(meeting) }
                .help((meeting.isRecurring ? "Скрыть всю серию из расписания Butler" : "Скрыть из расписания Butler") + ". Вернуть можно в настройках")
        }
        .frame(maxWidth: .infinity)
    }
}
