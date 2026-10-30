import CryptoKit
import Foundation
import Network

// Своё соединение с Exchange вместо URLSession (2026-10-28).
//
// Симптом: Butler рос от 50 до 200 МБ за сутки. `heap` показал, что на каждый запрос к Exchange в памяти остаётся
// закрытое соединение URLSession: задача, `URLProtocol`, `HTTPConnection`, цепочка сертификатов сервера —
// на 216 запросов 198 соединений, десятки КБ каждое. `leaks --traceTree` — цикл внутри CFNetwork:
// `URLProtocol` ← блок `Tube::preConnectConfiguration` ← `ProxyConnectionEstablishment` ← `NWIOConnection`.
//
// Почему соединений столько: URLSession сама закрывает соединение, простоявшее 20–40 с (сервер держит дольше),
// а Butler спрашивает каждый ящик раз в минуту — каждый запрос шёл по новому соединению с новым входом.
//
// Что пробовали и почему не помогло:
// - Код Butler уже был по правилам: одна долгоживущая сессия на ящик. Закрыть отдельное соединение или удалить
//   состояние входа публичный API URLSession не даёт.
// - Сессия на каждое чтение с `finishTasksAndInvalidate` — так документация велит отпускать ресурсы. Утечка
//   осталась, и вдобавок остались сами сессии (то же нашли в LiveKit и cmux на macOS/iOS 26).
// - Пробы в отдельном процессе: обычные соединения, соединения, закрытые сервером, вход по Basic, отказ во входе —
//   не текут. Течёт только соединение с удачным входом по NTLM после закрытия. Это ошибка CFNetwork, не наша.
// - Keep-alive внутри URLSession: срок простоя не настраивается — держать соединение живым можно, лишь спрашивая
//   сервер чаще раза в 20 с, то есть втрое больше запросов к боевому серверу. Не годится.
//
// Поэтому своё: TLS-соединение на ящик (`Network.framework`), HTTP/1.1 и вход NTLMv2 руками. Соединение живёт,
// пока им пользуются: вход один раз, дальше запросы идут без него. Итог: те же 3 сокета часами, ни одного
// объекта URLSession, 23 МБ; запрос 0,5 с вместо 1,4.

/// TLS-соединение с Exchange на ящик и вход по NTLM на соединение.
@MainActor
final class Connection {
    private let host: String
    private let port: UInt16
    private let path: String
    private let user: String
    private let domain: String
    private let password: String
    private var connection: NWConnection?
    private var authenticated = false
    private var buffer = Data()
    private var lastUsed = Date.distantPast
    private var deadline: Task<Void, Never>?
    private var timedOut = false
    private var connecting: CheckedContinuation<Void, Error>?
    /// Запросы по соединению идут по одному: остальные ждут своей очереди.
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    /// `login` — `ДОМЕН\логин`, как в Outlook.
    init?(server: String, login: String, password: String) {
        guard let url = URL(string: server), url.scheme == "https", let host = url.host() else { return nil }
        let parts = login.split(separator: "\\", maxSplits: 1).map(String.init)
        (self.host, port, path) = (host, UInt16(url.port ?? 443), url.path().isEmpty ? "/" : url.path())
        (domain, user) = parts.count == 2 ? (parts[0], parts[1]) : ("", login)
        self.password = password
    }

    func close() {
        connecting?.resume(throwing: URLError(.networkConnectionLost))
        connecting = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        authenticated = false
        buffer = Data()
    }

    /// POST тела SOAP. Ошибки — `URLError`, как у URLSession: их разбирает `outcome`.
    func post(_ body: Data) async throws -> (Data, HTTPURLResponse) {
        if busy { await withCheckedContinuation { waiting.append($0) } }
        busy = true
        defer { if waiting.isEmpty { busy = false } else { waiting.removeFirst().resume() } }
        timedOut = false
        do {
            let reply = try await send(body)
            lastUsed = .now
            let response = HTTPURLResponse(url: URL(string: "https://\(host)\(path)")!, statusCode: reply.status,
                                           httpVersion: "HTTP/1.1", headerFields: reply.headers)!
            return (reply.body, response)
        } catch {
            close()
            throw urlError(error)
        }
    }

    // MARK: - HTTP

    private struct Reply {
        var status: Int
        var headers: [String: String]
        var challenge: Data?
        var body: Data
    }

    /// Соединение, простоявшее больше 90 с, — заново: IIS закрывает простаивающее через 120 с, а после сна
    /// сокет может быть мёртв. Вход сервер забывает раньше — между 40 и 65 с, — поэтому после 30 с вход сразу,
    /// без лишнего отказа. Если сервер всё же закрыл соединение, это видно на первом запросе — один повтор
    /// на новом соединении; чтения Exchange повторять безопасно.
    private func send(_ body: Data) async throws -> Reply {
        let idle = Date.now.timeIntervalSince(lastUsed)
        if idle > 90 { close() }
        if idle > 30 { authenticated = false }
        let fresh = connection == nil
        do {
            if fresh { try await connect() }
            guard authenticated else { return try await login(body) }
            let reply = try await roundTrip(body, authorization: nil)
            if reply.status == 401 {
                authenticated = false
                return try await login(body)
            }
            return reply
        } catch let error where !fresh && !timedOut && isLost(error) {
            close()
            return try await send(body)
        }
    }

    /// Вход по NTLM: NEGOTIATE без тела, CHALLENGE от сервера, AUTHENTICATE вместе с запросом. Отвергнутый
    /// пароль второй раз не предлагается — доменную учётку не заблокируют.
    private func login(_ body: Data) async throws -> Reply {
        let first = try await roundTrip(Data(), authorization: "NTLM " + NTLM.negotiate().base64EncodedString())
        guard first.status == 401, let challenge = first.challenge,
              let answer = NTLM.authenticate(challenge, user: user, domain: domain, password: password)
        else { return first }
        let reply = try await roundTrip(body, authorization: "NTLM " + answer.base64EncodedString())
        if reply.status == 401 { throw URLError(.userAuthenticationRequired) }
        authenticated = connection != nil
        return reply
    }

    private func connect() async throws {
        close()
        let connection = NWConnection(host: .init(host), port: .init(rawValue: port)!, using: .tls)
        self.connection = connection
        armDeadline()
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            connecting = done
            connection.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated { self?.changed(state) }
            }
            connection.start(queue: .main)
        }
    }

    /// Соединение открылось — запрос идёт дальше; сбой или ожидание сети — соединение закрывается, а запрос,
    /// который его ждёт, узнаёт причину. Обработчик есть только у текущего соединения: `close` его снимает.
    private func changed(_ state: NWConnection.State) {
        switch state {
        case .ready:
            connecting?.resume()
        case .waiting(let error), .failed(let error):
            connection?.cancel()
            connecting?.resume(throwing: error)
        case .cancelled:
            connecting?.resume(throwing: URLError(.networkConnectionLost))
        default:
            return
        }
        connecting = nil
    }

    private func roundTrip(_ body: Data, authorization: String?) async throws -> Reply {
        var head = "POST \(path) HTTP/1.1\r\nHost: \(host)\r\nContent-Type: text/xml; charset=utf-8\r\nContent-Length: \(body.count)\r\nAccept-Encoding: gzip\r\n"
        if let authorization { head += "Authorization: \(authorization)\r\n" }
        armDeadline()
        defer { deadline?.cancel() }
        try await write(Data((head + "\r\n").utf8) + body)
        return try await reply()
    }

    private func reply() async throws -> Reply {
        let lines = String(decoding: try await line(until: "\r\n\r\n"), as: UTF8.self).components(separatedBy: "\r\n")
        var result = Reply(status: lines.first?.split(separator: " ").dropFirst().first.flatMap { Int($0) } ?? 0, headers: [:], body: Data())
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let (name, value) = (line[..<colon].lowercased(), line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
            if name == "www-authenticate", value.hasPrefix("NTLM ") { result.challenge = Data(base64Encoded: String(value.dropFirst(5))) }
            result.headers[name] = value
        }
        if result.headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            while let size = Int(String(decoding: try await line(until: "\r\n"), as: UTF8.self).prefix { $0 != ";" }
                .trimmingCharacters(in: .whitespaces), radix: 16), size > 0 {
                result.body += try await bytes(size)
                _ = try await bytes(2)
            }
            var trailer: Data
            repeat { trailer = try await line(until: "\r\n") } while !trailer.isEmpty
        } else {
            result.body = try await bytes(Int(result.headers["content-length"] ?? "") ?? 0)
        }
        if result.headers["connection"]?.lowercased() == "close" { close() }
        if result.headers["content-encoding"]?.lowercased() == "gzip" {
            guard let body = gunzip(result.body) else { throw URLError(.cannotDecodeContentData) }
            result.body = body
        }
        return result
    }

    /// Ответы — в gzip, как у URLSession: XML сжимается раз в восемь, месяц приходит за секунды, а не за минуту.
    /// `NSData` распаковывает только сам deflate — заголовок и хвост gzip (RFC 1952) снимаются здесь.
    private func gunzip(_ data: Data) -> Data? {
        let b = [UInt8](data)
        guard b.count > 18, b[0] == 0x1f, b[1] == 0x8b, b[2] == 8 else { return nil }
        var i = 10
        if b[3] & 4 != 0 { i += 2 + (Int(b[i]) | Int(b[i + 1]) << 8) }
        for flag: UInt8 in [8, 16] where b[3] & flag != 0 {
            while i < b.count, b[i] != 0 { i += 1 }
            i += 1
        }
        if b[3] & 2 != 0 { i += 2 }
        guard i < b.count - 8 else { return nil }
        return try? (Data(b[i..<b.count - 8]) as NSData).decompressed(using: .zlib) as Data
    }

    private func line(until delimiter: String) async throws -> Data {
        let delimiter = Data(delimiter.utf8)
        while true {
            if let range = buffer.range(of: delimiter) {
                defer { buffer.removeSubrange(..<range.upperBound) }
                return Data(buffer[..<range.lowerBound])
            }
            try await receive()
        }
    }

    private func bytes(_ count: Int) async throws -> Data {
        while buffer.count < count { try await receive() }
        defer { buffer.removeFirst(count) }
        return Data(buffer.prefix(count))
    }

    private func write(_ data: Data) async throws {
        guard let connection else { throw URLError(.networkConnectionLost) }
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { done.resume(throwing: error) } else { done.resume() }
            })
        }
    }

    private func receive() async throws {
        guard let connection else { throw URLError(.networkConnectionLost) }
        let data = try await withCheckedThrowingContinuation { (done: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, error in
                if let data, !data.isEmpty { done.resume(returning: data) }
                else { done.resume(throwing: error ?? URLError(.networkConnectionLost)) }
            }
        }
        buffer += data
        armDeadline()
    }

    /// 30 с тишины — запрос не ответил, как `timeoutIntervalForRequest` у URLSession.
    private func armDeadline() {
        deadline?.cancel()
        deadline = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled, let self else { return }
            self.timedOut = true
            self.connection?.cancel()
        }
    }

    private func isLost(_ error: Error) -> Bool {
        if let error = error as? URLError { return error.code == .networkConnectionLost }
        guard case .posix(let code)? = error as? NWError else { return false }
        return [.ECONNRESET, .EPIPE, .ECANCELED, .ENOTCONN].contains(code)
    }

    private func urlError(_ error: Error) -> Error {
        if timedOut { return URLError(.timedOut) }
        guard let error = error as? NWError else { return error }
        switch error {
        case .dns: return URLError(.cannotFindHost)
        case .tls(let status) where [errSSLXCertChainInvalid, errSSLBadCert, errSSLUnknownRootCert, errSSLNoRootCert,
                                     errSSLCertExpired, errSSLCertNotYetValid, errSSLHostNameMismatch].contains(status):
            return URLError(.serverCertificateUntrusted)
        case .posix(let code) where [.ENETDOWN, .ENETUNREACH, .EHOSTDOWN, .EHOSTUNREACH].contains(code):
            return URLError(.notConnectedToInternet)
        case .posix(.ECONNREFUSED): return URLError(.cannotConnectToHost)
        case .posix where isLost(error): return URLError(.networkConnectionLost)
        default: return URLError(.unknown, userInfo: [NSLocalizedDescriptionKey: error.localizedDescription])
        }
    }
}

// MARK: - NTLMv2 (MS-NLMP)

/// Сообщения NTLMv2 такие же, как у NTLM в URLSession, — с ним этот сервер пускает: LMv2 и NTv2 с временем
/// клиента, сведения сервера без изменений, без MIC и привязки к TLS.
enum NTLM {
    /// UNICODE, REQUEST_TARGET, NTLM, ALWAYS_SIGN, EXTENDED_SESSIONSECURITY.
    private static let flags: UInt32 = 0x0000_0001 | 0x0000_0004 | 0x0000_0200 | 0x0000_8000 | 0x0008_0000

    static func negotiate() -> Data {
        Data("NTLMSSP\0".utf8) + le32(1) + le32(flags) + Data(count: 16)
    }

    /// AUTHENTICATE на CHALLENGE сервера; `nil` — это не CHALLENGE.
    static func authenticate(_ challenge: Data, user: String, domain: String, password: String, time: Date = .now,
                             client: Data = Data((0..<8).map { _ in UInt8.random(in: 0...255) })) -> Data? {
        let c = [UInt8](challenge)
        guard c.count >= 48, c.starts(with: Array("NTLMSSP\0".utf8)), u32(c, 8) == 2 else { return nil }
        let (infoLength, infoOffset) = (Int(u16(c, 40)), Int(u32(c, 44)))
        guard infoOffset + infoLength <= c.count else { return nil }
        let (key, server) = (hash(user: user, domain: domain, password: password), Data(c[24..<32]))
        let lm = hmac(key, server + client) + client
        let nt = ntResponse(key, server: server, info: Data(c[infoOffset..<infoOffset + infoLength]), time: filetime(time), client: client)
        let fields = [lm, nt, utf16(domain), utf16(user), utf16("WORKSTATION"), Data()]
        var message = Data("NTLMSSP\0".utf8) + le32(3)
        var offset = 64
        for field in fields {
            message += le16(UInt16(field.count)) + le16(UInt16(field.count)) + le32(UInt32(field.isEmpty ? 0 : offset))
            offset += field.count
        }
        return message + le32(flags & u32(c, 20)) + fields.reduce(Data(), +)
    }

    /// NTOWFv2 (MS-NLMP 3.3.2).
    static func hash(user: String, domain: String, password: String) -> Data {
        hmac(Data(md4([UInt8](utf16(password)))), utf16(user.uppercased() + domain))
    }

    /// NTProofStr и blob (MS-NLMP 3.3.2).
    static func ntResponse(_ key: Data, server: Data, info: Data, time: Data, client: Data) -> Data {
        let blob = Data([1, 1, 0, 0, 0, 0, 0, 0]) + time + client + Data(count: 4) + info + Data(count: 4)
        return hmac(key, server + blob) + blob
    }

    /// Сотни наносекунд с 1601 года — FILETIME Windows.
    private static func filetime(_ date: Date) -> Data {
        let value = UInt64((date.timeIntervalSince1970 + 11_644_473_600) * 10_000_000)
        return Data((0..<8).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) })
    }

    private static func hmac(_ key: Data, _ data: Data) -> Data {
        Data(HMAC<Insecure.MD5>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }

    private static func utf16(_ text: String) -> Data { text.data(using: .utf16LittleEndian)! }
    private static func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
    private static func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
    private static func u16(_ b: [UInt8], _ i: Int) -> UInt16 { UInt16(b[i]) | UInt16(b[i + 1]) << 8 }
    private static func u32(_ b: [UInt8], _ i: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(b[i + $1]) << (8 * $1) } }

    /// MD4 (RFC 1320) — его требует NTLM, а в CryptoKit его нет.
    static func md4(_ message: [UInt8]) -> [UInt8] {
        var m = message + [0x80]
        while m.count % 64 != 56 { m.append(0) }
        m += (0..<8).map { UInt8(truncatingIfNeeded: (UInt64(message.count) * 8) >> (8 * $0)) }
        var (a, b, c, d): (UInt32, UInt32, UInt32, UInt32) = (0x6745_2301, 0xefcd_ab89, 0x98ba_dcfe, 0x1032_5476)
        func rotl(_ x: UInt32, _ n: UInt32) -> UInt32 { x << n | x >> (32 - n) }
        func f(_ x: UInt32, _ y: UInt32, _ z: UInt32) -> UInt32 { x & y | ~x & z }
        func g(_ x: UInt32, _ y: UInt32, _ z: UInt32) -> UInt32 { x & y | x & z | y & z }
        func h(_ x: UInt32, _ y: UInt32, _ z: UInt32) -> UInt32 { x ^ y ^ z }
        for chunk in stride(from: 0, to: m.count, by: 64) {
            let x = (0..<16).map { u32(m, chunk + $0 * 4) }
            let (aa, bb, cc, dd) = (a, b, c, d)
            for i in [0, 4, 8, 12] {
                a = rotl(a &+ f(b, c, d) &+ x[i], 3); d = rotl(d &+ f(a, b, c) &+ x[i + 1], 7)
                c = rotl(c &+ f(d, a, b) &+ x[i + 2], 11); b = rotl(b &+ f(c, d, a) &+ x[i + 3], 19)
            }
            for i in [0, 1, 2, 3] {
                a = rotl(a &+ g(b, c, d) &+ x[i] &+ 0x5a82_7999, 3); d = rotl(d &+ g(a, b, c) &+ x[i + 4] &+ 0x5a82_7999, 5)
                c = rotl(c &+ g(d, a, b) &+ x[i + 8] &+ 0x5a82_7999, 9); b = rotl(b &+ g(c, d, a) &+ x[i + 12] &+ 0x5a82_7999, 13)
            }
            for i in [0, 2, 1, 3] {
                a = rotl(a &+ h(b, c, d) &+ x[i] &+ 0x6ed9_eba1, 3); d = rotl(d &+ h(a, b, c) &+ x[i + 8] &+ 0x6ed9_eba1, 9)
                c = rotl(c &+ h(d, a, b) &+ x[i + 4] &+ 0x6ed9_eba1, 11); b = rotl(b &+ h(c, d, a) &+ x[i + 12] &+ 0x6ed9_eba1, 15)
            }
            (a, b, c, d) = (a &+ aa, b &+ bb, c &+ cc, d &+ dd)
        }
        return [a, b, c, d].flatMap { v in (0..<4).map { UInt8(truncatingIfNeeded: v >> (8 * $0)) } }
    }
}
