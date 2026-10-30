import Foundation
import LocalAuthentication
import SwiftUI

/// Конфиг, который правит пользователь: `~/.config/butler/config.json`; почти всё правится и в окне
/// настроек.
struct Config: Decodable {
    var reminderOffsetSeconds: Double = 0
    var vipReminderOffsetSeconds: Double = 60
    var homeTimeZone = TimeZone.current.identifier
    /// Показывать ли рядом время во втором, домашнем часовом поясе.
    var showHomeTime = false
    /// Скрытые встречи: ключ серии или встречи → название, чтобы было видно, что вычеркнуть.
    var hidden: [String: Hidden] = [:]
    var playAtDesk = true
    var soundAtDesk = "vibraphone"
    var playAway = true
    var soundAway = "doorbell"
    /// Громкость встроенных динамиков для звука «не у компьютера», %.
    var awayVolume = 75
    /// Сколько раз звучит звук «не у компьютера»: 1–5, 0 — пока не вернусь или не отвечу.
    var awayRepeats = 0
    var playInCall = true
    var soundInCall = "vibraphone"
    /// Через сколько минут без мыши и клавиатуры я считаюсь ушедшим.
    var awayAfterMinutes: Double = 2
    var autoOpenMTSLink = true
    /// За сколько секунд до начала Butler сам открывает встречу в МТС Линк.
    var autoOpenSeconds: Double = 30
    /// Ящики Exchange по порядку: из двух копий одной встречи остаётся копия ящика выше.
    var mailboxes: [Mailbox] = []
    /// VIP-контакты — фрагменты имён: «Иванов Пётр» находит «Иванов Пётр Сергеевич». Встреча VIP, если такой
    /// человек её организует или в ней участвует. Ключ называется по-старому.
    var vipOrganizers: [String] = []
    /// Ручные отметки VIP поверх правил: ключ серии или встречи → название и VIP ли она (`vip`, нет поля — да).
    var vipMeetings: [String: Hidden] = [:]
    /// Дни, которые владелец обвёл в календаре на месяц (`YYYY-MM-DD`), по возрастанию.
    var markedDays: [String] = []
    /// За сколько часов до первой встречи рабочего дня в строке меню стоит будильник и с какого часа её время мигает.
    var wakeUpHours: Double = 12
    var wakeUpBlinkHours: Double = 9

    /// Запись `hidden`: Butler пишет объект с признаком серии, а старая или ручная строка — только название.
    struct Hidden: Decodable {
        let subject: String
        let series: Bool?
        /// Только в `vipMeetings`: ручная отметка поверх правил — `false` принудительно не VIP; нет поля — VIP.
        var vip: Bool?

        init(from decoder: Decoder) throws {
            if let subject = try? decoder.singleValueContainer().decode(String.self) {
                (self.subject, series) = (subject, nil)
                return
            }
            let c = try decoder.container(keyedBy: CodingKeys.self)
            subject = try c.decode(String.self, forKey: .subject)
            series = try c.decodeIfPresent(Bool.self, forKey: .series)
            vip = try c.decodeIfPresent(Bool.self, forKey: .vip)
        }

        private enum CodingKeys: String, CodingKey { case subject, series, vip }
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) throws -> T {
            try c.decodeIfPresent(T.self, forKey: key) ?? fallback
        }
        reminderOffsetSeconds = try value(.reminderOffsetSeconds, reminderOffsetSeconds)
        vipReminderOffsetSeconds = try value(.vipReminderOffsetSeconds, vipReminderOffsetSeconds)
        homeTimeZone = try value(.homeTimeZone, homeTimeZone)
        showHomeTime = try value(.showHomeTime, showHomeTime)
        // Старые ключи склеивали идентификатор разовой встречи с её версией: `ItemId|ChangeKey`.
        hidden = Dictionary(try value(.hidden, hidden).map { (String($0.key.prefix { $0 != "|" }), $0.value) },
                            uniquingKeysWith: { first, _ in first })
        playAtDesk = try value(.playAtDesk, playAtDesk)
        soundAtDesk = try value(.soundAtDesk, soundAtDesk)
        playAway = try value(.playAway, playAway)
        soundAway = try value(.soundAway, soundAway)
        awayVolume = try value(.awayVolume, awayVolume)
        awayRepeats = try value(.awayRepeats, awayRepeats)
        playInCall = try value(.playInCall, playInCall)
        soundInCall = try value(.soundInCall, soundInCall)
        awayAfterMinutes = try value(.awayAfterMinutes, awayAfterMinutes)
        autoOpenMTSLink = try value(.autoOpenMTSLink, autoOpenMTSLink)
        autoOpenSeconds = try value(.autoOpenSeconds, autoOpenSeconds)
        mailboxes = try value(.mailboxes, mailboxes)
        vipOrganizers = try value(.vipOrganizers, vipOrganizers).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        vipMeetings = try value(.vipMeetings, vipMeetings)
        // Строка не в виде даты — опечатка в файле: отбрасывается, конфиг остаётся годным.
        markedDays = try value(.markedDays, markedDays).filter { bounds($0) != nil }
        wakeUpHours = try value(.wakeUpHours, wakeUpHours)
        wakeUpBlinkHours = try value(.wakeUpBlinkHours, wakeUpBlinkHours)
    }

    private enum CodingKeys: String, CodingKey {
        case reminderOffsetSeconds, vipReminderOffsetSeconds, homeTimeZone, showHomeTime, hidden
        case playAtDesk, soundAtDesk, playAway, soundAway, awayVolume, awayRepeats, playInCall, soundInCall
        case awayAfterMinutes, autoOpenMTSLink, autoOpenSeconds, mailboxes, vipOrganizers, vipMeetings, markedDays
        case wakeUpHours, wakeUpBlinkHours
    }

    /// Играть ли звук в этой ситуации и какой; ключи — те же, что в файле.
    func plays(_ s: Situation) -> Bool {
        switch s {
        case .atDesk: playAtDesk
        case .away: playAway
        case .inCall: playInCall
        }
    }

    func sound(_ s: Situation) -> String {
        switch s {
        case .atDesk: soundAtDesk
        case .away: soundAway
        case .inCall: soundInCall
        }
    }

    static func keys(_ s: Situation) -> (play: String, sound: String) {
        switch s {
        case .atDesk: ("playAtDesk", "soundAtDesk")
        case .away: ("playAway", "soundAway")
        case .inCall: ("playInCall", "soundInCall")
        }
    }

    /// Нет файла — умолчания без ошибки; файл с ошибкой — умолчания и причина для панели.
    private static let path = NSString(string: "~/.config/butler/config.json").expandingTildeInPath

    static func load() -> (Config, error: String?) {
        guard let data = FileManager.default.contents(atPath: path) else { return (Config(), nil) }
        guard let config = try? JSONDecoder().decode(Config.self, from: data) else {
            return (Config(), "не читается как JSON с нужными полями")
        }
        if config.reminderOffsetSeconds < 0 || config.vipReminderOffsetSeconds < 0 {
            return (Config(), "отрицательный сдвиг напоминания")
        }
        if TimeZone(identifier: config.homeTimeZone) == nil {
            return (Config(), "неизвестный часовой пояс \(config.homeTimeZone)")
        }
        if let unknown = [config.soundAtDesk, config.soundAway, config.soundInCall].first(where: { Sound.named($0) == nil }) {
            return (Config(), "неизвестный звук \(unknown)")
        }
        if !(0...100).contains(config.awayVolume) { return (Config(), "громкость не от 0 до 100") }
        if !(0...5).contains(config.awayRepeats) { return (Config(), "повторов не от 0 до 5") }
        if config.awayAfterMinutes < 1 { return (Config(), "порог «не у компьютера» меньше минуты") }
        if config.autoOpenSeconds < 0 { return (Config(), "отрицательный срок автооткрытия") }
        if config.wakeUpBlinkHours < 0 || config.wakeUpBlinkHours > config.wakeUpHours {
            return (Config(), "будильник мигает раньше, чем появляется, или срок отрицательный")
        }
        var seen: Set<String> = []
        for m in config.mailboxes {
            let problem = [m.address, m.login, m.server].contains { $0.isEmpty } ? "не все поля"
                : !seen.insert(m.address.lowercased()).inserted ? "повторяется"
                : !m.server.hasPrefix("https://") ? "сервер не https://" : nil
            if let problem { return (Config(), "ящик \(m.address): \(problem)") }
        }
        return (config, nil)
    }

    /// Поменять в файле одно поле, не трогая остальное, что пользователь написал в файле, и перечитать
    /// конфиг. Файл не JSON-объект или правка ничего не поменяла — ничего не пишется.
    static func change(_ edit: (inout [String: Any]) -> Void) -> (Config, error: String?) {
        let old = FileManager.default.contents(atPath: path)
        guard let data = changed(old, edit), data != changed(old, { _ in }) else { return load() }
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        // В файле пароли ящиков — читать его может только владелец.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        return load()
    }

    /// Содержимое файла после правки; `nil` — файл есть, но это не JSON-объект.
    static func changed(_ data: Data?, _ edit: (inout [String: Any]) -> Void) -> Data? {
        var json: [String: Any] = [:]
        if let data {
            guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
            json = object
        }
        edit(&json)
        return try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
    }
}

/// То, что Butler помнит между запусками: `~/Library/Application Support/Butler/state.json`.
struct State: Codable {
    /// Серии, пропущенные целиком: ключ серии → название на момент пропуска.
    var ignored: [String: String] = [:]
    /// Решения по экземплярам встреч: ключ — `eventId`, поэтому решение переживает перенос.
    var decisions: [String: Decision] = [:]
    /// Кэш и связь по каждому ящику Exchange: адрес → встречи окна и итог последнего обращения.
    var calendar: [String: Box] = [:]
    /// Сколько обычно длится чтение месяца — для индикатора загрузки.
    var loadStats = LoadStats()
    /// Производственный календарь: год → день за днём.
    var workdays: [String: Workdays] = [:]

    struct Decision: Codable {
        enum Kind: String, Codable { case joined, skipped }
        let kind: Kind
        /// День встречи — по нему решения прошлых дней удаляются.
        let day: String
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Раньше здесь был просто список ключей, без названий.
        if let keys = try? c.decodeIfPresent([String].self, forKey: .ignored) {
            ignored = Dictionary(keys.map { ($0, "") }, uniquingKeysWith: { first, _ in first })
        } else {
            ignored = try c.decodeIfPresent([String: String].self, forKey: .ignored) ?? [:]
        }
        decisions = try c.decodeIfPresent([String: Decision].self, forKey: .decisions) ?? [:]
        calendar = try c.decodeIfPresent([String: Box].self, forKey: .calendar) ?? [:]
        loadStats = try c.decodeIfPresent(LoadStats.self, forKey: .loadStats) ?? LoadStats()
        workdays = try c.decodeIfPresent([String: Workdays].self, forKey: .workdays) ?? [:]
    }

    private static let url = URL.applicationSupportDirectory.appending(path: "Butler/state.json")

    static func load() -> State {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url), let state = try? decoder.decode(State.self, from: data) else {
            return State()
        }
        return state
    }

    mutating func save() {
        // Прожитый заранее день (`--now`) настоящих решений не трогает.
        guard clockShift == 0 else { return }
        let current = today()
        decisions = decisions.filter { $0.value.day >= current }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? encoder.encode(self).write(to: Self.url, options: .atomic)
    }
}

/// Настройки — слой поверх окна Butler. Каждое изменение
/// сразу пишется в `config.json` и действует без перезапуска.
struct SettingsView: View {
    let app: App
    /// Чей список звуков открыт. Клавиши получает панель, а не список, поэтому Escape и Return, пока
    /// список открыт, закрывают только его.
    @SwiftUI.State private var list: Situation?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Настройки").font(Ink.title).foregroundStyle(Ink.primary)
                Spacer()
                if list != nil {
                    Button("") { list = nil }.keyboardShortcut(.cancelAction).frame(width: 0).opacity(0)
                    Button("") { list = nil }.keyboardShortcut(.defaultAction).frame(width: 0).opacity(0)
                }
            }
            if let error = app.configError {
                Text("config.json не читается: \(error) — изменения не сохраняются")
                    .foregroundStyle(Ink.alert).fixedSize(horizontal: false, vertical: true)
            }
            // Без прокрутки: всё помещается, а списки и ящики — во всплывающих окнах.
            VStack(alignment: .leading, spacing: 10) {
                sounds
                reminder
                link
                section("Часовой пояс") {
                    // Друг под другом: рядом в одну строку галочка и длинное имя пояса не влезают.
                    Toggle("Второй часовой пояс", isOn: Binding(get: { app.config.showHomeTime },
                                                                set: { app.changeConfig("showHomeTime", $0) }))
                    zone.disabled(!app.config.showHomeTime).padding(.leading, 18)
                }
                meetings
                exchange
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .disabled(app.configError != nil)
        }
        .font(Ink.body)
        .foregroundStyle(Ink.secondary)
        .controlSize(.small)
        .padding(12)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Ink.window)
        // «Готово» — на месте шестерёнки главного окна: где открыли, там и закрывают.
        .overlay(alignment: .bottomTrailing) {
            Button("Готово") { app.settingsOpen = false }
                .keyboardShortcut(list == nil && app.dialog == nil ? .cancelAction : nil)
                .buttonStyle(Hover(padding: 6))
                .foregroundStyle(Ink.primary)
                .font(Ink.body)
                .padding(.trailing, 6)
                .padding(.bottom, 8)
        }
    }

    private var sounds: some View {
        section("Звуки") {
            soundRow("У компьютера", .atDesk)
            soundRow("Не у компьютера", .away)
            VStack(alignment: .leading, spacing: 6) {
                Volume(app: app)
                HStack(spacing: 6) {
                    Text("Звучать")
                    Picker("", selection: Binding(get: { app.config.awayRepeats }, set: { app.changeConfig("awayRepeats", $0) })) {
                        ForEach(1...5, id: \.self) { Text("\($0) \($0 == 1 || $0 == 5 ? "раз" : "раза")").tag($0) }
                        Text("бесконечно").tag(0)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                if !app.hasSpeakers {
                    Text("Наушники: звук пойдёт тихо, в обычный выход").foregroundStyle(Ink.tertiary)
                }
            }
            .padding(.leading, 20)
            soundRow("На встрече", .inCall)
            if !app.config.playAtDesk && !app.config.playAway && !app.config.playInCall {
                Text("Напоминания придут без звука").foregroundStyle(Ink.tertiary)
            }
            HStack(spacing: 6) {
                Text("Не у компьютера, если не трогал мышь")
                Field(value: number(app.config.awayAfterMinutes), unit: "мин", check: { atLeast($0, 1, "не меньше 1 мин") }) {
                    app.changeConfig("awayAfterMinutes", Double($0)!)
                }
            }
        }
    }

    private func soundRow(_ title: String, _ situation: Situation) -> some View {
        HStack(spacing: 4) {
            Toggle(title, isOn: Binding(get: { app.config.plays(situation) },
                                        set: { app.changeConfig(Config.keys(situation).play, $0) }))
            Spacer()
            SoundList(app: app, situation: situation,
                      open: Binding(get: { list == situation }, set: { list = $0 ? situation : nil }))
            Button { app.preview(situation) } label: { Image(systemName: "play.fill") }
                .buttonStyle(Hover(padding: 6))
                .help("Послушать, как прозвучит в напоминании")
        }
    }

    private var reminder: some View {
        section("Напоминание") {
            HStack(spacing: 6) {
                Text("Обычная встреча за")
                Field(value: number(app.config.reminderOffsetSeconds), unit: "с", check: { atLeast($0, 0, "не меньше 0") }) {
                    app.changeConfig("reminderOffsetSeconds", Double($0)!)
                }
            }
            HStack(spacing: 6) {
                Text("VIP за")
                Field(value: number(app.config.vipReminderOffsetSeconds), unit: "с", check: { atLeast($0, 0, "не меньше 0") }) {
                    app.changeConfig("vipReminderOffsetSeconds", Double($0)!)
                }
            }
        }
    }

    private var link: some View {
        section("МТС Линк") {
            HStack(spacing: 6) {
                Toggle("Открывать встречу автоматически за", isOn: Binding(get: { app.config.autoOpenMTSLink },
                                                                       set: { app.changeConfig("autoOpenMTSLink", $0) }))
                Field(value: number(app.config.autoOpenSeconds), unit: "с", check: { atLeast($0, 0, "не меньше 0") }) {
                    app.changeConfig("autoOpenSeconds", Double($0)!)
                }
                .disabled(!app.config.autoOpenMTSLink)
            }
        }
    }

    /// Пояс — из списка macOS: регион, в нём город.
    private var zone: some View {
        let regions = Dictionary(grouping: TimeZone.knownTimeZoneIdentifiers.filter { $0.contains("/") }) {
            String($0.prefix { $0 != "/" })
        }
        return Menu(zoneName(app.config.homeTimeZone)) {
            ForEach(regions.keys.sorted(), id: \.self) { region in
                Menu(region) {
                    ForEach(regions[region]!.sorted(), id: \.self) { id in
                        Button(zoneName(String(id.dropFirst(region.count + 1)), offsetOf: id)) {
                            app.changeConfig("homeTimeZone", id)
                        }
                    }
                }
            }
        }
        .fixedSize()
    }

    /// VIP-контакты и скрытые встречи — во всплывающих окнах: так настройки помещаются без прокрутки.
    private var meetings: some View {
        section("Встречи") {
            Rows {
                Row(symbol: "star", title: "VIP-контакты", summary: "\(app.config.vipOrganizers.count)") { app.dialog = .vip }
                Divider()
                Row(symbol: "eye.slash", title: "Скрытые встречи", summary: "\(app.config.hidden.count)") { app.dialog = .hidden }
            }
        }
    }

    /// Ящики — тоже во всплывающем окне, но за Touch ID (значок — отпечаток): в нём пароли открытым текстом. Состояние ящиков —
    /// на огоньке главного окна, здесь его нет.
    private var exchange: some View {
        section("Exchange") {
            Rows {
                Row(symbol: "touchid", title: "Ящики", summary: count(app.config.mailboxes.count, "ящик", "ящика", "ящиков")) {
                    Task {
                        let reason = "показать пароли ящиков Exchange"
                        if (try? await LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) == true {
                            app.openMailboxes()
                        }
                    }
                }
            }
        }
    }

    private func section(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        settingsSection(title, content)
    }
}

enum Dialog { case vip, hidden, mailboxes }

/// «1 ящик», «3 ящика», «5 ящиков».
private func count(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
    let (ten, hundred) = (n % 10, n % 100)
    let word = ten == 1 && hundred != 11 ? one : (2...4).contains(ten) && !(12...14).contains(hundred) ? few : many
    return "\(n) \(word)"
}

/// Строки-переходы во всплывающие окна — в белой рамке, как списки.
private struct Rows<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Ink.faded))
    }
}

/// Строка-переход, как в Системных настройках: значок, название, сводка справа и «›». Под мышью
/// подсвечивается вся строка — видно, что это переход, а не действие.
private struct Row: View {
    let symbol: String
    let title: String
    let summary: String
    let action: () -> Void
    @SwiftUI.State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol).foregroundStyle(Ink.accent).frame(width: 14)
                Text(title).foregroundStyle(Ink.primary)
                Spacer()
                Text(summary).foregroundStyle(Ink.tertiary)
                Image(systemName: "chevron.right").foregroundStyle(Ink.tertiary)
            }
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(hovering ? ink(0xF5EFE6) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Всплывающее окно поверх настроек: заголовок и содержимое на карточке посреди окна.
func popup(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
    VStack(alignment: .leading, spacing: 8) {
        Text(title).font(Ink.title).foregroundStyle(Ink.primary)
        content()
    }
    .font(Ink.body)
    .foregroundStyle(Ink.secondary)
    .controlSize(.small)
    .padding(12)
    .background(Ink.window)
    .clipShape(RoundedRectangle(cornerRadius: 8))
    .shadow(color: .black.opacity(0.25), radius: 14, y: 5)
    .padding(16)
}

/// Список целиком, а длинный — с прокруткой, чтобы окно не вылезало за экран.
private func fitting(_ list: some View) -> some View {
    ViewThatFits(in: .vertical) {
        list
        ScrollView { list }
    }
}

/// «Готово» внизу справа всплывающего окна, и Escape.
private func done(_ app: App) -> some View {
    HStack {
        Spacer()
        Button("Готово") { app.dialog = nil }
            .keyboardShortcut(.cancelAction)
            .buttonStyle(Hover(padding: 6))
            .foregroundStyle(Ink.primary)
    }
}

/// VIP-контакты — добавить по имени и убрать. VIP-серии и встречи правятся с карточки, здесь их нет.
struct VIPDialog: View {
    let app: App
    @SwiftUI.State private var name = ""

    var body: some View {
        popup("VIP-контакты") {
            Text("Встреча VIP, если кто-то из списка её организует или в ней участвует.")
                .foregroundStyle(Ink.tertiary).fixedSize(horizontal: false, vertical: true)
            fitting(ListBox(items: app.config.vipOrganizers.sorted { $0.localizedStandardCompare($1) == .orderedAscending },
                            id: \.self, empty: "Список пуст") { name in
                Text(name).foregroundStyle(Ink.primary).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button {
                    app.changeVIP { json in json["vipOrganizers"] = (json["vipOrganizers"] as? [String] ?? []).filter { $0 != name } }
                } label: { Image(systemName: "xmark") }
                    .buttonStyle(Hover(padding: 4)).help("Убрать из VIP")
            })
            HStack(spacing: 6) {
                TextField("Фамилия Имя", text: $name).textFieldStyle(.roundedBorder).onSubmit(add)
                Button("Добавить в список", action: add).buttonStyle(Hover(padding: 6)).foregroundStyle(Ink.accent).fixedSize()
            }
            done(app)
        }
    }

    /// Пустое и уже записанное (без учёта регистра) имя не добавляется.
    private func add() {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !app.config.vipOrganizers.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else { return }
        app.changeVIP { json in json["vipOrganizers"] = (json["vipOrganizers"] as? [String] ?? []) + [name] }
        self.name = ""
    }
}

/// Скрытое корзиной (`config.json`) — вернуть его можно только здесь. Пропущенные целиком серии
/// возвращаются с карточки, здесь их нет.
struct HiddenDialog: View {
    let app: App

    var body: some View {
        let hidden = app.config.hidden.map { key, entry in
            (key: key, title: entry.subject, note: entry.series.map { $0 ? "серия" : "встреча" })
        }.sorted { ($0.title, $0.key) < ($1.title, $1.key) }
        popup("Скрытые встречи") {
            fitting(ListBox(items: hidden, id: \.key, empty: "Ничего не скрыто") { item in
                (Text(item.title.isEmpty ? item.key : item.title).foregroundStyle(Ink.primary) + Text(item.note.map { " · " + $0 } ?? ""))
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Вернуть") { app.unhide(item.key) }
                    .buttonStyle(Hover(padding: 4))
                    .foregroundStyle(Ink.accent)
            })
            done(app)
        }
    }
}

/// Раздел настроек — отдельная плашка с заголовком, чтобы разделы не сливались.
func settingsSection(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
    VStack(alignment: .leading, spacing: 6) {
        Text(title).font(Ink.title).foregroundStyle(Ink.primary)
        content()
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(RoundedRectangle(cornerRadius: 6).fill(ink(0xF2ECE2)))
    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(ink(0xE3D8C6)))
}

/// Список в настройках — белая рамка, строка на запись с маркером, строки разделены чертой; пустой список —
/// надпись внутри рамки. Чтобы список было видно как список, а не как разрозненные строки.
struct ListBox<Item, ID: Hashable, Row: View>: View {
    let items: [Item]
    let id: KeyPath<Item, ID>
    let empty: String
    @ViewBuilder let row: (Item) -> Row

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if items.isEmpty {
                Text(empty).foregroundStyle(Ink.tertiary).padding(.horizontal, 8).padding(.vertical, 6)
            }
            ForEach(items, id: id) { item in
                if item[keyPath: id] != items.first?[keyPath: id] { Divider() }
                HStack(spacing: 6) {
                    Circle().fill(Ink.tertiary).frame(width: 3, height: 3)
                    row(item)
                }
                .padding(.leading, 8)
                .padding(.trailing, 4)
                .frame(minHeight: 22)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color.white))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Ink.faded))
    }
}

/// «Europe/Moscow · UTC+3»: подчёркивания — пробелами, смещение сейчас, с минутами, если они есть.
private func zoneName(_ name: String, offsetOf id: String? = nil) -> String {
    let seconds = TimeZone(identifier: id ?? name)?.secondsFromGMT() ?? 0
    let minutes = abs(seconds) / 60
    let offset = "UTC\(seconds < 0 ? "−" : "+")\(minutes / 60)" + (minutes % 60 == 0 ? "" : String(format: ":%02d", minutes % 60))
    return name.replacingOccurrences(of: "_", with: " ") + " · " + offset
}

/// `60`, а дробное — `1.5`.
private func number(_ value: Double) -> String {
    value == value.rounded() ? String(Int(value)) : String(value)
}

/// Причина, по которой число не годится, или `nil`.
private func atLeast(_ text: String, _ minimum: Double, _ reason: String) -> String? {
    guard let value = Double(text) else { return "нужно число" }
    return value < minimum ? reason : nil
}

/// Список звуков, который не закрывается после щелчка: щелчок проигрывает звук и выбирает его —
/// можно переслушать подряд сколько угодно. Закрывают его Escape, Return и щелчок мимо.
private struct SoundList: View {
    let app: App
    let situation: Situation
    @Binding var open: Bool

    var body: some View {
        let selected = app.config.sound(situation)
        Button { open = true } label: {
            HStack(spacing: 3) {
                Text(Sound.named(selected)?.name ?? selected).foregroundStyle(Ink.primary)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }
        }
        .buttonStyle(Hover(padding: 6))
        .popover(isPresented: $open, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 0) {
                group("Мягкие", loud: false, selected: selected)
                group("Громкие", loud: true, selected: selected).padding(.top, 6)
            }
            .font(Ink.body)
            .padding(8)
            .frame(width: 190)
        }
    }

    private func group(_ title: String, loud: Bool, selected: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(Ink.title).foregroundStyle(Ink.tertiary).padding(.bottom, 2)
            ForEach(Sound.all.filter { $0.isLoud == loud }, id: \.id) { sound in
                Button {
                    app.changeConfig(Config.keys(situation).sound, sound.id)
                    app.preview(situation, sound: sound.id)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark").opacity(sound.id == selected ? 1 : 0)
                        Text(sound.name)
                        Spacer()
                    }
                    .foregroundStyle(Ink.primary)
                    .padding(.vertical, 2)
                }
                .buttonStyle(Hover(padding: 4))
            }
        }
    }
}

/// Громкость звука «не у компьютера»: пока ползунок тянут, ничего не пишется и не звучит; отпустили —
/// значение в файл и проба на новой громкости.
private struct Volume: View {
    let app: App
    @SwiftUI.State private var dragging: Double?

    var body: some View {
        let value = dragging ?? Double(app.config.awayVolume)
        HStack(spacing: 6) {
            Text("Громкость")
            Slider(value: Binding(get: { value }, set: { dragging = $0 }), in: 0...100, step: 5) { editing in
                guard !editing, let dragging else { return }
                app.changeConfig("awayVolume", Int(dragging))
                self.dragging = nil
                app.preview(.away)
            }
            .frame(width: 140)
            Text("\(Int(value)) %").monospacedDigit().frame(width: 36, alignment: .trailing)
        }
    }
}

/// Поле ввода значения из конфига: проверка на каждом вводе с причиной под полем; в файл — по Return
/// или уходу фокуса и только верное значение.
private struct Field: View {
    let value: String
    let unit: String
    let check: (String) -> String?
    let save: (String) -> Void
    @SwiftUI.State private var text: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                TextField("", text: Binding(get: { text ?? value }, set: { text = $0 }))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 44)
                    .focused($focused)
                    .onSubmit(commit)
                Text(unit)
            }
            if let text, let problem = check(clean(text)) {
                Text(problem).foregroundStyle(Ink.alert)
            }
        }
        .onChange(of: focused) { if !focused { commit() } }
    }

    private func clean(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
    }

    private func commit() {
        guard let text else { return }
        let entered = clean(text)
        guard check(entered) == nil else { return }
        if entered != value { save(entered) }
        self.text = nil
    }
}
