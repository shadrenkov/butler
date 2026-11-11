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
    + art("bloom", nil, ["flowers", "hydrangea", "ceibo", "jacaranda", "silkfloss", "lapacho", "passionflower"])
    + art("plant", nil, ["eucalyptus", "pinecone", "pampasgrass", "feijoa", "peppertree"])
    + art("tree", nil, ["ombu", "butia"])
    + art("sand", nil, ["crab", "starfish", "turtle"])
    + art("wild", nil, ["capybara", "rhea", "armadillo", "fox", "coypu"])
    + art("farm", nil, ["horse", "cow"])
    + art("bird", nil, ["seagull", "parakeets", "hornero", "lapwing", "cardinal", "hummingbird", "owl"])
    + art("wader", nil, ["heron", "screamer", "swans", "flamingo"])
    + art("sport", nil, ["surfboard", "sup", "kite", "bicycle", "skateboard"])
    + art("beach", nil, ["flipflops", "hat"])
    + art("luck", nil, ["gloves"])

let blots: [Art] = art("blot", nil, ["blot1", "blot2"]) + art("splash", nil, ["splash1", "splash2"]) + art("scuff", nil, ["scuff1", "scuff2"])

/// Выбор рисунков на день. Каждый набор перемешан раз и навсегда, а дни идут по нему подряд: соседние дни не
/// совпадают, рисунок возвращается, лишь когда набор пройден целиком. Всё задаётся датой — день выглядит одинаково
/// и после перезапуска, пока не поменялись алгоритм или набор рисунков. Вид за день не повторяется.
struct Choice {
    private let day: Int
    private var count: UInt64 = 0
    private var kinds: Set<String> = []
    /// Сколько рисунков из набора сегодня уже взято — по первому имени набора.
    private var taken: [String: Int] = [:]

    init(day: Date) {
        self.day = Int((day.timeIntervalSince1970 / 86_400).rounded())
    }

    /// Следующее случайное число от 0 до 1 — для мест и поворотов.
    mutating func next() -> CGFloat {
        count += 1
        return CGFloat(mix(UInt64(truncatingIfNeeded: day) &* 6_364_136_223_846_793_005 &+ count) % 10_000) / 10_000
    }

    /// Следующий по очереди рисунок набора, к месту в это время, вида, которого сегодня ещё не было; середина дня
    /// принимает любой. `perDay` — сколько рисунков набора день берёт обычно: на столько он и сдвигается от
    /// вчерашнего. Подходящего нет — `nil`.
    mutating func pick(_ arts: [Art], perDay: Int, at time: Date) -> String? {
        guard let first = arts.first?.name else { return nil }
        let hour = Calendar.current.component(.hour, from: time)
        let now: Hour? = hour < 12 ? .morning : hour >= 17 ? .evening : nil
        // Постоянный порядок — перемешивание с одним и тем же зерном; из него — подходящие по времени, чтобы
        // пропуск неподходящего не сдвигал день на завтрашний рисунок.
        var order = arts
        for i in stride(from: order.count - 1, to: 0, by: -1) {
            order.swapAt(i, Int(mix(UInt64(i) &+ 0x9e37_79b9_7f4a_7c15) % UInt64(i + 1)))
        }
        order = order.filter { $0.hour == nil || now == nil || $0.hour == now }
        let start = day * perDay + taken[first, default: 0]
        for j in 0..<order.count {
            let art = order[((start + j) % order.count + order.count) % order.count]
            guard !kinds.contains(art.kind) else { continue }
            kinds.insert(art.kind)
            taken[first, default: 0] += j + 1
            return art.name
        }
        return nil
    }
}

/// Перемешивание битов: из соседних чисел — непохожие.
private func mix(_ value: UInt64) -> UInt64 {
    var x = value &* 0xbf58_476d_1ce4_e5b9
    x ^= x >> 31
    x = x &* 0x94d0_49bb_1331_11eb
    x ^= x >> 29
    return x
}
