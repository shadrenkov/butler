import Foundation
import Testing
@testable import Butler

// Связь с Exchange: разбор ответов, сборка дня, итоги обращений и когда пробовать снова.
// Ответы написаны вручную по образцу настоящих — живых данных здесь нет, к серверу тесты не обращаются.

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func soap(_ body: String) -> Data {
    Data("""
    <?xml version="1.0" encoding="utf-8"?>
    <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"
      xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages"
      xmlns:t="http://schemas.microsoft.com/exchange/services/2006/types"><s:Body>\(body)</s:Body></s:Envelope>
    """.utf8)
}

private func doc(_ body: String) -> XMLDocument {
    try! XMLDocument(data: soap(body))
}

private func http(_ status: Int, _ headers: [String: String] = [:]) -> HTTPURLResponse {
    HTTPURLResponse(url: URL(string: "https://mail.example.com/EWS/Exchange.asmx")!, statusCode: status, httpVersion: nil, headerFields: headers)!
}

private func item(id: String, type: String = "Single", uid: String = "UID-1", allDay: Bool = false, cancelled: Bool = false,
                  freeBusy: String = "Busy", response: String = "Accept", location: String = "", body: String = "",
                  text: String = "") -> String {
    """
    <t:CalendarItem>
      <t:ItemId Id="\(id)" ChangeKey="K-\(id)"/>
      <t:Subject>Планёрка</t:Subject>
      <t:Body BodyType="HTML">\(body)</t:Body>
      <t:TextBody BodyType="Text">\(text)</t:TextBody>
      <t:Start>2027-01-15T07:00:00Z</t:Start>
      <t:End>2027-01-15T07:30:00Z</t:End>
      <t:IsAllDayEvent>\(allDay)</t:IsAllDayEvent>
      <t:LegacyFreeBusyStatus>\(freeBusy)</t:LegacyFreeBusyStatus>
      <t:Location>\(location)</t:Location>
      <t:Organizer><t:Mailbox><t:Name>Иванов Пётр Сергеевич</t:Name><t:EmailAddress>ivanov@example.com</t:EmailAddress></t:Mailbox></t:Organizer>
      <t:RequiredAttendees>
        <t:Attendee><t:Mailbox><t:Name>Петрова Анна</t:Name><t:EmailAddress>petrova@example.com</t:EmailAddress></t:Mailbox></t:Attendee>
      </t:RequiredAttendees>
      <t:OptionalAttendees>
        <t:Attendee><t:Mailbox><t:Name></t:Name><t:EmailAddress>guest@other.com</t:EmailAddress></t:Mailbox></t:Attendee>
      </t:OptionalAttendees>
      <t:IsCancelled>\(cancelled)</t:IsCancelled>
      <t:CalendarItemType>\(type)</t:CalendarItemType>
      <t:MyResponseType>\(response)</t:MyResponseType>
      <t:UID>\(uid)</t:UID>
    </t:CalendarItem>
    """
}

private func getItem(_ messages: String...) -> XMLDocument {
    doc("<m:GetItemResponse><m:ResponseMessages>\(messages.joined())</m:ResponseMessages></m:GetItemResponse>")
}

private func success(_ items: String...) -> String {
    """
    <m:GetItemResponseMessage ResponseClass="Success"><m:ResponseCode>NoError</m:ResponseCode>\
    <m:Items>\(items.joined())</m:Items></m:GetItemResponseMessage>
    """
}

private func error(_ code: String) -> String {
    #"<m:GetItemResponseMessage ResponseClass="Error"><m:MessageText>…</m:MessageText><m:ResponseCode>\#(code)</m:ResponseCode></m:GetItemResponseMessage>"#
}

// Разбор ответов.

@Test func findItemListsIdsAndVersions() {
    let found = findItems(doc("""
    <m:FindItemResponse><m:ResponseMessages><m:FindItemResponseMessage ResponseClass="Success">
    <m:ResponseCode>NoError</m:ResponseCode><m:RootFolder TotalItemsInView="2"><t:Items>
    <t:CalendarItem><t:ItemId Id="A" ChangeKey="1"/></t:CalendarItem>
    <t:CalendarItem><t:ItemId Id="B" ChangeKey="2"/></t:CalendarItem>
    </t:Items></m:RootFolder></m:FindItemResponseMessage></m:ResponseMessages></m:FindItemResponse>
    """))
    #expect(found.map(\.id) == ["A", "B"])
    #expect(found.map(\.changeKey) == ["1", "2"])
    #expect(findItems(doc("<m:FindItemResponse/>")).isEmpty)
}

@Test func getItemReadsEveryField() {
    let (events, failure) = events(getItem(success(
        item(id: "A"),
        item(id: "B", type: "Occurrence", uid: "SERIES", allDay: true, cancelled: true, freeBusy: "Free", response: "Organizer"))))
    #expect(failure == nil)
    let single = events[0], occurrence = events[1]
    #expect(single.id == "A" && single.changeKey == "K-A" && single.uid == nil)
    #expect(single.subject == "Планёрка" && single.start == ISO8601DateFormatter().date(from: "2027-01-15T07:00:00Z"))
    #expect(single.organizerName == "Иванов Пётр Сергеевич" && single.organizerAddress == "ivanov@example.com")
    #expect(single.attendees == [Person(name: "Петрова Анна", address: "petrova@example.com"), Person(name: "", address: "guest@other.com")])
    #expect(single.response == "Accept" && !single.isFree && !single.isCancelled && !single.isAllDay)
    #expect(occurrence.uid == "SERIES" && occurrence.isAllDay && occurrence.isCancelled && occurrence.isFree)
    #expect(occurrence.response == "Organizer")
}

@Test func meetingDeletedBetweenRequestsIsSkippedOtherErrorsFail() {
    let (events, failure) = events(getItem(error("ErrorItemNotFound"), success(item(id: "A"))))
    #expect(events.map(\.id) == ["A"] && failure == nil)
    #expect(Butler.events(getItem(error("ErrorAccessDenied"))).failure == .noAccess("ErrorAccessDenied"))
}

@Test func linkAndDescriptionComeFromTheInvitation() {
    let html = "&lt;p&gt;Повестка&lt;/p&gt;&lt;a href=&quot;https://my.mts-link.ru/j/1?a=1&amp;amp;b=2&quot;&gt;войти&lt;/a&gt;"
    let text = "Повестка\r\n\r\n\r\nhttps://my.mts-link.ru/j/1\r\nСсылка на встречу: https://my.mts-link.ru/j/1\r\nSIP: 123"
    let e = events(getItem(success(item(id: "A", body: html, text: text)))).events[0]
    #expect(e.joinURL == URL(string: "https://my.mts-link.ru/j/1?a=1&b=2"))
    #expect(e.description == "Повестка")
}

// Ссылка для подключения: открывается на моём Mac, поэтому правила строгие.

@Test func meetingLinkWinsAndHostIsComparedAsHost() {
    #expect(joinURL(location: "https://my.mts-link.ru/j/1", html: "https://example.com/x") == URL(string: "https://my.mts-link.ru/j/1"))
    #expect(joinURL(location: "https://zoom.example.com/1", html: "https://team.mts-link.ru/j/2") == URL(string: "https://team.mts-link.ru/j/2"))
    #expect(joinURL(location: "", html: "https://mts-link.ru.example.com/x https://mts-link.ru@example.com/x") == nil)
    #expect(joinURL(location: "http://my.mts-link.ru/j/1", html: "") == nil)
    #expect(joinURL(location: "Ссылка: https://zoom.example.com/1.", html: "") == URL(string: "https://zoom.example.com/1"))
    #expect(joinURL(location: "Переговорная 5", html: "https://example.com/logo.png") == nil)
}

@Test func invitationTextStopsAtTheLinkBlock() {
    #expect(invitationText("Обсудим план\nMeeting ID: 123\nПароль") == "Обсудим план")
    #expect(invitationText("  Идентификатор встречи: 5\nтекст") == nil)
    #expect(invitationText("https://my.mts-link.ru/j/1\nПовестка") == "Повестка")
    #expect(invitationText(String(repeating: "а", count: 5000))?.count == 4000)
    #expect(invitationText("") == nil)
}

@Test func invitationTextDropsTracesOfHTML() {
    let text = "[cid:image002.png@01DD]\nПиши: a@example.com<mailto:a@example.com> — ответим.\n·         пункт\n[cid:x.png]<https://my.mts-link.ru/j/1>\n________________________________"
    #expect(invitationText(text) == "Пиши: a@example.com — ответим.\n· пункт")
}

// Сборка дня из кэшей ящиков.

private func event(_ id: String, start: Date, minutes: Double = 30, response: String = "NoResponseReceived",
                   cancelled: Bool = false, attendees: [Person] = [], uid: String? = nil) -> Event {
    Event(id: id, changeKey: "1", uid: uid, subject: "Встреча", start: start, end: start + minutes * 60, isAllDay: false,
          organizerName: "Иванов Пётр Сергеевич", organizerAddress: "ivanov@example.com", attendees: attendees,
          response: response, isFree: false, isCancelled: cancelled, joinURL: nil, description: nil)
}

@Test func copiesFromTwoMailboxesBecomeOneMeeting() {
    let (start, _) = bounds("2027-01-15")!
    let at = start + 10 * 3600
    let people = [Person(name: "Я", address: "Me@example.com"), Person(name: "Иванов Пётр Сергеевич", address: "ivanov@example.com"),
                  Person(name: "", address: "guest@other.com")]
    let boxes = [
        "me@example.com": Box(events: [event("first", start: at, attendees: people), event("gone", start: at + 3600, cancelled: true)]),
        "work@example.com": Box(events: [event("second", start: at, response: "Accept", attendees: people)]),
    ]
    let day = assemble(boxes, order: ["me@example.com", "work@example.com"], day: "2027-01-15", config: Config())
    #expect(day.map(\.eventId) == ["first"])
    #expect(day[0].isAccepted == true && day[0].isOrganizer == false)
    #expect(day[0].attendees == ["guest@other.com"])
}

@Test func meetingOverMidnightIsInBothDays() {
    let (_, end) = bounds("2027-01-15")!
    let boxes = ["me@example.com": Box(events: [event("late", start: end - 3600, minutes: 120)])]
    for day in ["2027-01-15", "2027-01-16"] {
        #expect(assemble(boxes, order: ["me@example.com"], day: day, config: Config()).map(\.eventId) == ["late"])
    }
    #expect(assemble(boxes, order: ["me@example.com"], day: "2027-01-17", config: Config()).isEmpty)
}

@Test func vipByOrganizerFragmentOrBySeries() {
    let (start, _) = bounds("2027-01-15")!
    var config = Config()
    config.vipOrganizers = ["иванов пётр"]
    let boxes = ["me@example.com": Box(events: [event("a", start: start + 3600, uid: "S")])]
    #expect(assemble(boxes, order: ["me@example.com"], day: "2027-01-15", config: config)[0].isVIP)
    config.vipOrganizers = []
    #expect(!assemble(boxes, order: ["me@example.com"], day: "2027-01-15", config: config)[0].isVIP)
    // VIP среди участников — встреча тоже VIP.
    config.vipOrganizers = ["Петрова Анна"]
    let withGuest = ["me@example.com": Box(events: [event("b", start: start + 3600,
                                                           attendees: [Person(name: "Петрова Анна Ивановна", address: "petrova@example.com")])])]
    #expect(assemble(withGuest, order: ["me@example.com"], day: "2027-01-15", config: config)[0].isVIP)
    #expect(!assemble(boxes, order: ["me@example.com"], day: "2027-01-15", config: config)[0].isVIP)
    config.vipOrganizers = []
    config.vipMeetings = ["S": try! JSONDecoder().decode(Config.Hidden.self, from: Data(#""Серия""#.utf8))]
    #expect(assemble(boxes, order: ["me@example.com"], day: "2027-01-15", config: config)[0].isVIP)
}

@Test func manualMarkOverridesTheRule() {
    let (start, _) = bounds("2027-01-15")!
    var config = Config()
    config.vipOrganizers = ["Иванов Пётр"]
    config.vipMeetings = ["S": try! JSONDecoder().decode(Config.Hidden.self, from: Data(#"{"subject": "Серия", "vip": false}"#.utf8))]
    let boxes = ["me@example.com": Box(events: [event("a", start: start + 3600, uid: "S"), event("b", start: start + 7200)])]
    let day = assemble(boxes, order: ["me@example.com"], day: "2027-01-15", config: config)
    #expect(day.map(\.isVIP) == [false, true])
}

// Итоги обращений: от них зависит, засыпем ли мы боевой сервер или молча потеряем ящик.

@Test func throttlingKeepsTheServersWholeWait() {
    let fault = soap("""
    <s:Fault><faultcode xmlns:a="http://schemas.microsoft.com/exchange/services/2006/types">a:ErrorServerBusy</faultcode>
    <faultstring xml:lang="en-US">The server cannot service this request right now. Try again later.</faultstring>
    <detail><e:ResponseCode xmlns:e="http://schemas.microsoft.com/exchange/services/2006/errors">ErrorServerBusy</e:ResponseCode>
    <t:MessageXml><t:Value Name="BackOffMilliseconds">320000</t:Value></t:MessageXml></detail></s:Fault>
    """)
    #expect(failure(outcome(data: fault, response: http(500), now: t0)) == .throttled(until: t0 + 320))
    #expect(failure(outcome(data: Data(), response: http(503, ["Retry-After": "120"]), now: t0)) == .throttled(until: t0 + 120))
}

@Test func answersThatStopTheMailbox() {
    let noMailbox = soap(#"<m:FindItemResponse><m:ResponseMessages><m:FindItemResponseMessage ResponseClass="Error"><m:ResponseCode>ErrorNonExistentMailbox</m:ResponseCode></m:FindItemResponseMessage></m:ResponseMessages></m:FindItemResponse>"#)
    #expect(failure(outcome(data: noMailbox, response: http(200), now: t0)) == .noAccess("ErrorNonExistentMailbox"))
    #expect(failure(outcome(data: Data("<html><body>Outlook</body></html>".utf8), response: http(200), now: t0)) == .badServer("ответ не от Exchange"))
    #expect(failure(outcome(data: Data(), response: http(404), now: t0)) == .badServer("сервер ответил 404"))
    #expect(failure(outcome(data: Data(), response: http(401), now: t0)) == .unauthorized)
    #expect(outcome(URLError(.cancelled)) == .unauthorized)
    #expect(outcome(URLError(.serverCertificateUntrusted)) == .certificate)
}

@Test func unknownTroubleIsTemporary() {
    let broken = soap("<s:Fault><faultcode>a:ErrorInternalServerError</faultcode></s:Fault>")
    #expect(failure(outcome(data: broken, response: http(500), now: t0)) == .server("ErrorInternalServerError"))
    #expect(failure(outcome(data: Data("oops".utf8), response: http(502), now: t0)) == .server("сервер ответил 502"))
    #expect(outcome(URLError(.notConnectedToInternet)) == .offline)
    #expect(outcome(URLError(.cannotFindHost)) == .offline)
    #expect(outcome(URLError(.timedOut)) == .server("не ответил за 30 с"))
    #expect(outcome(URLError(.secureConnectionFailed)) == .server(URLError(.secureConnectionFailed).localizedDescription))
}

@Test func goodAnswerIsADocument() {
    let ok = soap(#"<m:FindItemResponse><m:ResponseMessages><m:FindItemResponseMessage ResponseClass="Success"><m:ResponseCode>NoError</m:ResponseCode></m:FindItemResponseMessage></m:ResponseMessages></m:FindItemResponse>"#)
    #expect(failure(outcome(data: ok, response: http(200), now: t0)) == nil)
}

private func failure(_ result: Result<XMLDocument, Failure>) -> Failure? {
    if case .failure(let f) = result { return f }
    return nil
}

// Когда пробовать снова.

@Test func retriesBackOffAndStopsWhereTheyMust() {
    #expect(retryAt(.offline, failures: 7, now: t0) == t0 + 120)
    #expect((1...6).map { retryAt(.server("x"), failures: $0, now: t0)!.timeIntervalSince(t0) } == [120, 240, 480, 960, 1800, 1800])
    #expect(retryAt(.throttled(until: t0 + 320), failures: 1, now: t0) == t0 + 600)
    #expect(retryAt(.throttled(until: t0 + 3600), failures: 1, now: t0) == t0 + 3600)
    for stopping in [Failure.unauthorized, .noAccess("x"), .certificate, .badServer("x"), .overLimit, .noPassword] {
        #expect(retryAt(stopping, failures: 1, now: t0) == nil)
    }
}

@Test func guardStopsTheRequestOverTheHourlyLimit() {
    var requests: [Date] = []
    for i in 0..<hourlyLimit { #expect(allowed(&requests, now: t0 + Double(i) / 2)) }
    #expect(!allowed(&requests, now: t0 + 1200))
    #expect(requests.count == hourlyLimit)
    #expect(allowed(&requests, now: t0 + 3600))
}

@Test func dueEveryTenMinutesOrWhenTheFailureSays() {
    #expect(isDue(nil, hasPassword: true, now: t0, wake: false))
    #expect(!isDue(Box(windowAt: t0), hasPassword: true, now: t0 + 599, wake: false))
    #expect(isDue(Box(windowAt: t0, success: t0 + 590), hasPassword: true, now: t0 + 600, wake: false))
    let offline = Box(failure: .offline, retryAt: t0 + 120)
    #expect(!isDue(offline, hasPassword: true, now: t0 + 60, wake: false))
    #expect(isDue(offline, hasPassword: true, now: t0 + 60, wake: true))
    let throttled = Box(failure: .throttled(until: t0 + 900), retryAt: t0 + 900)
    #expect(!isDue(throttled, hasPassword: true, now: t0 + 60, wake: true))
    #expect(!isDue(Box(failure: .unauthorized), hasPassword: true, now: t0 + 86_400, wake: true))
    #expect(!isDue(Box(failure: .noPassword), hasPassword: false, now: t0, wake: false))
    #expect(isDue(Box(failure: .noPassword), hasPassword: true, now: t0, wake: false))
}

@Test func alarmAfterTenMinutesOfFailureOrAtOnceWhenStopped() {
    let boxes = ["a@x": Box(success: t0, failure: .offline, failingSince: t0 + 60), "b@x": Box(success: t0 + 30)]
    let mailboxes = [Mailbox(address: "a@x", login: "l", server: "https://s"), Mailbox(address: "b@x", login: "l", server: "https://s")]
    #expect(outage(boxes, mailboxes: mailboxes, now: t0 + 659) == nil)
    let alarm = outage(boxes, mailboxes: mailboxes, now: t0 + 660)
    #expect(alarm?.since == t0 && alarm?.lines == ["a@x: нет сети или VPN"])
    #expect(outage(["a@x": Box(failure: .unauthorized, failingSince: t0)], mailboxes: mailboxes, now: t0) != nil)
    #expect(outage(["a@x": Box(failure: .noPassword)], mailboxes: mailboxes, now: t0 + 9999) == nil)
}

// Текст ящиков в настройках.

@Test func mailboxesFromIniSkipCommentsAndBlankLines() throws {
    let text = """
    # мои ящики
    [me@example.com]
    login = DOM\\me
    password = p=ss word
    server=https://mail.example.com/EWS/Exchange.asmx

    ; второй
    [work@example.com]
      server = mail.example.com
      login = DOM\\work

    [odd@example.com]
    login = DOM\\odd
    server = https://mail.example.com/ews/other.asmx
    """
    let boxes = try mailboxes(from: text)
    #expect(boxes == [Mailbox(address: "me@example.com", login: "DOM\\me", server: "https://mail.example.com/EWS/Exchange.asmx",
                              password: "p=ss word"),
                      Mailbox(address: "work@example.com", login: "DOM\\work", server: "https://mail.example.com/EWS/Exchange.asmx"),
                      Mailbox(address: "odd@example.com", login: "DOM\\odd", server: "https://mail.example.com/ews/other.asmx")])
    #expect(Butler.text(of: boxes).contains("server = mail.example.com\n") && Butler.text(of: boxes).contains("other.asmx"))
    #expect(try mailboxes(from: Butler.text(of: boxes)) == boxes)
    #expect(try mailboxes(from: "").isEmpty)
}

@Test func mailboxTextErrorsNameTheLine() {
    func problem(_ text: String) -> String? {
        do { _ = try mailboxes(from: text); return nil } catch { return error.localizedDescription }
    }
    #expect(problem("login = a") == "строка 1: сначала [адрес ящика]")
    #expect(problem("[me@x]\nlogin = a") == "строка 1: у [me@x] нет server")
    #expect(problem("[me@x]\nlogin = a\nserver = http://s") == "строка 1: у [me@x] server не https://")
    #expect(problem("[me@x]\nпароль = 1") == "строка 2: нужно «login = …», «server = …» или «password = …»")
    #expect(problem("[me]") == "строка 1: в [ ] нужен адрес ящика")
    #expect(problem("[me@x\nlogin = a") == "строка 1: секция закрывается «]»")
    #expect(problem("[me@x]\nlogin = a\nserver = https://s\n[ME@x]") == "строка 4: ящик ME@x уже есть")
}

@Test func passwordsAreSealedAndOpenedBack() {
    let stored = sealed("пароль 1")
    #expect(stored.hasPrefix("enc:") && !stored.contains("пароль"))
    #expect(opened(stored) == "пароль 1")
    #expect(sealed(stored) == stored && sealed("") == "")
    #expect(opened("открытый") == "открытый")
    #expect(opened("enc:" + Data(repeating: 7, count: 40).base64EncodedString()) == "")
}

// Вход по NTLM: ошибка в шифровании видна лишь как «неверный пароль», поэтому сверка с примером из MS-NLMP 4.2.4.

private func hex(_ text: String) -> Data {
    Data(stride(from: 0, to: text.count, by: 2).map { UInt8(text.dropFirst($0).prefix(2), radix: 16)! })
}

@Test func md4MatchesTheRFC() {
    #expect(Data(NTLM.md4([])) == hex("31d6cfe0d16ae931b73c59d7e0c089c0"))
    #expect(Data(NTLM.md4(Array("message digest".utf8))) == hex("d9130a8164549fe818874806e1c7014b"))
    #expect(Data(NTLM.md4(Array(String(repeating: "1234567890", count: 8).utf8))) == hex("e33b4ddc9c38f2199c3e7b164fcc0536"))
}

@Test func ntlmV2ResponseMatchesTheSpec() {
    let info = hex("02000c0044006f006d00610069006e0001000c0053006500720076006500720000000000")
    let response = NTLM.ntResponse(NTLM.hash(user: "User", domain: "Domain", password: "Password"), server: hex("0123456789abcdef"),
                                   info: info, time: Data(count: 8), client: hex("aaaaaaaaaaaaaaaa"))
    #expect(response.prefix(16) == hex("68cd0ab851e51c96aabc927bebef6a1c"))
}
