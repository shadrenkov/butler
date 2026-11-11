import Foundation

// Рисунки рабочего дня из `Pictures/`: пейзажи, вставки и кляксы. У каждого — вид: за день не больше одного
// рисунка вида. И время, когда он к месту: утро, вечер или всегда.

enum Hour { case morning, evening }

struct Art {
    let name: String
    let kind: String
    var hour: Hour? = nil
}

/// Рисунки одного вида и времени.
private func art(_ kind: String, _ hour: Hour? = nil, _ names: [String]) -> [Art] {
    names.map { Art(name: $0, kind: kind, hour: hour) }
}

let landscapes: [Art] = art("sea", nil, ["horizon", "kites", "whales", "surf", "regatta"])
    + art("sea", .evening, ["sunset1", "sunset2", "lighthouse"])
    + art("sea", .morning, ["fog"])
    + art("shore", nil, ["sealions1", "sealions2", "cliffs", "dunes", "quad"])
    + art("shore", .morning, ["harbor"])
    + art("shore", .evening, ["stilts"])
    + art("town", nil, ["street", "ride"])
    + art("town", .morning, ["cafe"])
    + art("town", .evening, ["promenade1", "promenade2"])
    + art("land", nil, ["hills", "pines1", "pines2", "island"])
    + art("land", .morning, ["forest"])

let vignettes: [Art] = art("drink", .morning, ["cup"])
    + art("drink", nil, ["tea", "mate"])
    + art("food", .morning, ["croissant", "yogurt"])
    + art("food", nil, ["bananas", "icecream", "alfajores"])
    + art("rest", nil, ["armchair", "pouf", "books", "notebook", "hammock"])
    + art("plant", nil, ["flowers", "eucalyptus", "hydrangea", "pinecone"])
    + art("sand", nil, ["crab", "starfish"])
    + art("animal", nil, ["capybara"])
    + art("bird", nil, ["seagull", "heron", "parakeets", "hornero"])
    + art("sport", nil, ["surfboard", "sup", "wetsuit", "kite", "bicycle", "skateboard"])
    + art("beach", nil, ["flipflops", "hat"])
    + art("luck", nil, ["gloves", "money"])

let blots: [Art] = art("blot", nil, ["blot1", "blot2"]) + art("splash", nil, ["splash1", "splash2"]) + art("scuff", nil, ["scuff1", "scuff2"])

/// Выбор рисунков на день: случайно, но случайность задаётся только датой — день выглядит одинаково и после
/// перезапуска, пока не поменялись алгоритм или набор рисунков. Вид за день не повторяется.
struct Choice {
    private let seed: UInt64
    private var count: UInt64 = 0
    private var kinds: Set<String> = []

    init(day: Date) {
        seed = UInt64(truncatingIfNeeded: Int((day.timeIntervalSince1970 / 86_400).rounded()))
    }

    /// Следующее случайное число от 0 до 1.
    mutating func next() -> CGFloat {
        count += 1
        var x = seed &* 6_364_136_223_846_793_005 &+ count &* 1_442_695_040_888_963_407
        x ^= x >> 33
        x = x &* 0xff51_afd7_ed55_8ccd
        x ^= x >> 33
        return CGFloat(x % 10_000) / 10_000
    }

    /// Рисунок вида, которого сегодня ещё не было, к месту в это время; середина дня принимает любой. Нет — `nil`.
    mutating func pick(_ arts: [Art], at time: Date) -> String? {
        let hour = Calendar.current.component(.hour, from: time)
        let now: Hour? = hour < 12 ? .morning : hour >= 17 ? .evening : nil
        let fit = arts.filter { !kinds.contains($0.kind) && ($0.hour == nil || now == nil || $0.hour == now) }
        guard !fit.isEmpty else { return nil }
        let art = fit[min(fit.count - 1, Int(next() * CGFloat(fit.count)))]
        kinds.insert(art.kind)
        return art.name
    }
}
