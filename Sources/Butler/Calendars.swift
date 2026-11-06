import EventKit
import SwiftUI

/// Календари Mac — только чтение через EventKit: повторы, часовые пояса и синхронизацию с Google и iCloud
/// делает система. Встречи кладутся в те же `Box`, что у ящиков Exchange, под ключом `mac:<calendarIdentifier>`,
/// и собираются тем же `assemble`.
@MainActor let store = EKEventStore()

/// Встречи Mac есть, только когда доступ дан полностью. Запрашивает его одно окно «Календари Mac».
var hasCalendarAccess: Bool {
    EKEventStore.authorizationStatus(for: .event) == .fullAccess && !offlineMode
}

@MainActor func macCalendars() -> [EKCalendar] {
    hasCalendarAccess ? store.calendars(for: .event) : []
}

func key(_ c: EKCalendar) -> String {
    "mac:" + c.calendarIdentifier
}

/// Значок события на весь день: картинки у календаря в EventKit нет — только вид и название.
func symbol(_ c: EKCalendar) -> String? {
    symbol(type: c.type, title: c.title)
}

func symbol(type: EKCalendarType, title: String) -> String? {
    if type == .birthday { return "gift" }
    return title.localizedCaseInsensitiveContains("праздн") || title.localizedCaseInsensitiveContains("holiday") ? "flag" : nil
}

/// Встреча EventKit — как встреча ящика. Отклонённая не попадает никуда. Экземпляр серии — по исходной дате:
/// перенос его не меняет, поэтому «пропустить эту» ложится на один экземпляр.
func event(_ e: EKEvent) -> Event? {
    let me = e.attendees?.first { $0.isCurrentUser }
    if me?.participantStatus == .declined { return nil }
    let external = e.calendarItemExternalIdentifier ?? e.eventIdentifier ?? ""
    let series = e.hasRecurrenceRules ? external : nil
    let id = series.flatMap { s in e.occurrenceDate.map { s + "|" + $0.ISO8601Format() } } ?? external
    let attendees = e.attendees ?? []
    let response = e.organizer?.isCurrentUser == true || attendees.isEmpty ? "Organizer"
        : me?.participantStatus == .accepted ? "Accept"
        : me?.participantStatus == .tentative ? "Tentative" : "NoResponseReceived"
    let notes = e.notes?.trimmingCharacters(in: .whitespacesAndNewlines)
    return Event(id: id, changeKey: "", uid: series, subject: e.title ?? "", start: e.startDate, end: e.endDate,
                 isAllDay: e.isAllDay, organizerName: e.organizer?.name ?? "", organizerAddress: e.organizer.map(address) ?? "",
                 attendees: attendees.filter { !$0.isCurrentUser }.map { Person(name: $0.name ?? "", address: address($0)) },
                 response: response, isFree: e.availability == .free, isCancelled: e.status == .canceled,
                 joinURL: joinURL(location: e.location ?? "", html: [e.notes, e.url?.absoluteString].compactMap { $0 }.joined(separator: "\n")),
                 description: notes?.isEmpty == false ? notes : nil,
                 source: "\(e.calendar.source?.title ?? "") · \(e.calendar.title)", symbol: symbol(e.calendar))
}

/// Адрес участника — из ссылки `mailto:`; другой ссылки адресом не считаем.
private func address(_ p: EKParticipant) -> String {
    let link = p.url.absoluteString
    guard link.lowercased().hasPrefix("mailto:") else { return "" }
    return String(link.dropFirst(7)).removingPercentEncoding ?? ""
}

/// Встречи дня из включённых календарей — одним запросом, по боксам календарей. Без доступа или без
/// включённых календарей EventKit не трогается.
@MainActor func macBoxes(_ day: String, keys: [String]) -> [String: Box] {
    guard !keys.isEmpty, hasCalendarAccess, let (start, end) = bounds(day) else { return [:] }
    let calendars = macCalendars().filter { keys.contains(key($0)) }
    guard !calendars.isEmpty else { return [:] }
    var boxes: [String: Box] = [:]
    for e in store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: calendars)) {
        if let event = event(e) { boxes[key(e.calendar), default: Box()].events.append(event) }
    }
    return boxes
}

/// Окно «Календари Mac»: единственное место, где Butler просит доступ к календарям, — при первом открытии.
/// Галочка действует сразу, окно не закрывается.
struct CalendarsDialog: View {
    let app: App
    @SwiftUI.State private var status = EKEventStore.authorizationStatus(for: .event)

    var body: some View {
        popup("Календари Mac") {
            switch status {
            case .fullAccess:
                Text("Встречи отмеченных календарей — в Butler наравне с Exchange.")
                    .foregroundStyle(Ink.tertiary).fixedSize(horizontal: false, vertical: true)
                list
            case .notDetermined:
                Text("Ждём разрешения…").foregroundStyle(Ink.tertiary)
            default:
                Text("Butler не видит календари Mac.")
                Button("Открыть настройки доступа") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
                }
                .buttonStyle(Hover(padding: 6))
                .foregroundStyle(Ink.accent)
            }
            done(app)
        }
        .task {
            guard status == .notDetermined else { return }
            _ = try? await store.requestFullAccessToEvents()
            status = EKEventStore.authorizationStatus(for: .event)
            app.calendarsChanged()
            // Щелчок по системному запросу закрывает окно Butler как щелчок мимо — оно открывается снова.
            app.openDialog(.calendars)
        }
    }

    /// Календари по учётным записям; и те и другие — по алфавиту.
    @ViewBuilder private var list: some View {
        let groups = Dictionary(grouping: macCalendars()) { $0.source?.title ?? "" }
        let sources = groups.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        if sources.isEmpty {
            ListBox(items: [String](), id: \.self, empty: "В «Календаре» нет календарей") { _ in EmptyView() }
        } else {
            fitting(VStack(alignment: .leading, spacing: 8) {
                ForEach(sources, id: \.self) { source in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(source).font(Ink.title).foregroundStyle(Ink.tertiary)
                        ForEach(groups[source]!.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending },
                                id: \.calendarIdentifier) { c in
                            Toggle(isOn: Binding(get: { app.config.calendars.contains(key(c)) }, set: { _ in app.toggleCalendar(key(c)) })) {
                                HStack(spacing: 6) {
                                    Circle().fill(Color(cgColor: c.cgColor)).frame(width: 8, height: 8)
                                    Text(c.title).foregroundStyle(Ink.primary).lineLimit(1).truncationMode(.middle)
                                }
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading))
        }
    }
}
