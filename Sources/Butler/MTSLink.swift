import AppKit
import CoreAudio

/// Открытие встреч в приложении МТС Линк.
enum MTSLink {
    static let apps = ["ru.weteams.desktop", "ru.mts-link.desktop"]

    static func isLink(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased() else { return false }
        return ["mts-link.ru", "webinar.ru"].contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// Ссылку МТС Линк — прямо приложению, без браузера; любую другую — как обычную ссылку.
    static func open(_ url: URL) {
        let workspace = NSWorkspace.shared
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        if isLink(url), let app = workspace.urlForApplication(withBundleIdentifier: "ru.weteams.desktop") {
            workspace.open([url], withApplicationAt: app, configuration: configuration)
        } else if isLink(url), let app = workspace.urlForApplication(withBundleIdentifier: "ru.mts-link.desktop"),
                  var old = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            old.scheme = "wbnr"
            workspace.open([old.url ?? url], withApplicationAt: app, configuration: configuration)
        } else {
            workspace.open(url)
        }
    }
}

extension MTSLink {
    /// Звонок идёт, если звук с микрофона пишет хоть одно приложение, кроме фонового
    /// прослушивания macOS. Приложение с выключенным микрофоном (mute) поток не отпускает.
    /// Не удалось узнать — считаем, что звонок идёт: лишний раз не открыть безопаснее.
    /// `ignoringLink` — не считать МТС Линк: открытая встреча занимает микрофон сама, ещё до начала.
    static func isCallActive(ignoringLink: Bool = false) -> Bool {
        let processes = audioArray(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList)
        if processes.isEmpty { return true }
        let ignored = Set(["com.apple.CoreSpeech", Bundle.main.bundleIdentifier].compactMap { $0 })
        return processes.contains { process in
            guard audioValue(process, kAudioProcessPropertyIsRunningInput, UInt32(0)) == 1 else { return false }
            guard let bundle = audioValue(process, kAudioProcessPropertyBundleID, Unmanaged<CFString>?.none) ?? nil else { return true }
            let id = bundle.takeRetainedValue() as String
            return !ignored.contains(id) && !(ignoringLink && apps.contains { id.hasPrefix($0) })
        }
    }

    /// Запустить МТС Линк, не показывая окон и не забирая фокус, если он ещё не запущен.
    static func launchInBackground() {
        let workspace = NSWorkspace.shared
        guard apps.allSatisfy({ NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty }),
              let app = apps.lazy.compactMap({ workspace.urlForApplication(withBundleIdentifier: $0) }).first
        else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.hides = true
        workspace.openApplication(at: app, configuration: configuration)
    }

    /// В последние `lead` секунд перед встречей со ссылкой МТС Линк выбрать её для открытия, как только
    /// освободится микрофон. Если в это время несколько таких встреч — ту единственную, что принята;
    /// не выбрать — только запустить МТС Линк в фоне. Каждое время начала готовится один раз.
    /// Возвращает встречу, которую пора открыть: открывает её Butler, после короткого сигнала.
    static func prepare(_ meetings: [Meeting], now: Date, state: State, lead: TimeInterval, prepared: inout Set<String>) -> Meeting? {
        let linked = linked(meetings, state)
        let soon = linked.filter { $0.start - lead <= now && now < $0.start && !prepared.contains($0.reminderKey) }
        guard let start = soon.map(\.start).min() else { return nil }
        let together = linked.filter { $0.start == start }
        let accepted = together.filter { $0.isAccepted == true }
        guard let choice = together.count == 1 ? together.first : accepted.count == 1 ? accepted.first : nil else {
            prepared.formUnion(together.map(\.reminderKey))
            launchInBackground()
            return nil
        }
        guard !isCallActive(), choice.joinURL != nil else {
            launchInBackground()
            return nil
        }
        prepared.formUnion(together.map(\.reminderKey))
        return choice
    }

    /// За сколько секунд до открытия звучит «тк-тк»: Линк забирает фокус, к этому надо успеть приготовиться.
    static let warning = 1.0

    /// За сколько секунд до автооткрытия на иконке начинается кольцо отсчёта.
    static let countdownSeconds = 10.0

    /// Отсчёт до того, как Butler сам займётся МТС Линк: за `countdownSeconds` до срока `prepare` и пока он не
    /// сработал (микрофон занят — значение 1). Встречи — те, что он откроет, или все одновременные,
    /// если выбрать нельзя и он только запустит МТС Линк.
    static func countdown(_ meetings: [Meeting], now: Date, state: State, lead: TimeInterval, prepared: Set<String>) -> (ids: Set<String>, progress: Double)? {
        let linked = linked(meetings, state)
        let soon = linked.filter { $0.start - lead - countdownSeconds <= now && now < $0.start && !prepared.contains($0.reminderKey) }
        guard let start = soon.map(\.start).min() else { return nil }
        let together = linked.filter { $0.start == start }
        let accepted = together.filter { $0.isAccepted == true }
        let chosen = together.count > 1 && accepted.count == 1 ? accepted : together
        return (Set(chosen.map(\.id)), min(1, now.timeIntervalSince(start - lead - countdownSeconds) / countdownSeconds))
    }

    private static func linked(_ meetings: [Meeting], _ state: State) -> [Meeting] {
        meetings.filter { m in !m.isAllDay && !isSettled(m, state) && m.joinURL.map(isLink) == true }
    }
}
