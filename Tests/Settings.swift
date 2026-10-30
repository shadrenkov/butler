import Foundation
import Testing
@testable import Butler

// Окно настроек меняет в config.json одно поле — ручные правки владельца не должны теряться.

private func json(_ data: Data?) -> [String: Any] {
    data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
}

@Test func changeKeepsUnknownKeysAndHandWrittenHidden() throws {
    let file = Data("""
    {"foo": 1, "hidden": {"a": "Ручная", "b": {"subject": "Daily", "series": true}}, "soundAway": "bell"}
    """.utf8)
    let added = json(Config.changed(file) { json in
        var hidden = json["hidden"] as? [String: Any] ?? [:]
        hidden["c"] = ["subject": "Новая", "series": false]
        json["hidden"] = hidden
    })
    #expect(added["foo"] as? Int == 1)
    #expect(added["soundAway"] as? String == "bell")
    #expect((added["hidden"] as? [String: Any])?.keys.sorted() == ["a", "b", "c"])

    let removed = json(Config.changed(file) { json in
        var hidden = json["hidden"] as? [String: Any] ?? [:]
        hidden["b"] = nil
        json["hidden"] = hidden
    })
    #expect((removed["hidden"] as? [String: Any])?["a"] as? String == "Ручная")
    #expect((removed["hidden"] as? [String: Any])?["b"] == nil)

    let one = json(Config.changed(file) { $0["awayVolume"] = 40 })
    #expect(one["awayVolume"] as? Int == 40)
    #expect(one["foo"] as? Int == 1)
}

@Test func changeRefusesBrokenFileAndCreatesMissingOne() {
    #expect(Config.changed(Data("{ сломано".utf8)) { $0["awayVolume"] = 40 } == nil)
    #expect(Config.changed(Data("[1, 2]".utf8)) { $0["awayVolume"] = 40 } == nil)
    #expect(json(Config.changed(nil) { $0["playAway"] = false }).keys.sorted() == ["playAway"])
}

@Test func hiddenReadsOldStringsAndNewObjects() throws {
    let config = try JSONDecoder().decode(Config.self, from: Data("""
    {"hidden": {"a": "Daily", "b": {"subject": "Ретро", "series": true}, "c": {"subject": "Разбор", "series": false}}}
    """.utf8))
    #expect(config.hidden["a"]?.subject == "Daily")
    #expect(config.hidden["a"]?.series == nil)
    #expect(config.hidden["b"]?.series == true)
    #expect(config.hidden["c"]?.series == false)
}

@Test func missingKeysGiveTodaysBehaviour() throws {
    let config = try JSONDecoder().decode(Config.self, from: Data("{}".utf8))
    #expect(config.playAtDesk && config.playAway && config.playInCall)
    #expect(config.soundAtDesk == "vibraphone" && config.soundInCall == "vibraphone" && config.soundAway == "doorbell")
    #expect(config.awayVolume == 75 && config.awayRepeats == 0 && config.awayAfterMinutes == 2)
    #expect(config.autoOpenMTSLink && config.autoOpenSeconds == 30)
    #expect(Sound.all.count == 15 && Sound.all.filter(\.isLoud).count == 5)
}

@Test func ignoredReadsOldListAndNewNames() throws {
    let old = try JSONDecoder().decode(State.self, from: Data(#"{"ignored": ["s1", "s2"]}"#.utf8))
    #expect(old.ignored == ["s1": "", "s2": ""])
    let new = try JSONDecoder().decode(State.self, from: Data(#"{"ignored": {"s1": "Daily"}}"#.utf8))
    #expect(new.ignored == ["s1": "Daily"])
    let none = try JSONDecoder().decode(State.self, from: Data("{}".utf8))
    #expect(none.ignored.isEmpty)
}
