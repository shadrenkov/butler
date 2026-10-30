import AppKit
import SwiftUI

/// Окно Butler — день и рядом с ним детали встречи: поверх всех окон, в том числе полноэкранных,
/// и не забирает фокус.
final class Panel: NSPanel {
    private let app: App
    private let host: Host
    private var clickOutside: Any?

    init(app: App, content: some View) {
        self.app = app
        host = Host(rootView: AnyView(content))
        // Без рамки и с прозрачным фоном: окно — стопка карточек (дни, настройки сверху); скругление рисуют
        // карточки, тень macOS строит по их форме.
        super.init(contentRect: .zero, styleMask: [.nonactivatingPanel], backing: .buffered, defer: true)
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        host.safeAreaRegions = []
        contentView = host
    }

    override var canBecomeKey: Bool { true }

    /// У Butler нет главного меню, а с ним и пунктов «Правка» — поэтому ⌘X, ⌘C, ⌘V, ⌘A, ⌘Z, ⌘⇧Z в полях ввода
    /// разбираются здесь. По коду клавиши, а не по букве: так они работают и в русской раскладке.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // ⌃C и ⌘C вне поля ввода — картинка верхней карточки. В настройках её нет: там живые поля и пароли.
        if event.keyCode == 8, !app.settingsOpen, modifiers == .control || (modifiers == .command && !(firstResponder is NSText)) {
            if let png = cardPNG() {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setData(png, forType: .png)
            }
            return true
        }
        let action: Selector? = switch (event.keyCode, modifiers) {
        case (7, .command): #selector(NSText.cut(_:))
        case (8, .command): #selector(NSText.copy(_:))
        case (9, .command): #selector(NSText.paste(_:))
        case (0, .command): #selector(NSText.selectAll(_:))
        case (6, .command): Selector(("undo:"))
        case (6, [.command, .shift]): Selector(("redo:"))
        default: nil
        }
        if let action, NSApp.sendAction(action, to: nil, from: self) { return true }
        return super.performKeyEquivalent(with: event)
    }

    /// Верхняя карточка, как на экране: на Retina — вдвое подробнее, размером в те же точки.
    func cardPNG() -> Data? {
        let renderer = ImageRenderer(content: DayView(app: app).top)
        renderer.scale = backingScaleFactor
        return renderer.cgImage.flatMap { png($0, scale: renderer.scale) }
    }

    /// Настройки — элементы AppKit, `ImageRenderer` рисует вместо них заглушки. Поэтому снимается само окно
    /// и обрезается по карточке настроек: она лежит на шаг выше дня.
    func settingsPNG() -> Data? {
        // Без рамки фокуса на первом поле.
        makeFirstResponder(nil)
        let file = FileManager.default.temporaryDirectory.appending(path: "butler-settings.png")
        defer { try? FileManager.default.removeItem(at: file) }
        let shot = Process()
        shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        shot.arguments = ["-x", "-o", "-l", "\(windowNumber)", file.path]
        guard (try? shot.run()) != nil else { return nil }
        shot.waitUntilExit()
        guard let image = (try? Data(contentsOf: file)).flatMap(NSBitmapImageRep.init(data:))?.cgImage else { return nil }
        let scale = CGFloat(image.width) / frame.width
        let card = CGRect(x: (windowMargin + 2) * scale, y: (windowMargin - 2) * scale,
                          width: (frame.width - 2 * windowMargin) * scale, height: (frame.height - 2 * windowMargin) * scale)
        return image.cropping(to: card).flatMap { png($0, scale: scale) }
    }

    private func png(_ image: CGImage, scale: CGFloat) -> Data? {
        let bitmap = NSBitmapImageRep(cgImage: image)
        bitmap.size = NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        return bitmap.representation(using: .png, properties: [:])
    }

    /// Окна Butler ставятся точно туда, куда задано, — AppKit не подтягивает их к главному экрану.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    /// Когда меняется содержимое, окно растёт вниз и влево: верхний и правый края остаются на месте.
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        var rect = frameRect
        if isVisible && rect.origin == frame.origin {
            rect.origin = NSPoint(x: frame.maxX - rect.width, y: frame.maxY - rect.height)
        }
        super.setFrame(rect, display: flag)
    }

    /// Окно, которое Butler поднимает сам, — напоминание или сбой связи: правый верхний угол монитора,
    /// где я последний раз открывал окно; если этот монитор отключён — того, где я работаю.
    func showAlert(soft: Bool) {
        let number = UserDefaults.standard.integer(forKey: "screen")
        place(on: NSScreen.screens.first { Self.number($0) == number } ?? workScreen())
        // Секунда на то, чтобы клик, начатый до появления окна, его не отложил.
        closeOnClickOutside(after: 1)
        guard soft, !isVisible else {
            alphaValue = 1
            return orderFrontRegardless()
        }
        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.4; animator().alphaValue = 1 }
    }

    /// По клику на иконку — тоже справа вверху, на мониторе с этой иконкой. Окно сразу получает клавиши. Окно
    /// напоминания — нет: оно всплывает, пока я печатаю в другом приложении.
    func showFromMenu(_ button: NSStatusBarButton) {
        guard let screen = button.window?.screen else { return }
        UserDefaults.standard.set(Self.number(screen), forKey: "screen")
        place(on: screen)
        alphaValue = 1
        orderFrontRegardless()
        makeKey()
        closeOnClickOutside(after: 0)
    }

    /// Клик мимо окна закрывает его, а во время напоминания — откладывает, как «Закрыть».
    /// Butler не становится активным приложением, поэтому глобальный монитор видит и клики по его
    /// собственным окнам — их отсеиваем по координатам.
    private func closeOnClickOutside(after delay: TimeInterval) {
        if let clickOutside { NSEvent.removeMonitor(clickOutside) }
        let from = Date() + delay
        clickOutside = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, Date() >= from else { return }
                let point = NSEvent.mouseLocation
                // Списки настроек и подробности встречи — свои окна Butler, иногда за рамкой панели.
                // У панели — без прозрачных полей вокруг карточки.
                let inside = NSApp.windows.contains {
                    $0.isVisible && ($0 === self ? $0.frame.insetBy(dx: windowMargin, dy: windowMargin) : $0.frame).contains(point)
                }
                if !inside { self.app.close() }
            }
        }
    }

    private func place(on screen: NSScreen) {
        let visible = screen.visibleFrame
        setContentSize(host.fittingSize)
        // Карточка — в 12 pt от краёв экрана; прозрачные поля окна заходят за эти 12 pt.
        setFrameTopLeftPoint(NSPoint(x: visible.maxX - frame.width - 12 + windowMargin, y: visible.maxY - 12 + windowMargin))
    }

    /// Спрятанное окно снимает месяц: открывается оно всё равно на сегодняшнем дне, а месяц в скрытом окне
    /// только перерисовывается по таймеру и тратит процессор.
    override func orderOut(_ sender: Any?) {
        if let clickOutside { NSEvent.removeMonitor(clickOutside) }
        clickOutside = nil
        app.monthOpen = false
        super.orderOut(sender)
    }


    private static func number(_ screen: NSScreen) -> Int {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.intValue ?? 0
    }

    /// Монитор с верхним окном активного приложения; не нашли — основной.
    private func workScreen() -> NSScreen {
        let fallback = NSScreen.main ?? NSScreen.screens[0]
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        guard let window = windows.first(where: {
                  $0[kCGWindowOwnerPID as String] as? pid_t == pid && $0[kCGWindowLayer as String] as? Int == 0
              }),
              let bounds = window[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary)
        else { return fallback }
        // У CG начало координат — верхний левый угол основного экрана, у NSScreen — нижний левый.
        let center = NSPoint(x: rect.midX, y: NSScreen.screens[0].frame.maxY - rect.midY)
        return NSScreen.screens.first { $0.frame.contains(center) } ?? fallback
    }
}

/// Butler не бывает активным приложением, и без этого первый клик по его окну лишь делал бы окно
/// ключевым, не нажимая кнопку.
private final class Host: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Высота окна постоянная: почти весь меньший из мониторов — день помещается на любом, — но не больше 940 pt.
@MainActor func windowHeight() -> CGFloat {
    min((NSScreen.screens.map(\.visibleFrame.height).min() ?? 900) - 40, 940)
}

/// Скругление карточки, её граница и прозрачные поля окна вокруг — под стопку: неделя дней и настройки сверху,
/// по 2 pt на карточку.
private let windowRadius: CGFloat = 12
private let cardEdge = ink(0xCFC3B1)
let windowMargin: CGFloat = 16

/// Сколько дней от `from` до `to`: завтра — 1, вчера — −1.
func daysBetween(_ from: String, _ to: String) -> Int {
    guard let a = bounds(from)?.start, let b = bounds(to)?.start else { return 0 }
    return Calendar.current.dateComponents([.day], from: a, to: b).day ?? 0
}

/// День в окне: заголовок с датой и стрелками дней, шкала, при напоминании — его кнопки.
struct DayView: View {
    let app: App

    var body: some View {
        card
            // Под карточками месяца и настроек день не реагирует — ни на щелчки, ни на клавиши.
            .disabled(app.settingsOpen || app.monthOpen)
            .offset(lift(pile))
            // После сдвига: фон, месяц и настройки берут несдвинутое место карточки и лежат от сегодняшней.
            .background { stack }
            .overlay { if app.monthOpen { monthStack } }
            .overlay {
                if app.settingsOpen {
                    let below = app.monthOpen ? monthTop : lift(pile)
                    let past = (app.monthOpen ? monthPile : pile) < 0
                    settings.offset(place(below, shift(1, past: past)))
                }
            }
            // Прозрачные поля вокруг карточки — под стопку.
            .padding(windowMargin)
    }

    /// Верхняя карточка без стопки под ней: такой она уходит в буфер обмена.
    @ViewBuilder var top: some View {
        if app.monthOpen {
            MonthView(app: app, scrolls: false)
                .paper()
                .clipShape(RoundedRectangle(cornerRadius: windowRadius))
                .overlay(RoundedRectangle(cornerRadius: windowRadius).strokeBorder(cardEdge))
                .frame(width: width, height: windowHeight())
        } else {
            card
        }
    }

    private var width: CGFloat {
        windowWidth(lanes: app.shownMeetings.flatMap { layout($0)?.placed.map(\.lanes).max() } ?? 1)
    }

    @ViewBuilder private var card: some View {
        let meetings = app.shownMeetings
        VStack(alignment: .leading, spacing: 8) {
            header
            notices
            ForEach((meetings ?? []).filter(\.isAllDay)) { m in
                Label(m.subject, systemImage: "sun.max").font(Ink.body).foregroundStyle(Ink.secondary).lineLimit(1)
            }
            if let meetings, meetings.contains(where: { !$0.isAllDay }) {
                GeometryReader { geo in
                    Scale(app: app, meetings: meetings, isToday: app.isShowingToday, available: geo.size.height)
                }
            } else if meetings != nil {
                Text("Свободный день").font(Ink.title).foregroundStyle(Ink.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if app.config.mailboxes.isEmpty {
                VStack(spacing: 4) {
                    Text("Нет ящиков — задайте их в настройках").font(Ink.title).foregroundStyle(Ink.secondary)
                    Button("Настройки") { app.openSettings() }.buttonStyle(Hover(padding: 6)).foregroundStyle(Ink.accent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = app.isShowingToday ? app.scheduleError : app.dayErrors[app.shownDay] {
                Text("Расписание не получено: \(error)").font(Ink.body).foregroundStyle(Ink.alert)
                Spacer()
            } else {
                Loading().id(app.shownDay).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(12)
        .frame(width: width, height: windowHeight(), alignment: .topLeading)
        .background(Ink.window)
        .overlay(alignment: .bottomTrailing) {
            HStack(spacing: 2) {
                if let trouble = trouble {
                    Text(trouble).font(Ink.body).foregroundStyle(Ink.alert).lineLimit(1)
                }
                Indicator(app: app)
                Button { app.openSettings() } label: { Image(systemName: "gearshape") }
                    .buttonStyle(Hover(padding: 4))
                    .foregroundStyle(Ink.tertiary)
                    .help("Настройки")
            }
            // Значок — в 12 pt от краёв, как карточки: 12 минус отступ подсветки `Hover`.
            .padding(.trailing, 8)
            .padding(.bottom, 10)
        }
        .paper()
        .clipShape(RoundedRectangle(cornerRadius: windowRadius))
        .overlay(RoundedRectangle(cornerRadius: windowRadius).strokeBorder(cardEdge))
    }

    /// Настройки — ещё одна карточка, положенная на стопку поверх дня; «Готово» её снимает. Всплывающие окна
    /// настроек — на этой карточке.
    private var settings: some View {
        ZStack {
            SettingsView(app: app)
                .paper()
                .clipShape(RoundedRectangle(cornerRadius: windowRadius))
                .overlay(RoundedRectangle(cornerRadius: windowRadius).strokeBorder(cardEdge))
            if let dialog = app.dialog {
                ZStack {
                    Color.black.opacity(0.2).contentShape(Rectangle()).onTapGesture {}
                    switch dialog {
                    case .vip: VIPDialog(app: app)
                    case .hidden: HiddenDialog(app: app)
                    case .mailboxes: MailboxesEditor(app: app)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: windowRadius))
            }
        }
    }

    /// Сколько дней в стопке под показанным: от сегодняшнего до него.
    private var pile: Int { daysBetween(today(), app.shownDay) }

    /// Месяцы — своя стопка поверх дня: первый на шаг выше дня, каждый следующий — ещё шаг от первого.
    private var monthPile: Int { monthsBetween(app.firstMonth, app.shownMonth) }
    private var monthBase: CGSize { place(lift(pile), shift(1, past: pile < 0)) }
    private var monthTop: CGSize { place(monthBase, shift(min(abs(monthPile), 7), past: monthPile < 0)) }

    private var monthStack: some View {
        ZStack {
            ForEach(0..<min(abs(monthPile), 7), id: \.self) { level in
                Ink.window
                    .paper()
                    .clipShape(RoundedRectangle(cornerRadius: windowRadius))
                    .overlay(RoundedRectangle(cornerRadius: windowRadius).strokeBorder(cardEdge))
                    .offset(place(monthBase, shift(level, past: monthPile < 0)))
            }
            MonthView(app: app)
                .paper()
                .clipShape(RoundedRectangle(cornerRadius: windowRadius))
                .overlay(RoundedRectangle(cornerRadius: windowRadius).strokeBorder(cardEdge))
                .disabled(app.settingsOpen)
                .offset(monthTop)
        }
    }

    /// Сдвиг карточки — сумма шагов, но в пределах прозрачных полей окна: глубже карточки ложатся в одно место.
    private func place(_ parts: CGSize...) -> CGSize {
        let (width, height) = (parts.map(\.width).reduce(0, +), parts.map(\.height).reduce(0, +))
        return CGSize(width: min(max(width, -windowMargin), windowMargin), height: min(max(height, -windowMargin), windowMargin))
    }

    /// Сдвиг на `steps` шагов по 2 pt: будущее — вверх и вправо, края нижних выглядывают снизу слева; прошлое —
    /// вниз и влево, края выглядывают сверху справа. Без анимации: бумажная карточка ложится или снимается, а не
    /// наплывает.
    private func shift(_ steps: Int, past: Bool) -> CGSize {
        let d = 2 * CGFloat(steps)
        return past ? CGSize(width: -d, height: d) : CGSize(width: d, height: -d)
    }

    /// Где лежит карточка `level`-го дня относительно сегодняшней: стопки хватает на неделю, дальше сдвиг не растёт.
    private func lift(_ level: Int) -> CGSize {
        shift(min(abs(level), 7), past: level < 0)
    }

    /// Стопка под показанным днём: сегодняшняя карточка и дни до показанного — каждая на своём месте, нижние не
    /// двигаются. Листаешь дальше — показанная становится частью стопки, а новая ложится сверху. Карточка —
    /// просто чёткая граница: две карточки — две границы. Глубже седьмой они легли бы в одно место — их не рисуем.
    private var stack: some View {
        ZStack {
            ForEach(0..<min(abs(pile), 7), id: \.self) { level in
                Ink.window
                    .paper()
                    .clipShape(RoundedRectangle(cornerRadius: windowRadius))
                    .overlay(RoundedRectangle(cornerRadius: windowRadius).strokeBorder(cardEdge))
                    .offset(lift(pile > 0 ? level : -level))
                    .transition(.identity)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 2) {
            Button { app.shift(-1) } label: { Image(systemName: "chevron.left") }
                .keyboardShortcut(key(.leftArrow))
                .help("Предыдущий день")
            // Ширина постоянная, чтобы стрелки не сдвигались вместе с длиной даты.
            // Дата — кнопка: щелчок кладёт на стопку календарь на месяц. Отмеченный в календаре день обведён.
            // Кружок — по рамке подсветки, как у стрелок рядом: отступ `Hover` (6 по бокам, 3 сверху и снизу)
            // почти весь уходит под кружок, а от него до текста — ещё 6 pt.
            Button { app.openMonth() } label: {
                Text(dayTitle(app.shownDay) ?? "").font(Ink.title).foregroundStyle(Ink.primary)
                    .padding(.horizontal, 6)
                    .overlay {
                        if app.config.markedDays.contains(app.shownDay) {
                            Pencil().stroke(ink(0xCF5F4C).opacity(0.85), style: StrokeStyle(lineWidth: 1.3, lineCap: .round))
                                .padding(.horizontal, -5).padding(.vertical, -2.5)
                        }
                    }
            }
            .keyboardShortcut(key(.return))
            .help("Календарь на месяц")
            .frame(width: 124)
            Button { app.shift(1) } label: { Image(systemName: "chevron.right") }
                .keyboardShortcut(key(.rightArrow))
                .help("Следующий день")
            Spacer()
            // Escape работает и при напоминании, когда крестика нет: это то же, что щелчок мимо окна.
            Button("") { app.close() }.keyboardShortcut(key(.escape)).frame(width: 0).opacity(0)
            // Пока есть кнопки напоминания, крестик лишний: «Отложить на 5 мин» делает то же самое.
            if !app.pending.isEmpty {
                ReminderBar(app: app).fixedSize()
            } else {
                if !app.isShowingToday {
                    Button("Сегодня") { app.show(today()) }
                }
                Button { app.close() } label: { Image(systemName: "xmark") }.help("Закрыть")
            }
        }
        .font(Ink.body)
        .foregroundStyle(Ink.secondary)
        .buttonStyle(Hover(padding: 6))
    }

    /// Клавиши дня — только когда он сверху: под месяцем и настройками действуют их клавиши.
    private func key(_ key: KeyEquivalent) -> KeyboardShortcut? {
        app.settingsOpen || app.monthOpen ? nil : KeyboardShortcut(key, modifiers: [])
    }

    @ViewBuilder private var notices: some View {
        if let error = app.configError {
            Text("Конфиг не прочитан: \(error)").font(Ink.body).foregroundStyle(Ink.alert)
        }
        // Связь с Exchange — внизу, у индикатора: короткой фразой и во всплывашке.
    }

    /// Короткая фраза у индикатора — в одну строку, влезает всегда: связи давно нет или день за окном не
    /// обновляется. Подробности — во всплывашке индикатора.
    private var trouble: String? {
        if app.window.contains(app.shownDay), let outage = app.currentOutage { return "Нет связи с \(staleTime(outage.since))" }
        if !app.window.contains(app.shownDay), let stale = app.freshness(of: app.shownDay) { return "День не обновлён с \(staleTime(stale.since))" }
        return nil
    }

    /// `13:40`, а если данные не сегодняшние — `21 окт 13:40`.
    private func staleTime(_ date: Date) -> String {
        guard dayString(date) != today() else { return hhmm(date) }
        return date.formatted(.dateTime.day().month(.abbreviated).locale(Locale(identifier: "ru_RU"))) + " " + hhmm(date)
    }
}

/// «Загрузка…» по центру — только если ответа нет дольше полсекунды: быстрый ответ Exchange не должен
/// мелькать надписью.
private struct Loading: View {
    @SwiftUI.State private var shown = false

    var body: some View {
        Text("Загрузка…").font(Ink.title).foregroundStyle(Ink.secondary).opacity(shown ? 1 : 0)
            .task {
                try? await Task.sleep(for: .milliseconds(500))
                shown = true
            }
    }
}

/// «Чт, 22 октября» из `YYYY-MM-DD`.
func dayTitle(_ day: String) -> String? {
    let parser = DateFormatter()
    parser.dateFormat = "yyyy-MM-dd"
    guard let date = parser.date(from: day) else { return nil }
    let text = date.formatted(.dateTime.weekday(.abbreviated).day().month(.wide).locale(Locale(identifier: "ru_RU")))
    return text.prefix(1).uppercased() + text.dropFirst()
}

/// Кнопки напоминания в заголовке, справа от даты, — пока встреча звенит или я на неё опаздываю:
/// «ОК» (понял, больше не звенеть), главная кнопка «Отложить на 5 мин» с индикатором автоповтора и
/// выпадающий список редких действий, в том числе «Пропустить».
struct ReminderBar: View {
    @Bindable var app: App

    var body: some View {
        HStack(spacing: 6) {
            Button { app.acknowledge() } label: {
                Text("ОК").fontWeight(.semibold).foregroundStyle(Ink.primary).padding(.horizontal, 10).padding(.vertical, 3)
            }
            .buttonStyle(Hover(padding: 0))
            .plate()
            .help("Понял — больше не напоминать")
            snooze
        }
        .font(Ink.body)
        .lineLimit(1)
    }

    private var snooze: some View {
        HStack(spacing: 0) {
            Button { app.snooze(5) } label: {
                TimelineView(.animation) { context in
                    Text("Отложить на 5 мин")
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(alignment: .leading) {
                            GeometryReader { g in
                                Rectangle()
                                    .fill(ink(0xFFC873))
                                    .frame(width: g.size.width * app.autoSnoozeProgress(at: context.date))
                            }
                        }
                }
            }
            .buttonStyle(Hover(padding: 0))
            Divider().frame(height: 16)
            Button { app.menuOpen.toggle() } label: {
                Image(systemName: "chevron.down").padding(.horizontal, 6).padding(.vertical, 3)
            }
            .buttonStyle(Hover(padding: 0))
            .popover(isPresented: $app.menuOpen, arrowEdge: .bottom) { menu }
        }
        .foregroundStyle(Ink.primary)
        .plate()
    }

    private var menu: some View {
        VStack(alignment: .leading, spacing: 2) {
            item("Отложить на 10 мин") { app.snooze(10) }
            item("Отложить на 15 мин") { app.snooze(15) }
            Divider().padding(.vertical, 4)
            ForEach(app.pending) { m in
                item("Пропустить «\(m.subject)»") { app.skip(m) }
            }

        }
        .padding(8)
        .frame(minWidth: 260)
    }

    private func item(_ title: String, action: @escaping () -> Void) -> some View {
        Button {
            app.menuOpen = false
            action()
        } label: {
            Text(title).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
        }
        .buttonStyle(Hover(padding: 6))
    }
}

extension View {
    /// Плашка кнопок напоминания: светлая заливка, тонкая рамка, скруглённые углы — одна на всех.
    func plate() -> some View {
        background(ink(0xFFF6E8))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(ink(0xE3CBA6)))
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// Кнопка без рамки, которая заметно темнеет под мышью и ещё сильнее — при нажатии; недоступная — серая.
struct Hover: ButtonStyle {
    var padding: CGFloat = 3

    func makeBody(configuration: Configuration) -> some View {
        Face(configuration: configuration, padding: padding)
    }

    private struct Face: View {
        let configuration: Configuration
        let padding: CGFloat
        @SwiftUI.State private var hovering = false
        /// Недоступная кнопка — серая и не подсвечивается: иначе кажется, что она сломана.
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            // Цвет доступной кнопки задаёт тот, кто её поставил; недоступная — всегда серая.
            Group {
                if isEnabled { configuration.label } else { configuration.label.foregroundStyle(Ink.faded) }
            }
                .padding(.horizontal, padding)
                .padding(.vertical, padding / 2)
                .background(RoundedRectangle(cornerRadius: 4)
                    .fill(.black.opacity(!isEnabled ? 0 : configuration.isPressed ? 0.18 : hovering ? 0.09 : 0)))
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}

@MainActor private let timeFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm"
    return f
}()

@MainActor func hhmm(_ date: Date) -> String {
    timeFormatter.string(from: date)
}

