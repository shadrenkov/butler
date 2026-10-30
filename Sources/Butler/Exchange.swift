import AppKit
import CryptoKit
import IOKit
import SwiftUI

// Связь с Exchange: запросы к серверу, итоги и повторы, кэш ящиков, индикатор и раздел «Ящики»
// в настройках. Сервер боевой: каждое обращение — в журнал и под предохранитель.

struct Mailbox: Codable, Equatable {
    let address: String
    /// `ДОМЕН\логин` — как входят в Outlook.
    let login: String
    /// Адрес EWS: `https://…/EWS/Exchange.asmx`.
    let server: String
    /// Пароль учётной записи. В памяти — открытым текстом, в `config.json` — зашифрованным (`sealed`).
    /// Пустой — пароля нет.
    var password = ""

    init(address: String, login: String, server: String, password: String = "") {
        (self.address, self.login, self.server, self.password) = (address, login, server, password)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        address = try c.decode(String.self, forKey: .address)
        login = try c.decode(String.self, forKey: .login)
        server = try c.decode(String.self, forKey: .server)
        password = opened(try c.decodeIfPresent(String.self, forKey: .password) ?? "")
    }
}

/// Ключ паролей в `config.json`: идентификатор этого Mac, имя пользователя и случайная строка из кода.
/// Минимальная защита — от кражи или сканирования файла: на другом Mac или под другой учёткой он не
/// расшифровывается. Связку ключей не берём: при ad-hoc подписи она спрашивает пароль после каждой сборки.
private let passwordKey: SymmetricKey = {
    let device = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
    defer { IOObjectRelease(device) }
    let mac = IORegistryEntryCreateCFProperty(device, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)?
        .takeRetainedValue() as? String ?? ""
    let secret = "9561a2f6d91256fa75c857f29c6337873a474e53c4ded36004baaecca7d1a15f"
    return SymmetricKey(data: SHA256.hash(data: Data("\(secret)|\(mac)|\(NSUserName())".utf8)))
}()

/// Пароль для `config.json`: `enc:` и AES-GCM в base64. Пустой и уже зашифрованный — как есть.
func sealed(_ password: String) -> String {
    guard !password.isEmpty, !password.hasPrefix("enc:") else { return password }
    return "enc:" + (try! AES.GCM.seal(Data(password.utf8), using: passwordKey)).combined!.base64EncodedString()
}

/// Пароль из `config.json`. Без `enc:` — открытый текст (прежняя версия, вписан руками): он
/// принимается и при запуске шифруется. Не расшифровался (другой Mac или учётка) — пароля нет.
func opened(_ stored: String) -> String {
    guard stored.hasPrefix("enc:") else { return stored }
    guard let data = Data(base64Encoded: String(stored.dropFirst(4))), let box = try? AES.GCM.SealedBox(combined: data),
          let plain = try? AES.GCM.open(box, using: passwordKey) else { return "" }
    return String(decoding: plain, as: UTF8.self)
}

struct Person: Codable, Equatable {
    let name: String
    let address: String
}

/// Встреча так, как её отдал один ящик; тела приглашений не хранятся — из них уже взяты ссылка и описание.
struct Event: Codable, Equatable {
    let id: String
    /// Версия встречи на сервере: изменилась — встречу нужно перечитать.
    let changeKey: String
    /// UID серии; у разовой встречи `nil`.
    let uid: String?
    let subject: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let organizerName: String
    let organizerAddress: String
    let attendees: [Person]
    /// Ответ владельца на приглашение словами сервера: `Organizer`, `Accept`, `Tentative`, `NoResponseReceived`…
    let response: String
    let isFree: Bool
    let isCancelled: Bool
    let joinURL: URL?
    let description: String?
}

/// Чем кончилось неудачное обращение — от этого зависит, когда пробовать снова.
enum Failure: Error, Codable, Equatable {
    case offline
    case server(String)
    case throttled(until: Date)
    case unauthorized
    case noAccess(String)
    case certificate
    case badServer(String)
    case overLimit
    case noPassword

    /// Само не пройдёт: ящик не трогается до смены его настроек или «Проверить снова».
    var stops: Bool {
        switch self {
        case .unauthorized, .noAccess, .certificate, .badServer, .overLimit: true
        default: false
        }
    }

    /// Простыми словами — для подсказки индикатора и красного блока.
    var text: String {
        switch self {
        case .offline: "нет сети или VPN"
        case .server(let reason): "сервер не отвечает (\(reason))"
        case .throttled(let until): "сервер просит подождать до \(until.formatted(date: .omitted, time: .shortened))"
        case .unauthorized: "неверный логин или пароль"
        case .noAccess(let code): "нет доступа к ящику (\(code))"
        case .certificate: "сертификат сервера не принят"
        case .badServer(let reason): "по адресу сервера не Exchange (\(reason))"
        case .overLimit: "Butler превысил лимит запросов"
        case .noPassword: "нет пароля"
        }
    }

    /// Для журнала: одно слово.
    var name: String {
        switch self {
        case .offline: "offline"
        case .server: "server"
        case .throttled: "throttled"
        case .unauthorized: "unauthorized"
        case .noAccess: "noAccess"
        case .certificate: "certificate"
        case .badServer: "badServer"
        case .overLimit: "overLimit"
        case .noPassword: "noPassword"
        }
    }
}

/// Кэш и связь одного ящика: встречи окна из последнего удачного чтения и чем кончилось последнее обращение.
struct Box: Codable {
    var events: [Event] = []
    /// Какие дни (`YYYY-MM-DD`) покрывает `events`.
    var window: ClosedRange<String>?
    /// Последнее удачное чтение всего окна — оно раз в 10 минут; между ними раз в минуту проверяется сегодня.
    var windowAt: Date?
    /// Последнее удачное обращение — любое.
    var success: Date?
    var failure: Failure?
    /// Первая неудача после удачи — от неё считаются 10 минут до тревоги.
    var failingSince: Date?
    var retryAt: Date?
    /// Сбоев подряд — от него растёт пауза.
    var failures = 0
}

// MARK: - Обращение к серверу

/// `--offline`: ни одного обращения к серверу — для работы над интерфейсом на кэше.
nonisolated(unsafe) var offlineMode = false

/// Соединение на ящик (`NTLM.swift`) — не больше одного запроса одновременно. Другой логин, сервер или пароль —
/// новое соединение и новый вход.
@MainActor private var connections: [String: (mailbox: Mailbox, password: String, connection: Connection)] = [:]

@MainActor private func connection(_ mailbox: Mailbox, _ password: String) -> Connection? {
    if let c = connections[mailbox.address], c.mailbox.login == mailbox.login, c.mailbox.server == mailbox.server,
       c.password == password { return c.connection }
    connections[mailbox.address]?.connection.close()
    guard let connection = Connection(server: mailbox.server, login: mailbox.login, password: password) else { return nil }
    connections[mailbox.address] = (mailbox, password, connection)
    return connection
}

/// Обращения к каждому ящику за последний час — для предохранителя. Не в `Box`: чтение дня за окном идёт
/// во временный кэш, а считаться должно всё.
@MainActor private var requests: [String: [Date]] = [:]

/// Предохранитель от собственных ошибок Butler, например цикла обновлений. Работе он не мешает:
/// в обычный час на ящик уходит около 70 запросов, при листании месяцев — до ~170, лимит на порядок выше.
let hourlyLimit = 2000

func allowed(_ requests: inout [Date], now: Date) -> Bool {
    requests.removeAll { now.timeIntervalSince($0) >= 3600 }
    guard requests.count < hourlyLimit else { return false }
    requests.append(now)
    return true
}

/// Одно обращение: предохранитель, запрос, итог, строка журнала.
@MainActor private func post(_ body: String, to mailbox: Mailbox, password: String, operation: String) async -> Result<XMLDocument, Failure> {
    let started = Date.now
    guard allowed(&requests[mailbox.address, default: []], now: started) else {
        journal(mailbox, operation, .overLimit, 0)
        return .failure(.overLimit)
    }
    guard let connection = connection(mailbox, password) else { return .failure(.badServer("неверный адрес")) }
    let result: Result<XMLDocument, Failure>
    do {
        let (data, response) = try await connection.post(Data(envelope(body).utf8))
        result = outcome(data: data, response: response, now: .now)
    } catch {
        result = .failure(outcome(error))
    }
    journal(mailbox, operation, failure(of: result), Date.now.timeIntervalSince(started))
    return result
}

private func envelope(_ body: String) -> String {
    """
    <?xml version="1.0" encoding="utf-8"?>
    <soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/" \
    xmlns:t="http://schemas.microsoft.com/exchange/services/2006/types" \
    xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages">
    <soap:Header><t:RequestServerVersion Version="Exchange2013"/></soap:Header>
    <soap:Body>\(body)</soap:Body>
    </soap:Envelope>
    """
}

/// Итог сетевой ошибки: нет сети — временно; сертификат — до смены настроек; `userAuthenticationRequired` —
/// сервер отверг пароль (`Connection.login`). Остальное — временная беда сервера: неизвестное считается временным.
func outcome(_ error: Error) -> Failure {
    guard let error = error as? URLError else { return .server(error.localizedDescription) }
    switch error.code {
    case .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .networkConnectionLost,
         .internationalRoamingOff, .dataNotAllowed:
        return .offline
    case .serverCertificateHasBadDate, .serverCertificateUntrusted, .serverCertificateHasUnknownRoot,
         .serverCertificateNotYetValid, .clientCertificateRejected, .clientCertificateRequired:
        return .certificate
    case .cancelled, .userAuthenticationRequired, .userCancelledAuthentication:
        return .unauthorized
    case .timedOut:
        return .server("не ответил за 30 с")
    default:
        return .server(error.localizedDescription)
    }
}

/// Итог ответа сервера.
func outcome(data: Data, response: HTTPURLResponse?, now: Date) -> Result<XMLDocument, Failure> {
    let status = response?.statusCode ?? 0
    switch status {
    case 401: return .failure(.unauthorized)
    case 404: return .failure(.badServer("сервер ответил 404"))
    case 429, 503:
        let wait = response?.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? 600
        return .failure(.throttled(until: now + wait))
    default: break
    }
    guard let doc = try? XMLDocument(data: data), !nodes(doc, "//*[local-name()='Envelope']").isEmpty else {
        return .failure(status == 200 ? .badServer("ответ не от Exchange") : .server("сервер ответил \(status)"))
    }
    let codes = nodes(doc, "//*[local-name()='ResponseCode']").compactMap(\.stringValue)
        + nodes(doc, "//*[local-name()='faultcode']").compactMap { $0.stringValue?.components(separatedBy: ":").last }
    // Одна удалённая между двумя запросами встреча — не беда всего ответа.
    if let code = codes.first(where: { $0 != "NoError" && $0 != "ErrorItemNotFound" }) {
        return .failure(failure(code: code, doc: doc, now: now))
    }
    return status == 200 ? .success(doc) : .failure(.server("сервер ответил \(status)"))
}

/// Код ошибки EWS → итог. `ErrorServerBusy` называет, сколько молчать, — срок соблюдается целиком:
/// возвращаясь раньше, ящик может застрять в троттлинге на часы.
private func failure(code: String, doc: XMLDocument, now: Date) -> Failure {
    switch code {
    case "ErrorServerBusy":
        let ms = nodes(doc, "//*[local-name()='Value'][@Name='BackOffMilliseconds']").first?.stringValue.flatMap(Double.init)
        return .throttled(until: now + (ms.map { $0 / 1000 } ?? 600))
    case "ErrorNonExistentMailbox", "ErrorAccessDenied", "ErrorInvalidServerVersion", "ErrorMailboxMoveInProgress":
        return .noAccess(code)
    default:
        return .server(code)
    }
}

/// Строка на обращение в `~/Library/Logs/Butler/exchange.log` — по нему считают, сколько запросов ушло.
/// Без паролей, тем и имён.
private func journal(_ mailbox: Mailbox, _ operation: String, _ failure: Failure?, _ seconds: TimeInterval) {
    let result = switch failure {
    case nil: "ok"
    case .throttled(let until)?: "throttled \(Int(until.timeIntervalSinceNow.rounded()))s"
    case let f?: f.name
    }
    let time = Date.now.formatted(Date.ISO8601FormatStyle(timeZone: .current))
    let line = "\(time) \(mailbox.address) \(operation) \(result) \(String(format: "%.1f", seconds))s\n"
    let url = URL.libraryDirectory.appending(path: "Logs/Butler/exchange.log")
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    // Около 4500 строк в день: после 5 МБ журнал уходит в exchange.log.1, прежний .1 стирается.
    if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int, size > 5_000_000 {
        let old = url.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: url, to: old)
    }
    if let file = try? FileHandle(forWritingTo: url) {
        file.seekToEndOfFile()
        file.write(Data(line.utf8))
        try? file.close()
    } else {
        try? Data(line.utf8).write(to: url)
    }
}

/// Когда пробовать снова после неудачи; `nil` — сам ящик не пробуется.
func retryAt(_ failure: Failure, failures: Int, now: Date) -> Date? {
    switch failure {
    case .offline: now + 120
    case .server: now + min(120 * pow(2, Double(max(failures, 1) - 1)), 1800)
    case .throttled(let until): max(until, now + 600)
    default: nil
    }
}

/// Пора ли читать окно ящика: в порядке — раз в 10 минут; временный сбой — в его срок, а «нет сети» ещё и сразу
/// после сна; остановленный — никогда, без пароля — когда пароль появится.
func isDue(_ box: Box?, hasPassword: Bool, now: Date, wake: Bool) -> Bool {
    guard let box else { return true }
    guard let failure = box.failure else { return now.timeIntervalSince(box.windowAt ?? .distantPast) >= 600 }
    if failure == .noPassword { return hasPassword }
    if failure.stops { return false }
    if wake && failure == .offline { return true }
    return now >= box.retryAt ?? .distantPast
}

/// Тревога: ящик остановлен или временный сбой длится 10 минут. Время — последняя удачная связь среди ящиков
/// в сбое, строки — по ящику в сбое; `nil` — тревоги нет.
func outage(_ boxes: [String: Box], mailboxes: [Mailbox], now: Date) -> (since: Date, lines: [String])? {
    let failing = mailboxes.compactMap { m -> (address: String, box: Box, failure: Failure)? in
        guard let box = boxes[m.address], let failure = box.failure, failure != .noPassword else { return nil }
        return (m.address, box, failure)
    }
    guard failing.contains(where: { $0.failure.stops || now.timeIntervalSince($0.box.failingSince ?? now) >= 600 }) else { return nil }
    let since = failing.compactMap(\.box.success).min() ?? failing.compactMap(\.box.failingSince).min() ?? now
    return (since, failing.map { "\($0.address): \($0.failure.text)" })
}

// MARK: - Индикатор

enum Light { case green, red, gray }

/// Цвет и строка ящика для индикатора, его подсказки и раздела «Ящики».
@MainActor
func status(_ box: Box?, hasPassword: Bool, now: Date) -> (light: Light, text: String) {
    guard hasPassword, box?.failure != .noPassword else { return (.gray, "нет пароля") }
    guard let box, box.success != nil || box.failure != nil else { return (.gray, "ещё не проверялся") }
    guard let failure = box.failure else { return (.green, "на связи, \(hhmm(box.success!))") }
    var text = failure.text
    if failure.stops {
        text += " · проверки остановлены"
    } else if case .throttled = failure {
    } else if let retry = box.retryAt {
        text += " · пробую снова в \(hhmm(max(retry, now)))"
    }
    if let success = box.success { text += " · на связи был в \(hhmm(success))" }
    return (.red, text)
}

func color(_ light: Light) -> Color {
    switch light {
    case .green: ink(0x4E9A45)
    case .red: Ink.alert
    case .gray: Ink.tertiary
    }
}

/// Точка связи у шестерёнки: зелёная — все ящики ответили, красная и часто мигает — хоть один нет, серая —
/// проверять нечего. По щелчку — всплывашка со строкой на ящик.
struct Indicator: View {
    @Bindable var app: App

    var body: some View {
        let lines = app.config.mailboxes.map { m in
            (address: m.address, status: status(app.state.calendar[m.address], hasPassword: !m.password.isEmpty, now: .now))
        }
        let light: Light = lines.contains { $0.status.light == .red } ? .red : lines.contains { $0.status.light == .green } ? .green : .gray
        Button { app.connectionDetails.toggle() } label: {
            // Ошибка — мигает быстро, чтобы заметить краем глаза: 0,3 с горит, 0,3 с гаснет.
            // Пока идёт обращение к Exchange — плавно, в ожидании отсчёту хватает кадра в секунду.
            TimelineView(.animation(minimumInterval: app.syncingSince != nil ? nil : light == .red ? 0.3 : 1)) { context in
                let dim = light == .red && Int(context.date.timeIntervalSinceReferenceDate / 0.3) % 2 == 1
                // Колечко вплотную к точке — обратный отсчёт до следующей проверки: за минуту тает до одной
                // точки; пока идёт обращение, эта точка кружит вокруг, после него кольцо снова полное.
                let left = app.syncingSince != nil ? 0 : 1 - context.date.timeIntervalSince(app.polledAt ?? context.date) / pollInterval
                let turns = app.syncingSince.map { context.date.timeIntervalSince($0) } ?? 0
                ZStack {
                    // Тонкая рамка цвета точки — всегда на месте, отсчёт идёт внутри неё.
                    Circle().stroke(color(light), lineWidth: 0.5).frame(width: 10.5, height: 10.5)
                    Circle().trim(from: 0, to: max(left, 0.001)).rotation(.degrees(-90 + turns * 360))
                        .stroke(color(light).opacity(0.5), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .frame(width: 7.5, height: 7.5)
                    Circle().fill(color(light)).frame(width: 5, height: 5).opacity(dim ? 0.15 : 1)
                }
                .frame(width: 11, height: 11)
            }
        }
        .buttonStyle(Hover(padding: 4))
        .help("Связь с Exchange")
        .popover(isPresented: $app.connectionDetails, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text(light == .red ? "Связь с Exchange: есть ошибки" : light == .green ? "Связь с Exchange в порядке" : "Связь с Exchange")
                    .font(Ink.title).foregroundStyle(light == .red ? Ink.alert : Ink.primary)
                if lines.isEmpty { Text("Ящиков нет — задайте их в настройках").foregroundStyle(Ink.secondary) }
                ForEach(lines, id: \.address) { line in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Circle().fill(color(line.status.light)).frame(width: 7, height: 7)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(line.address).foregroundStyle(Ink.primary)
                            Text(line.status.text).foregroundStyle(line.status.light == .red ? Ink.alert : Ink.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            // Остановленный ящик сам не пробует — снова только по кнопке или после смены настроек.
                            if app.state.calendar[line.address]?.failure?.stops == true {
                                Button("Проверить снова") { app.recheck(line.address) }
                                    .buttonStyle(Hover(padding: 4)).foregroundStyle(Ink.accent).padding(.leading, -4)
                            }
                        }
                    }
                }
            }
            .font(Ink.body)
            .padding(10)
            .frame(width: 300, alignment: .leading)
        }
    }
}

// MARK: - Ящики в настройках

/// Ящики из текста в духе ini: секция на ящик — `[адрес]`, под ней `login`, `server` и `password`; пустые строки,
/// `#` и `;` пропускаются. Ошибка называет строку.
func mailboxes(from text: String) throws -> [Mailbox] {
    var result: [Mailbox] = []
    var section: (address: String, line: Int, values: [String: String])?

    func close() throws {
        guard let s = section else { return }
        guard let login = s.values["login"], !login.isEmpty else { throw Problem("строка \(s.line): у [\(s.address)] нет login") }
        guard let value = s.values["server"], !value.isEmpty else { throw Problem("строка \(s.line): у [\(s.address)] нет server") }
        // Как в Outlook, достаточно хоста: адрес EWS у Exchange стандартный. Полный адрес тоже принимается.
        let server = value.contains("://") ? value : "https://\(value)/EWS/Exchange.asmx"
        guard server.hasPrefix("https://") else { throw Problem("строка \(s.line): у [\(s.address)] server не https://") }
        result.append(Mailbox(address: s.address, login: login, server: server, password: s.values["password"] ?? ""))
    }

    for (index, raw) in text.components(separatedBy: .newlines).enumerated() {
        let line = raw.trimmingCharacters(in: .whitespaces)
        let number = index + 1
        if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
        if line.hasPrefix("[") {
            guard line.hasSuffix("]") else { throw Problem("строка \(number): секция закрывается «]»") }
            try close()
            let address = line.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
            guard address.contains("@") else { throw Problem("строка \(number): в [ ] нужен адрес ящика") }
            guard !result.contains(where: { $0.address.lowercased() == address.lowercased() }) else {
                throw Problem("строка \(number): ящик \(address) уже есть")
            }
            section = (address, number, [:])
            continue
        }
        guard section != nil else { throw Problem("строка \(number): сначала [адрес ящика]") }
        let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, ["login", "server", "password"].contains(parts[0]) else {
            throw Problem("строка \(number): нужно «login = …», «server = …» или «password = …»")
        }
        section?.values[parts[0]] = parts[1]
    }
    try close()
    return result
}

/// Текст ящиков для окна настройки.
func text(of mailboxes: [Mailbox]) -> String {
    mailboxes.map { "[\($0.address)]\nlogin = \($0.login)\npassword = \($0.password)\nserver = \(shown($0.server))" }.joined(separator: "\n\n")
}

/// Стандартный адрес `https://хост/EWS/Exchange.asmx` в тексте — одним хостом, иной — целиком.
private func shown(_ server: String) -> String {
    let host = server.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "/EWS/Exchange.asmx", with: "")
    return server == "https://\(host)/EWS/Exchange.asmx" ? host : server
}

/// Пример нового ящика для пользователя ivanov: домен почты, домен входа и сервер — как у последнего ящика, а
/// без ящиков — example.com. Пароль пустой: пока его не впишут, к серверу с примером не обращаются.
private func template(after last: Mailbox?) -> String {
    let mail = last.map { String($0.address.split(separator: "@").last ?? "") } ?? "example.com"
    let domain = last?.login.split(separator: "\\").dropLast().first.map(String.init) ?? "DOMAIN"
    let server = last.map { shown($0.server) } ?? "e-mail.\(mail)"
    return "[ivanov@\(mail)]\nlogin = \(domain)\\ivanov\npassword = \nserver = \(server)"
}

/// Всплывающее окно поверх настроек, за Touch ID: текст всех ящиков в духе ini — с паролями. Сохраняется целиком;
/// «Добавить ящик» дописывает шаблон, «Отмена» и Escape закрывают без сохранения.
struct MailboxesEditor: View {
    let app: App
    @SwiftUI.State private var text: String?
    @SwiftUI.State private var error: String?

    var body: some View {
        let saved = Butler.text(of: app.config.mailboxes)
        let current = text ?? saved
        popup("Ящики Exchange") {
            Text("Секция на ящик: [адрес], под ней login, password — пароль учётной записи — и server — хост, как в Outlook.")
                .foregroundStyle(Ink.tertiary).fixedSize(horizontal: false, vertical: true)
            Text("Здесь пароли видны как есть, а на диске хранятся в зашифрованном виде.")
                .foregroundStyle(Ink.tertiary).fixedSize(horizontal: false, vertical: true)
            // `get` читает состояние, а не `current`: снимок старше набранного, и редактор сбросил бы курсор в конец.
            TextEditor(text: Binding(get: { text ?? saved }, set: { text = $0; error = nil }))
                .font(.system(size: 9.5, design: .monospaced))
                .scrollContentBackground(.hidden)
                .frame(height: 220)
                .padding(4)
                .background(Color.white)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Ink.faded))
            if let error { Text(error).foregroundStyle(Ink.alert).fixedSize(horizontal: false, vertical: true) }
            HStack(spacing: 4) {
                // Подписи кнопок не переносятся: каждая — одной строкой.
                Button("Добавить ящик") {
                    text = current + (current.isEmpty ? "" : "\n\n") + template(after: app.config.mailboxes.last)
                }
                .fixedSize()
                Spacer()
                Button("Отмена") { app.dialog = nil }
                    .keyboardShortcut(.cancelAction)
                    .fixedSize()
                Button("Сохранить") {
                    error = app.saveMailboxes(current)
                    if error == nil { app.dialog = nil }
                }
                .disabled(current == saved)
                .fixedSize()
            }
            .buttonStyle(Hover(padding: 6))
            .foregroundStyle(Ink.accent)
        }
    }
}

// MARK: - Чтение ящика

/// Прочитать `from..<to` ящика: `FindItem` даёт встречи с их версиями, `GetItem` — только новые и изменённые;
/// без изменений это один запрос. `days` — чтение всего окна: кэш заменяется. `nil` — проверка
/// сегодняшнего дня: заменяются только встречи в `from..<to`, остальное окно остаётся. `onStep` — для
/// индикатора загрузки: сколько встреч нужно дочитать и сколько уже дочитано.
@MainActor
func read(_ mailbox: Mailbox, password: String?, from: Date, to: Date, days: ClosedRange<String>?, box: Box,
          onStep: ((_ stale: Int, _ fetched: Int) -> Void)? = nil) async -> Box {
    var box = box
    if offlineMode { return box }
    guard let password else {
        box.failure = .noPassword
        return box
    }

    func failed(_ failure: Failure) -> Box {
        let now = Date.now
        box.failure = failure
        box.failingSince = box.failingSince ?? now
        box.failures += 1
        box.retryAt = retryAt(failure, failures: box.failures, now: now)
        return box
    }

    let listed: [(id: String, changeKey: String)]
    switch await post(findItem(mailbox.address, from: from, to: to), to: mailbox, password: password, operation: "FindItem") {
    case .failure(let f): return failed(f)
    case .success(let doc): listed = findItems(doc)
    }
    let known = Dictionary(box.events.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let stale = listed.filter { known[$0.id]?.changeKey != $0.changeKey }
    onStep?(stale.count, 0)
    var fresh: [String: Event] = [:]
    for start in stride(from: 0, to: stale.count, by: 100) {
        let chunk = Array(stale[start..<min(start + 100, stale.count)])
        switch await post(getItem(chunk), to: mailbox, password: password, operation: "GetItem(\(chunk.count))") {
        case .failure(let f): return failed(f)
        case .success(let doc):
            let (read, failure) = events(doc)
            if let failure { return failed(failure) }
            for e in read { fresh[e.id] = e }
            onStep?(stale.count, min(start + 100, stale.count))
        }
    }
    // Встреча, удалённая между двумя запросами, просто пропадает.
    let read = listed.compactMap { item in fresh[item.id] ?? known[item.id].flatMap { $0.changeKey == item.changeKey ? $0 : nil } }
    if let days {
        (box.events, box.window, box.windowAt) = (read, days, .now)
    } else {
        // Встреча, перенесённая на сегодня с другого дня окна, не должна остаться и там.
        let ids = Set(listed.map(\.id))
        box.events = box.events.filter { ($0.start >= to || $0.end <= from) && !ids.contains($0.id) } + read
    }
    box.success = .now
    box.failure = nil
    box.failingSince = nil
    box.failures = 0
    box.retryAt = nil
    return box
}

private func findItem(_ address: String, from: Date, to: Date) -> String {
    let iso = ISO8601DateFormatter()
    return """
    <m:FindItem Traversal="Shallow"><m:ItemShape><t:BaseShape>IdOnly</t:BaseShape></m:ItemShape>\
    <m:CalendarView StartDate="\(iso.string(from: from))" EndDate="\(iso.string(from: to))"/>\
    <m:ParentFolderIds><t:DistinguishedFolderId Id="calendar"><t:Mailbox><t:EmailAddress>\(escaped(address))\
    </t:EmailAddress></t:Mailbox></t:DistinguishedFolderId></m:ParentFolderIds></m:FindItem>
    """
}

private let fields = ["item:Subject", "item:Body", "item:TextBody", "calendar:Start", "calendar:End", "calendar:IsAllDayEvent",
                      "calendar:IsCancelled", "calendar:LegacyFreeBusyStatus", "calendar:Location", "calendar:Organizer",
                      "calendar:RequiredAttendees", "calendar:OptionalAttendees", "calendar:MyResponseType", "calendar:UID",
                      "calendar:CalendarItemType"]

private func getItem(_ items: [(id: String, changeKey: String)]) -> String {
    """
    <m:GetItem><m:ItemShape><t:BaseShape>IdOnly</t:BaseShape><t:BodyType>HTML</t:BodyType><t:AdditionalProperties>\
    \(fields.map { "<t:FieldURI FieldURI=\"\($0)\"/>" }.joined())</t:AdditionalProperties></m:ItemShape>\
    <m:ItemIds>\(items.map { "<t:ItemId Id=\"\(escaped($0.id))\" ChangeKey=\"\(escaped($0.changeKey))\"/>" }.joined())\
    </m:ItemIds></m:GetItem>
    """
}

private func escaped(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
}

/// Встречи окна из ответа `FindItem`: идентификатор и версия.
func findItems(_ doc: XMLDocument) -> [(id: String, changeKey: String)] {
    nodes(doc, "//*[local-name()='CalendarItem']/*[local-name()='ItemId']").compactMap { node in
        guard let e = node as? XMLElement, let id = e.attribute(forName: "Id")?.stringValue else { return nil }
        return (id, e.attribute(forName: "ChangeKey")?.stringValue ?? "")
    }
}

/// Встречи из ответа `GetItem`. Удалённая между запросами (`ErrorItemNotFound`) пропускается; любая другая
/// ошибка — итог всего обращения.
func events(_ doc: XMLDocument) -> (events: [Event], failure: Failure?) {
    var result: [Event] = []
    for message in nodes(doc, "//*[local-name()='GetItemResponseMessage']") {
        if (message as? XMLElement)?.attribute(forName: "ResponseClass")?.stringValue == "Error" {
            let code = text(message, "ResponseCode")
            if code == "ErrorItemNotFound" { continue }
            return ([], failure(code: code, doc: doc, now: .now))
        }
        for item in nodes(message, ".//*[local-name()='CalendarItem']") {
            guard let e = item as? XMLElement, let id = child(e, "ItemId")?.attribute(forName: "Id")?.stringValue,
                  let start = date(text(e, "Start")), let end = date(text(e, "End")) else { continue }
            let attendees = ["RequiredAttendees", "OptionalAttendees"].flatMap { list in
                nodes(e, "./*[local-name()='\(list)']/*[local-name()='Attendee']/*[local-name()='Mailbox']").map {
                    Person(name: text($0, "Name"), address: text($0, "EmailAddress"))
                }
            }
            let type = text(e, "CalendarItemType")
            result.append(Event(
                id: id,
                changeKey: child(e, "ItemId")?.attribute(forName: "ChangeKey")?.stringValue ?? "",
                uid: type.isEmpty || type == "Single" ? nil : text(e, "UID"),
                subject: text(e, "Subject"),
                start: start, end: end,
                isAllDay: text(e, "IsAllDayEvent") == "true",
                organizerName: text(e, "Organizer/Mailbox/Name"),
                organizerAddress: text(e, "Organizer/Mailbox/EmailAddress"),
                attendees: attendees,
                response: text(e, "MyResponseType"),
                isFree: text(e, "LegacyFreeBusyStatus") == "Free",
                isCancelled: text(e, "IsCancelled") == "true",
                joinURL: joinURL(location: text(e, "Location"), html: text(e, "Body")),
                description: invitationText(text(e, "TextBody"))))
        }
    }
    return (result, nil)
}

private func nodes(_ node: XMLNode, _ xpath: String) -> [XMLNode] {
    (try? node.nodes(forXPath: xpath)) ?? []
}

private func child(_ node: XMLNode, _ name: String) -> XMLElement? {
    nodes(node, "./*[local-name()='\(name)']").first as? XMLElement
}

/// Текст по пути из имён без пространств имён: `Organizer/Mailbox/Name`.
private func text(_ node: XMLNode, _ path: String) -> String {
    let xpath = "./" + path.split(separator: "/").map { "*[local-name()='\($0)']" }.joined(separator: "/")
    return nodes(node, xpath).first?.stringValue ?? ""
}

private func date(_ text: String) -> Date? {
    ISO8601DateFormatter().date(from: text)
}

private func failure(of result: Result<XMLDocument, Failure>) -> Failure? {
    if case .failure(let f) = result { return f }
    return nil
}
