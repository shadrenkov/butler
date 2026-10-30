import AppKit
import Observation

/// Строка меню, секундный тик и связывание всего: расписание → напоминания → окно и звук.
@main
@MainActor
@Observable
final class App: NSObject, NSApplicationDelegate {
    var config = Config()
    var configError: String?
    var state = State.load()
    var meetings: [Meeting] = []
    var reminding: [Meeting] = []
    var late: [Meeting] = []
    /// О чём кнопки напоминания в заголовке: звенящие встречи, а когда они отложены — те, на которые
    /// опаздываю и про которые ещё не нажато «ОК».
    var pending: [Meeting] = []
    var next: Meeting?
    var now = currentTime()
    /// Какой день показан в окне (`YYYY-MM-DD`) и расписания дней за окном кэша, уже полученные.
    var shownDay = today() {
        // Карточка дня сдвигается по стопке — тень прозрачного окна пересчитывается после сдвига.
        didSet { DispatchQueue.main.async { [weak self] in self?.panel?.invalidateShadow() } }
    }
    var days: [String: Day] = [:]
    /// Когда получены расписания других дней и чем кончился последний неудачный запрос каждого.
    var daysAt: [String: Date] = [:]
    var dayErrors: [String: String] = [:]
    /// Дни, которые сейчас перечитываются: пока ответа нет, прежние ошибка и возраст данных не в счёт —
    /// иначе при листании дней мелькало бы красное предупреждение.
    var loading: Set<String> = []
    /// Встреча, которую Butler сейчас открывает в МТС Линк, — её карточка и иконка в строке меню
    /// показывают это анимацией.
    var opening: String?
    /// Отсчёт до автооткрытия МТС Линк — на камерах этих встреч и на иконке в строке меню.
    var linkCountdown: (ids: Set<String>, progress: Double)?
    /// Когда окно начало звенеть — от этого момента через 30 с срабатывает «Отложить на 5 мин».
    var ringingSince: Date?
    /// Когда прозвучал первый звук напоминания: от него в такт пульсирует кнопка подключения.
    var chimeAt: Date?
    /// Открыты ли настройки — карточка поверх стопки дней.
    var settingsOpen = false {
        // Тень прозрачного окна macOS сама не пересчитывает: карточка легла или снята — по новой форме.
        didSet { DispatchQueue.main.async { [weak self] in self?.panel?.invalidateShadow() } }
    }
    /// Какое всплывающее окно открыто поверх настроек: VIP-контакты, скрытые встречи или ящики.
    var dialog: Dialog?
    /// Календарь на месяц: лежит ли он на стопке, с какого месяца открыт — от него считается стопка
    /// месяцев, — какой месяц сверху и какой день выбран.
    var monthOpen = false {
        didSet { DispatchQueue.main.async { [weak self] in self?.panel?.invalidateShadow() } }
    }
    var firstMonth = monthOf(today())
    var shownMonth = monthOf(today()) {
        didSet { DispatchQueue.main.async { [weak self] in self?.panel?.invalidateShadow() } }
    }
    var selectedDay = today()
    /// Прочитанные месяцы — в памяти, как дни за окном, и идущее чтение — для индикатора.
    var months: [String: MonthRead] = [:]
    var monthLoad: MonthLoad?
    /// Когда началась последняя проверка расписания и с какого момента идёт обращение к Exchange — для колечка
    /// вокруг точки связи.
    var polledAt: Date?
    var syncingSince: Date?
    /// Открыта ли всплывашка индикатора связи — её открывает и сам Butler, когда связь пропала.
    var connectionDetails = false
    /// Пока выпадающий список открыт, автоповтор стоит.
    var menuOpen = false {
        didSet {
            guard let since = ringingSince, menuOpen != oldValue else { return }
            if menuOpen { pausedFor = currentTime().timeIntervalSince(since) } else { ringingSince = currentTime() - pausedFor }
        }
    }

    /// Пароли ящиков — из текста ящиков в `config.json`; пустой пароль — пароля нет.
    var passwords: [String: String] {
        Dictionary(config.mailboxes.filter { !$0.password.isEmpty }.map { ($0.address, $0.password) }, uniquingKeysWith: { first, _ in first })
    }
    /// Сообщение о потере связи этого эпизода уже показано: окно открывается само один раз за эпизод.
    @ObservationIgnored private var announced = false
    @ObservationIgnored private var refreshing = false
    /// Ящики, которые читаются прямо сейчас: «Проверить снова», сохранение ящиков и расписание не должны
    /// читать один ящик дважды одновременно.
    @ObservationIgnored private var reading: Set<String> = []
    @ObservationIgnored private var reminders = Reminders()
    @ObservationIgnored private var pausedFor: TimeInterval = 0
    @ObservationIgnored private var prepared: Set<String> = []
    @ObservationIgnored private var nextPrepare = Date.distantPast
    /// Встречи, которые Butler открыл сам: их МТС Линк занимает микрофон ещё до начала, это не звонок.
    @ObservationIgnored private var autoOpened: Set<String> = []
    /// С какого момента идёт анимация открытия и начинается ли она с «тк-тк»; кадры для иконки.
    @ObservationIgnored private var openingSince = Date.distantPast
    @ObservationIgnored private var knocking = false
    @ObservationIgnored private var frames: Timer?
    @ObservationIgnored private let alarm = Alarm()
    /// Первые встречи сегодня и завтра, если дни рабочие, — для будильника; собираются раз в минуту.
    @ObservationIgnored private var firsts: [Meeting] = []
    @ObservationIgnored private var firstsMinute = 0
    @ObservationIgnored private var statusItem: NSStatusItem!
    @ObservationIgnored private var panel: Panel!

    static func main() {
        if CommandLine.arguments.contains("--sounds") { return playSounds() }
        if let i = CommandLine.arguments.firstIndex(of: "--dump"), i + 1 < CommandLine.arguments.count {
            return dump(CommandLine.arguments[i + 1])
        }
        offlineMode = CommandLine.arguments.contains("--offline")
        guard takeLock() else {
            print("Butler уже запущен — вторая копия не нужна: она удвоила бы запросы к Exchange")
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--now"), i + 1 < CommandLine.arguments.count {
            let parser = DateFormatter()
            parser.dateFormat = "yyyy-MM-dd'T'HH:mm"
            if let date = parser.date(from: CommandLine.arguments[i + 1]) { clockShift = date.timeIntervalSinceNow }
        }
        let app = App()
        NSApplication.shared.delegate = app
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.run()
    }

    /// `make sounds`: звук «у компьютера», затем «не у компьютера» — по умолчанию, чтобы сверить на слух.
    private static func playSounds() {
        let alarm = Alarm()
        alarm.ring(.atDesk, Config())
        Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { _ in MainActor.assumeIsolated { alarm.ring(.away, Config()) } }
        Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { _ in
            MainActor.assumeIsolated { alarm.stopLoud() }
            exit(0)
        }
        RunLoop.main.run()
    }

    /// Одна копия Butler на пользователя: две удвоили бы обращения к боевому Exchange и переписывали бы
    /// друг другу `state.json`. Блокировку держит процесс — как бы он ни упал, система её снимет.
    nonisolated(unsafe) private static var lock: Int32 = -1

    private static func takeLock() -> Bool {
        let url = URL.applicationSupportDirectory.appending(path: "Butler/butler.lock")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        lock = open(url.path, O_CREAT | O_RDWR, 0o600)
        return lock >= 0 && flock(lock, LOCK_EX | LOCK_NB) == 0
    }

    /// `--dump YYYY-MM-DD`: день, собранный из кэша, в JSON. Без сети и без окна.
    private static func dump(_ day: String) {
        let config = Config.load().0
        let events = assemble(State.load().calendar, order: config.mailboxes.map(\.address), day: day, config: config)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        print(String(decoding: try! encoder.encode(Day(date: day, events: events)), as: UTF8.self))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Пароль открытым текстом — от прежней версии или вписанный руками — шифруется при запуске.
        (config, configError) = Config.change { json in
            guard let list = json["mailboxes"] as? [[String: Any]] else { return }
            json["mailboxes"] = list.map { m in var m = m; m["password"] = (m["password"] as? String).map(sealed); return m }
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "calendar", accessibilityDescription: "Butler")
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePanel)
        panel = Panel(app: self, content: DayView(app: self))

        // Кэш — сразу, ещё до сервера.
        meetings = visible(assembled(today()))
        startPolling { [weak self] wake in Task { await self?.refresh(wake: wake) } }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        writePicture()
    }

    /// `--picture day|month|settings файл`: карточка в PNG — скриншоты для README (`make screens`). Через
    /// полторы секунды: к этому времени месяц прочитан, а напоминание уже зазвенело.
    private func writePicture() {
        let arguments = CommandLine.arguments
        guard let i = arguments.firstIndex(of: "--picture"), i + 2 < arguments.count else { return }
        let (card, file) = (arguments[i + 1], URL(fileURLWithPath: arguments[i + 2]))
        if card == "month" { openMonth() }
        if card == "settings" {
            settingsOpen = true
            panel.showAlert(soft: false)
        }
        Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                try? (card == "settings" ? self?.panel.settingsPNG() : self?.panel.cardPNG())?.write(to: file)
                exit(0)
            }
        }
    }

    /// Раз в минуту, после сна и в полночь: каждый ящик, которому пора, читается заново — окно «сегодня и
    /// 7 дней вперёд». Пора ли, решает `isDue`: обычно раз в 10 минут, после сбоя — по его правилу.
    private func refresh(wake: Bool = false) async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        polledAt = .now
        state.calendar = state.calendar.filter { address, _ in config.mailboxes.contains { $0.address == address } }
        let now = Date.now
        let due = config.mailboxes.filter {
            isDue(state.calendar[$0.address], hasPassword: passwords[$0.address] != nil, now: now, wake: wake)
        }
        // Между чтениями окна — сегодня раз в минуту, только у ящиков на связи: сбой ждёт своего срока.
        let checks = config.mailboxes.filter { m in
            guard !due.contains(m), let box = state.calendar[m.address], box.failure == nil, box.windowAt != nil else { return false }
            return currentTime().timeIntervalSince(box.success ?? .distantPast) >= 50
        }
        if !due.isEmpty || !checks.isEmpty {
            syncingSince = .now
            await read(due)
            await read(checks, onlyToday: true)
            syncingSince = nil
            state.save()
        }
        meetings = visible(assembled(today()))
        if !isShowingToday { show(shownDay) }
        if let tomorrow = window.dropFirst().first { loadWorkdays(String(tomorrow.prefix(4))) }
        tick()
    }

    /// Прочитать окно ящиков (или только сегодня) параллельно и положить результат в кэш.
    private func read(_ mailboxes: [Mailbox], onlyToday: Bool = false) async {
        let mailboxes = mailboxes.filter { !reading.contains($0.address) }
        reading.formUnion(mailboxes.map(\.address))
        defer { reading.subtract(mailboxes.map(\.address)) }
        let first = today()
        guard let (from, end) = bounds(first), let last = window.last, let to = bounds(last)?.end else { return }
        let reads = mailboxes.map { m in
            let (password, box) = (passwords[m.address], state.calendar[m.address] ?? Box())
            return (m.address, Task {
                await Butler.read(m, password: password, from: from, to: onlyToday ? end : to, days: onlyToday ? nil : first...last, box: box)
            })
        }
        for (address, task) in reads { state.calendar[address] = await task.value }
    }

    /// «Проверить снова», новый пароль, изменённые настройки ящика: остановка снимается, и ровно одно обращение.
    func recheck(_ address: String) {
        guard let m = config.mailboxes.first(where: { $0.address == address }) else { return }
        var box = state.calendar[address] ?? Box()
        (box.failure, box.retryAt, box.failingSince, box.failures) = (nil, nil, nil, 0)
        state.calendar[address] = box
        Task {
            await read([m])
            state.save()
            meetings = visible(assembled(today()))
            tick()
        }
    }

    /// Сохранить текст ящиков: удалённые уходят вместе со встречами, новые и изменённые (в том числе новый пароль) проверяются
    /// одним обращением, нетронутые не трогаются. Возвращает ошибку или `nil`.
    func saveMailboxes(_ text: String) -> String? {
        let new: [Mailbox]
        do { new = try mailboxes(from: text) } catch { return error.localizedDescription }
        guard configError == nil else { return "config.json не читается" }
        let old = config.mailboxes
        (config, configError) = Config.change { json in
            json["mailboxes"] = new.map { ["address": $0.address, "login": $0.login, "server": $0.server, "password": sealed($0.password)] }
        }
        if let configError { return configError }
        let removed = old.filter { m in !new.contains { $0.address == m.address } }
        if !removed.isEmpty {
            for m in removed { state.calendar[m.address] = nil }
            state.save()
        }
        for m in new where !old.contains(m) { recheck(m.address) }
        meetings = visible(assembled(today()))
        tick()
        return nil
    }

    /// Дни окна, которое читается из Exchange: сегодня и 7 дней вперёд.
    var window: [String] {
        (0...7).compactMap { Calendar.current.date(byAdding: .day, value: $0, to: currentTime()).map(dayString) }
    }

    /// День из кэшей ящиков — без скрытых.
    private func assembled(_ day: String) -> [Meeting] {
        assemble(state.calendar, order: config.mailboxes.map(\.address), day: day, config: config)
    }

    /// Почему нет расписания: ящиков нет или ни один ещё не ответил.
    var scheduleError: String? {
        if config.mailboxes.isEmpty { return "нет ящиков — задайте их в настройках" }
        return config.mailboxes.compactMap { state.calendar[$0.address]?.failure }.first.map(\.text)
    }

    /// Получено ли хоть что-то хоть из одного ящика — иначе пустой день — это не «свободный день».
    private var hasSchedule: Bool {
        config.mailboxes.contains { state.calendar[$0.address]?.success != nil }
    }

    /// Сколько индикатора автоповтора уже заполнено: от 0 до 1 за 30 секунд.
    func autoSnoozeProgress(at date: Date) -> Double {
        guard let ringingSince else { return 0 }
        let elapsed = menuOpen ? pausedFor : date.timeIntervalSince(ringingSince)
        return min(max(elapsed / 30, 0), 1)
    }

    /// Раз в секунду: напоминания, будильник, автооткрытие и часы в строке меню — по точному времени. Наблюдаемые
    /// поля меняются, только когда значение другое, а `now` — раз в минуту: окну хватает минут, встречи начинаются
    /// и кончаются в целые минуты. Иначе окно, даже спрятанное, перерисовывалось бы каждую секунду.
    private func tick() {
        let time = currentTime()
        if Int(time.timeIntervalSince1970 / 60) != Int(now.timeIntervalSince1970 / 60) { now = time }
        let current = reminders.reminding(meetings, now: time, state: state, config: config)
        let started = Set(current.map(\.id)).subtracting(reminding.map(\.id))
        let late = reminders.late(meetings, now: time, state: state)
        let pending = current.isEmpty ? late : current
        if reminding != current { reminding = current }
        if self.late != late { self.late = late }
        if self.pending != pending { self.pending = pending }
        let next = countdownTarget(meetings, now: time, state: state)
        if self.next != next { self.next = next }
        if Int(time.timeIntervalSince1970 / 60) != firstsMinute, let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: time) {
            firstsMinute = Int(time.timeIntervalSince1970 / 60)
            firsts = [time, tomorrow].map(dayString).filter { !nonWorking($0, workdays: state.workdays) }
                .compactMap { firstMeeting(visible(assembled($0)), state: state) }
        }

        if current.isEmpty {
            ringingSince = nil
            chimeAt = nil
            menuOpen = false
            alarm.stopLoud()
        } else if !started.isEmpty {
            ringingSince = time
            shownDay = today()
            settingsOpen = false
            dialog = nil
            monthOpen = false
            // Звонок важнее присутствия: в нём я у компьютера, даже если давно не трогал мышь. Встреча,
            // которую Butler открыл сам, занимает микрофон без меня — МТС Линк тогда не в счёт.
            let ownLink = !started.isDisjoint(with: autoOpened)
            let situation: Situation = MTSLink.isCallActive(ignoringLink: ownLink) ? .inCall
                : alarm.isPresent(after: config.awayAfterMinutes) ? .atDesk : .away
            // Сначала окно, через секунду — звук и первый толчок пульса кнопки подключения.
            panel.showAlert(soft: situation != .away)
            chimeAt = time + 1
            Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, !self.reminding.isEmpty else { return }
                    self.alarm.ring(situation, self.config)
                }
            }
        } else if autoSnoozeProgress(at: time) >= 1 {
            reminders.snooze(current, minutes: 5, now: time, byUser: false)
            tick()
            if reminding.isEmpty { panel.orderOut(nil) }
            return
        } else if alarm.isLoud && alarm.isPresent(after: config.awayAfterMinutes) {
            alarm.stopLoud()
        }
        announceOutage()
        let lead = config.autoOpenSeconds + MTSLink.warning
        let countdown = config.autoOpenMTSLink
            ? MTSLink.countdown(meetings, now: time, state: state, lead: lead, prepared: prepared) : nil
        if countdown?.ids != linkCountdown?.ids || countdown?.progress != linkCountdown?.progress { linkCountdown = countdown }
        showClock()
        // Первая попытка — ровно в срок, а пока микрофон занят — раз в 10 секунд.
        if config.autoOpenMTSLink && time >= nextPrepare {
            if let chosen = MTSLink.prepare(meetings, now: time, state: state, lead: lead, prepared: &prepared) {
                autoOpen(chosen)
            } else if linkCountdown?.progress == 1 {
                nextPrepare = time + 10
            }
        }
    }

    /// Тревога связи с Exchange сейчас: ящик остановлен или сбой длится 10 минут.
    var currentOutage: (since: Date, lines: [String])? {
        outage(state.calendar, mailboxes: config.mailboxes, now: .now)
    }

    /// Связи нет 10 минут (остановка — сразу): окно один раз за эпизод открывается само, без звука, с открытой
    /// всплывашкой индикатора. Эпизод кончается, когда все ящики снова ответили.
    private func announceOutage() {
        if !config.mailboxes.contains(where: { [nil, .noPassword].contains(state.calendar[$0.address]?.failure) == false }) {
            announced = false
        }
        guard !announced, currentOutage != nil else { return }
        announced = true
        guard !panel.isVisible else { return }
        show(today())
        panel.showAlert(soft: false)
        connectionDetails = true
    }

    /// Отсчёт до следующей встречи, а при опоздании — мигающий минус; перед ним красный «VIP».
    /// Строка меню перекрашивает цветной текст и значки в свой цвет, поэтому, когда нужен красный
    /// («VIP», опоздание), значок и часы рисуются одной цветной картинкой.
    private func showClock() {
        guard let button = statusItem.button else { return }
        // Отсчёт — с секундами, поэтому по точному времени, а не по поминутному `now`.
        let now = currentTime()
        guard let clock = clock(late: late, next: next, now: now) else {
            button.image = statusImage(color: nil)
            button.title = ""
            // Будильник — вместо календаря, но не вместо аварийного значка и камеры МТС Линк. Мигает
            // время: прозрачное на нечётных секундах, ширина не прыгает. Со вторым поясом время — по нему
            // и его голубым, поэтому одной цветной картинкой.
            if let wake = wakeUp(firsts, now: now, config: config), currentOutage == nil, opening == nil, linkCountdown == nil,
               let alarm = NSImage(systemSymbolName: "alarm", accessibilityDescription: "Первая встреча") {
                let home = config.showHomeTime
                var digits: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular),
                ]
                if home { digits[.foregroundColor] = menuBlue }
                if wake.blinks && Int(now.timeIntervalSince1970) % 2 == 1 { digits[.foregroundColor] = NSColor.clear }
                guard home else {
                    button.image = alarm
                    button.attributedTitle = NSAttributedString(string: " " + hhmm(wake.start), attributes: digits)
                    return
                }
                let icon = alarm.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.labelColor])) ?? alarm
                button.image = picture(icon, NSAttributedString(string: " " + homeTime(wake.start, config: config), attributes: digits))
            }
            return
        }
        let size = NSFont.menuBarFont(ofSize: 0).pointSize
        let title = NSMutableAttributedString()
        if clock.isVIP {
            title.append(NSAttributedString(string: " VIP", attributes: [
                .font: NSFont.systemFont(ofSize: size * 0.75, weight: .heavy),
                .foregroundColor: menuRed,
            ]))
        }
        var digits: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular)]
        // Опоздание — красные значок и цифры; цифры мигают, прозрачные на нечётных секундах — ширина не прыгает.
        if clock.isLate { digits[.foregroundColor] = Int(now.timeIntervalSince1970) % 2 == 1 ? NSColor.clear : menuRed }
        guard clock.isLate || clock.isVIP else {
            button.image = statusImage(color: nil)
            button.attributedTitle = NSAttributedString(string: " " + clock.text, attributes: digits)
            return
        }
        if !clock.isLate { digits[.foregroundColor] = NSColor.labelColor }
        title.append(NSAttributedString(string: " " + clock.text, attributes: digits))
        button.image = picture(statusImage(color: clock.isLate ? menuRed : .labelColor), title)
        button.title = ""
    }

    private func picture(_ icon: NSImage, _ title: NSAttributedString) -> NSImage {
        let text = title.size()
        let size = NSSize(width: ceil(icon.size.width + text.width), height: max(icon.size.height, ceil(text.height)))
        let image = NSImage(size: size, flipped: false) { rect in
            icon.draw(in: NSRect(x: 0, y: (rect.height - icon.size.height) / 2, width: icon.size.width, height: icon.size.height))
            title.draw(at: NSPoint(x: icon.size.width, y: (rect.height - text.height) / 2))
            return true
        }
        image.isTemplate = false
        return image
    }

    /// Календарь, а пока Butler готовится сам открыть МТС Линк, — камера в кольце отсчёта. Когда
    /// срок пришёл, кружок с камерой мигает в такт «тк-тк», а пока Butler открывает встречу — кольцо
    /// вращается, как на карточке.
    /// `color` — цветная картинка; `nil` — шаблон, который строка меню красит сама.
    private func statusImage(color: NSColor?) -> NSImage {
        let since = Date().timeIntervalSince(openingSince)
        let flash = opening != nil && knocking && Sound.knock.notes.indices.contains {
            (0..<0.09).contains(since - Double($0) * Sound.knock.step)
        }
        // Сколько уже вращается кольцо открытия: до конца «тк-тк» — меньше нуля, кольцо полное.
        let spin = opening == nil ? -1 : since - (knocking ? Sound.knock.length : 0)
        guard let progress = opening != nil ? 1 : linkCountdown?.progress else {
            // Связи с Exchange давно нет — значок аварийный, красный, что бы ни просили.
            if currentOutage != nil, let alarm = NSImage(systemSymbolName: "calendar.badge.exclamationmark", accessibilityDescription: "Нет связи с Exchange") {
                let red = alarm.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [menuRed])) ?? alarm
                red.isTemplate = false
                return red
            }
            let calendar = NSImage(systemSymbolName: "calendar", accessibilityDescription: "Butler")!
            return color.flatMap { calendar.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [$0])) } ?? calendar
        }
        let ink = color ?? .black
        let camera = NSImage(systemSymbolName: "video.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 7, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [ink])))
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let center = NSPoint(x: rect.midX, y: rect.midY)
            let ring = rect.insetBy(dx: 1.5, dy: 1.5)
            if flash {
                ink.setFill()
                NSBezierPath(ovalIn: rect.insetBy(dx: 0.75, dy: 0.75)).fill()
            } else {
                ink.withAlphaComponent(0.3).setStroke()
                let track = NSBezierPath(ovalIn: ring)
                track.lineWidth = 1.5
                track.stroke()
                ink.setStroke()
                // Отсчёт — дуга растёт от верха по часовой; открытие — дуга в 70 % оборачивается раз в секунду.
                let from = spin > 0 ? 90 - 360 * spin : 90
                let arc = NSBezierPath()
                arc.appendArc(withCenter: center, radius: ring.width / 2, startAngle: from,
                              endAngle: from - 360 * (spin > 0 ? 0.7 : progress), clockwise: true)
                arc.lineWidth = 1.5
                arc.lineCapStyle = .round
                arc.stroke()
            }
            if let camera {
                camera.draw(in: NSRect(x: center.x - camera.size.width / 2, y: center.y - camera.size.height / 2,
                                       width: camera.size.width, height: camera.size.height),
                            from: .zero, operation: flash ? .destinationOut : .sourceOver, fraction: 1)
            }
            return true
        }
        image.isTemplate = color == nil
        return image
    }

    var isShowingToday: Bool { shownDay == today() }

    /// Встречи показанного дня; `nil` — его расписание ещё не получено. Дни окна — из кэша ящиков.
    var shownMeetings: [Meeting]? {
        if isShowingToday { return hasSchedule ? meetings : nil }
        if window.contains(shownDay) { return hasSchedule ? visible(assembled(shownDay)) : nil }
        return days[shownDay]?.events
    }

    /// Показать день со сдвигом от показанного: −1 — предыдущий, +1 — следующий.
    func shift(_ offset: Int) {
        if let day = day(shownDay, plus: offset) { show(day) }
    }

    private func day(_ day: String, plus offset: Int) -> String? {
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        return parser.date(from: day).flatMap { Calendar.current.date(byAdding: .day, value: offset, to: $0) }.map(dayString)
    }

    /// День окна берётся из кэша; день за окном читается из Exchange — не чаще раза в 10 минут и только из
    /// ящиков, у которых всё в порядке: остановленный или ждущий конца троттлинга ящик не трогается.
    func show(_ day: String) {
        shownDay = day
        guard !window.contains(day), currentTime().timeIntervalSince(daysAt[day] ?? .distantPast) > 600,
              let (from, to) = bounds(day) else { return }
        // День из свежего месяца — без своего чтения.
        if let read = monthRead(day), read.failure == nil, currentTime().timeIntervalSince(read.at) < 600 {
            days[day] = Day(date: day, events: visible(assemble(read.boxes, order: config.mailboxes.map(\.address), day: day, config: config)))
            (daysAt[day], dayErrors[day]) = (read.at, nil)
            return
        }
        if let failure = config.mailboxes.compactMap({ state.calendar[$0.address]?.failure }).first(where: { $0 != .noPassword }) {
            dayErrors[day] = failure.text
            return
        }
        loading.insert(day)
        dayErrors[day] = nil
        // Время попытки, а не удачи: неудачное чтение тоже не повторяется раньше чем через 10 минут.
        daysAt[day] = currentTime()
        Task {
            defer { loading.remove(day) }
            var boxes: [String: Box] = [:]
            for m in config.mailboxes {
                let box = await Butler.read(m, password: passwords[m.address], from: from, to: to, days: day...day, box: Box())
                if let failure = box.failure, failure != .noPassword {
                    dayErrors[day] = failure.text
                    return
                }
                boxes[m.address] = box
            }
            days[day] = Day(date: day, events: visible(assemble(boxes, order: config.mailboxes.map(\.address), day: day, config: config)))
            daysAt[day] = currentTime()
        }
    }

    // Календарь на месяц.

    /// Щелчок по дате: поверх дня ложится месяц показанного дня, этот день выбран.
    func openMonth() {
        firstMonth = monthOf(shownDay)
        showMonth(firstMonth, selecting: shownDay)
        monthOpen = true
    }

    /// «Готово» и Escape: месяцы сняты, показан прежний день.
    func closeMonth() {
        monthOpen = false
    }

    /// Провалиться в день: месяцы сняты, сверху выбранный день.
    func openDay(_ day: String) {
        monthOpen = false
        show(day)
    }

    /// Щелчок по дню: выбранный открывается, другой выбирается — двойной щелчок поэтому открывает любой.
    func select(_ day: String) {
        if day == selectedDay { openDay(day) } else { selectedDay = day }
    }

    /// Стрелки на месяце: выбран соседний день или тот же день соседней недели, за краем месяца перелистывается и месяц.
    func moveSelection(_ offset: Int) {
        guard let day = day(selectedDay, plus: offset) else { return }
        selectedDay = day
        if monthOf(day) != shownMonth { showMonth(monthOf(day)) }
    }

    func shiftMonth(_ offset: Int) {
        showMonth(Butler.shiftMonth(shownMonth, by: offset))
    }

    /// Показать месяц сверху стопки и при надобности прочитать его и производственный календарь года.
    func showMonth(_ month: String, selecting day: String? = nil) {
        shownMonth = month
        if let day { selectedDay = day }
        readMonth(month)
        loadWorkdays(String(month.prefix(4)))
    }

    /// Получить производственный календарь года, если пора: он нужен месяцу и будильнику.
    private func loadWorkdays(_ year: String) {
        Task {
            if let workdays = await fetchWorkdays(year, state: state) {
                state.workdays[year] = workdays
                state.save()
            }
        }
    }

    /// Встречи дня для месяца: день окна — из кэша окна, остальные — из прочитанного месяца; `nil` — данных нет.
    func monthMeetings(_ day: String) -> [Meeting]? {
        if window.contains(day) && hasSchedule { return visible(assembled(day)) }
        guard let read = monthRead(day) else { return nil }
        return visible(assemble(read.boxes, order: config.mailboxes.map(\.address), day: day, config: config))
    }

    /// Самое свежее чтение, захватившее день: чтение месяца покрывает его сетку, поэтому день с края —
    /// ещё и в чтении соседнего месяца.
    private func monthRead(_ day: String) -> MonthRead? {
        months.values.filter { !$0.boxes.isEmpty && $0.days?.contains(day) == true }.max { $0.at < $1.at }
    }

    /// Есть ли у дня свежие встречи: в окне или в чтении месяца не старше 10 минут.
    private func isFresh(_ day: String) -> Bool {
        if window.contains(day) && hasSchedule { return true }
        guard let read = monthRead(day) else { return false }
        return read.failure == nil && currentTime().timeIntervalSince(read.at) < 600
    }

    /// Прочитать месяц одним чтением на ящик: не чаще раза в 10 минут, не во время сбоя связи и
    /// не тот ящик, что уже читается. Затравка — известные встречи: `GetItem` идёт только за новыми.
    /// Читаются только дни сетки без свежих встреч — от первого такого до последнего: края, уже прочитанные
    /// с соседним месяцем, и окно не перечитываются.
    private func readMonth(_ month: String) {
        let days = grid(month).joined().filter { !isFresh($0) }
        guard currentTime().timeIntervalSince(months[month]?.at ?? .distantPast) > 600, monthLoad == nil,
              let first = days.first, let last = days.last, let from = bounds(first)?.start, let to = bounds(last)?.end
        else { return }
        // Время попытки не ставится: сбой пройдёт — месяц прочитается при следующем показе.
        if let failure = config.mailboxes.compactMap({ state.calendar[$0.address]?.failure }).first(where: { $0 != .noPassword }) {
            months[month, default: MonthRead(at: .distantPast)].failure = failure
            return
        }
        let mailboxes = config.mailboxes.filter { !reading.contains($0.address) && passwords[$0.address] != nil }
        guard !mailboxes.isEmpty else { return }
        reading.formUnion(mailboxes.map(\.address))
        months[month, default: MonthRead(at: .distantPast)].at = currentTime()
        months[month]?.failure = nil
        monthLoad = MonthLoad(month: month, started: .now, reads: Dictionary(uniqueKeysWithValues: mailboxes.map { ($0.address, MonthLoad.Read()) }))
        let reads = mailboxes.map { m in
            let seed = Box(events: (state.calendar[m.address]?.events ?? []) + (months[month]?.boxes[m.address]?.events ?? []))
            return (m.address, Task {
                await Butler.read(m, password: passwords[m.address], from: from, to: to, days: first...last, box: seed) {
                    [weak self] stale, fetched in self?.step(m.address, stale: stale, fetched: fetched)
                }
            })
        }
        Task {
            var boxes = months[month]?.boxes ?? [:]
            var failure: Failure?
            for (address, task) in reads {
                let box = await task.value
                if let f = box.failure, f != .noPassword { failure = f } else { boxes[address] = box }
            }
            reading.subtract(mailboxes.map(\.address))
            // Дни и встречи меняются вместе: иначе прежние встречи сочтутся встречами нового диапазона.
            if failure == nil {
                months[month]?.boxes = boxes
                months[month]?.days = first...last
            }
            months[month]?.failure = failure
            if failure == nil, let load = monthLoad {
                state.loadStats.add(load, now: .now)
                state.save()
            }
            monthLoad = nil
            // Пока читался этот, могли перелистнуть на другой — он своё чтение пропустил.
            if monthOpen { readMonth(shownMonth) }
        }
    }

    /// Шаг чтения месяца по ящику — для индикатора. Показанная доля запоминается: полоска не откатывается.
    private func step(_ address: String, stale: Int, fetched: Int) {
        guard var load = monthLoad else { return }
        let now = Date.now
        if let guess = estimate(elapsed: now.timeIntervalSince(load.started), reads: Array(load.reads.values),
                                stats: state.loadStats, shown: load.shown) {
            load.shown = guess
        }
        var read = load.reads[address] ?? MonthLoad.Read()
        if read.stale == nil { read.listedAt = now }
        (read.stale, read.fetched) = (stale, fetched)
        if fetched >= stale { read.doneAt = now }
        load.reads[address] = read
        monthLoad = load
    }

    /// «Отметить день»: кружок вокруг числа включается и выключается.
    func toggleMark(_ day: String) {
        guard configError == nil else { return }
        (config, configError) = Config.change { json in
            let marked = Set(json["markedDays"] as? [String] ?? [])
            json["markedDays"] = (marked.contains(day) ? marked.subtracting([day]) : marked.union([day])).sorted()
        }
    }

    /// Сегодня всё закончилось — окно открывается на ближайшем дне окна со встречами, а нет такого — на завтра.
    private func showNextDayWithMeetings() {
        let rest = window.dropFirst()
        show(rest.first { day in visible(assembled(day)).contains { !$0.isAllDay } } ?? rest.first ?? today())
    }

    @objc private func togglePanel() {
        if !panel.isVisible, let button = statusItem.button {
            show(today())
            if reminding.isEmpty && !meetings.contains(where: { !$0.isAllDay && $0.end > currentTime() }) { showNextDayWithMeetings() }
            panel.showFromMenu(button)
        } else if reminding.isEmpty {
            panel.orderOut(nil)
        } else {
            close()
        }
    }

    private func decide(_ m: Meeting, _ kind: State.Decision.Kind) {
        state.decisions[m.eventId] = State.Decision(kind: kind, day: dayString(m.start))
    }

    /// Сам открыть встречу: сначала тихое «тк-тк», иконка в строке меню мигает с ним в такт, и через
    /// `MTSLink.warning` — МТС Линк.
    private func autoOpen(_ m: Meeting) {
        guard let url = m.joinURL else { return }
        autoOpened.insert(m.id)
        alarm.knock()
        showOpening(m, knock: true)
        Timer.scheduledTimer(withTimeInterval: MTSLink.warning, repeats: false) { _ in
            MainActor.assumeIsolated { MTSLink.open(url) }
        }
    }

    /// Карточка и иконка в строке меню 2 секунды показывают вращающимся кольцом, что Butler открывает
    /// встречу; окно ради этого не открывается. Иконка перерисовывается каждый кадр.
    private func showOpening(_ m: Meeting, knock: Bool) {
        opening = m.id
        openingSince = Date()
        knocking = knock
        frames?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if Date().timeIntervalSince(self.openingSince) > (self.knocking ? Sound.knock.length : 0) + 2 {
                    self.opening = nil
                    self.frames?.invalidate()
                    self.frames = nil
                }
                self.showClock()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        frames = timer
    }

    /// Подключение к одной из встреч напоминания делает остальные пропущенными: быть сразу на двух нельзя.
    /// Как и «ОК», выключает будильник и закрывает окно.
    func join(_ m: Meeting) {
        guard let url = m.joinURL else { return }
        let alert = !reminding.isEmpty
        MTSLink.open(url)
        prepared.formUnion(meetings.filter { $0.start == m.start }.map(\.reminderKey))
        if reminding.contains(where: { $0.id == m.id }) {
            for other in reminding where other.id != m.id { decide(other, .skipped) }
        }
        decide(m, .joined)
        state.save()
        showOpening(m, knock: false)
        tick()
        if alert && reminding.isEmpty { panel.orderOut(nil) }
    }

    /// Как будильник: «Отложить» — окно закрывается, через `minutes` напоминание зазвенит снова.
    func snooze(_ minutes: Int) {
        reminders.snooze(pending, minutes: minutes, now: currentTime(), byUser: true)
        tick()
        if reminding.isEmpty { panel.orderOut(nil) }
    }

    /// «Закрыть» во время напоминания — то же, что «Отложить на 5 мин»; иначе окно просто прячется.
    func close() {
        if reminding.isEmpty { panel.orderOut(nil) } else { snooze(5) }
    }

    /// «ОК» выключает будильник: напоминание больше не звенит, опоздание не мигает, окно закрывается.
    func acknowledge() {
        reminders.acknowledge(pending)
        tick()
        if reminding.isEmpty { panel.orderOut(nil) }
    }

    func skip(_ m: Meeting) {
        decide(m, .skipped)
        state.save()
        tick()
    }

    func unskip(_ m: Meeting) {
        state.decisions[m.eventId] = nil
        state.save()
        tick()
    }

    /// «Пропустить все» — название запоминается, чтобы серию было видно в списке скрытых.
    func ignore(_ m: Meeting) {
        state.ignored[m.ignoreKey] = m.subject
        state.save()
        tick()
    }

    func unignore(_ key: String) {
        state.ignored[key] = nil
        state.save()
        tick()
    }

    /// Скрыть встречу (серию) навсегда — она пропадает из окна, напоминаний и часов. Записи, которые
    /// пользователь дописал в файл руками, не теряются: правится одна запись `hidden` в файле.
    func hide(_ m: Meeting) {
        (config, configError) = Config.change { json in
            var hidden = json["hidden"] as? [String: Any] ?? [:]
            hidden[m.ignoreKey] = ["subject": m.subject, "series": m.isRecurring]
            json["hidden"] = hidden
        }
        meetings = visible(meetings)
        days = days.mapValues(visible)
        tick()
    }

    /// Вернуть скрытую встречу: сегодняшний день берётся из кэша без фильтра, другие дни перечитаются при показе.
    func unhide(_ key: String) {
        (config, configError) = Config.change { json in
            var hidden = json["hidden"] as? [String: Any] ?? [:]
            // Старый ключ `ItemId|ChangeKey` читается как `ItemId` — и удаляется так же.
            hidden = hidden.filter { $0.key.prefix { $0 != "|" } != key }
            json["hidden"] = hidden
        }
        meetings = visible(assembled(today()))
        days = [:]
        daysAt = [:]
        tick()
    }

    /// Звезда у организатора: VIP — убрать все записи, что есть в его имени; иначе — записать имя целиком.
    func toggleVIPOrganizer(_ m: Meeting) {
        let isVIP = isVIPOrganizer(m.organizerName, config)
        changeVIP { json in
            let list = json["vipOrganizers"] as? [String] ?? []
            json["vipOrganizers"] = isVIP ? list.filter { !m.organizerName.localizedCaseInsensitiveContains($0) } : list + [m.organizerName]
        }
    }

    /// Кругляш «VIP»: вся серия, а у разовой встречи — она сама — становится VIP или перестаёт, что бы ни говорило
    /// правило. Совпала ручная отметка с правилом — она стирается, и встреча снова живёт по правилу.
    func toggleVIPMeeting(_ m: Meeting) {
        let wanted = !m.isVIP
        let byRule = isVIPByRule(m, config)
        changeVIP { json in
            var meetings = json["vipMeetings"] as? [String: Any] ?? [:]
            meetings[m.ignoreKey] = wanted == byRule ? nil : ["subject": m.subject, "series": m.isRecurring, "vip": wanted]
            json["vipMeetings"] = meetings
        }
    }

    /// Список VIP поменялся — разметка пересчитывается по уже полученному, без обращения к серверу. Срок
    /// VIP-напоминания уже наступил — `tick` начнёт напоминание сам.
    func changeVIP(_ edit: (inout [String: Any]) -> Void) {
        guard configError == nil else { return }
        (config, configError) = Config.change(edit)
        meetings = marked(meetings, config)
        days = days.mapValues { Day(date: $0.date, events: marked($0.events, config)) }
        tick()
    }

    private func visible(_ events: [Meeting]) -> [Meeting] {
        events.filter { config.hidden[$0.ignoreKey] == nil }
    }

    private func visible(_ day: Day) -> Day {
        Day(date: day.date, events: visible(day.events))
    }

    // Настройки.

    func openSettings() {
        dialog = nil
        settingsOpen = true
        panel.makeKey()
    }

    /// Ящики — сразу после Touch ID. Щелчок по системному запросу пароля закрывает окно как щелчок мимо него:
    /// тогда оно открывается снова. Настройки за это время могло снять напоминание — тогда ящики не открываются.
    func openMailboxes() {
        guard settingsOpen else { return }
        if !panel.isVisible { panel.showAlert(soft: false) }
        dialog = .mailboxes
        panel.makeKey()
    }

    /// Записать одно поле в `config.json` и сразу применить; битый файл не трогается.
    func changeConfig(_ key: String, _ value: Any) {
        guard configError == nil else { return }
        (config, configError) = Config.change { $0[key] = value }
        tick()
    }

    func preview(_ situation: Situation, sound id: String? = nil) {
        guard let sound = Sound.named(id ?? config.sound(situation)) else { return }
        alarm.preview(sound, situation, config)
    }

    var hasSpeakers: Bool { alarm.hasSpeakers }

    /// Неактуально ли расписание дня за окном кэша: его чтение кончилось ошибкой или устарело. Дни окна
    /// неактуальны по связи с ящиками — это `currentOutage`.
    func freshness(of day: String) -> (since: Date, reason: String)? {
        guard !loading.contains(day) else { return nil }
        return staleness(fetchedAt: daysAt[day], error: dayErrors[day], now: now)
    }
}

/// Цвета строки меню. На тёмной насыщенные красный и голубой плохо читаются — там они почти белые с оттенком,
/// на светлой — обычные.
private let menuRed = menuTint(light: .systemRed, dark: NSColor(red: 1, green: 0.74, blue: 0.72, alpha: 1))
private let menuBlue = menuTint(light: NSColor(Ink.home), dark: NSColor(red: 0.74, green: 0.88, blue: 1, alpha: 1))

private func menuTint(light: NSColor, dark: NSColor) -> NSColor {
    NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light }
}
