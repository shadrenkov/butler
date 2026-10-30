import AppKit
import AudioToolbox
import AVFoundation
import CoreAudio

/// Где владелец, когда начинается напоминание: от этого зависит, какой звук играть.
enum Situation { case atDesk, away, inCall }

/// Звук напоминания — рецепт: ноты одна за другой с шагом `step`.
/// Обертоны — (кратность, громкость); обертон с номером k затухает в k раз быстрее основного тона.
struct Sound {
    let id: String
    let name: String
    let isLoud: Bool
    let notes: [Double]
    let step: Double
    let attack: Double
    let decay: Double
    let partials: [(ratio: Double, gain: Double)]
    let swell: Double

    // Наборы обертонов, общие для нескольких звуков.
    private static let bright: [(ratio: Double, gain: Double)] = [(1, 1), (2.76, 0.5), (5.4, 0.25)]
    private static let chime: [(ratio: Double, gain: Double)] = [(1, 1), (2.76, 0.2), (5.4, 0.06)]
    private static let warm: [(ratio: Double, gain: Double)] = [(1, 1), (2, 0.25), (3, 0.08)]
    private static let mellow: [(ratio: Double, gain: Double)] = [(1, 1), (2, 0.15), (3, 0.04)]
    private static let deep: [(ratio: Double, gain: Double)] = [(1, 1), (2.76, 0.2), (5.4, 0.05)]

    static let all = [
        Sound(id: "trill", name: "Трель", isLoud: false, notes: [659.25, 739.99, 659.25, 739.99, 659.25],
              step: 0.11, attack: 0.004, decay: 0.25, partials: bright, swell: 0),
        Sound(id: "softTrill", name: "Мягкая трель", isLoud: false, notes: [659.25, 739.99, 659.25, 739.99, 659.25, 739.99],
              step: 0.13, attack: 0.05, decay: 0.35, partials: chime, swell: 0.6),
        Sound(id: "musicBox", name: "Шкатулка", isLoud: false, notes: [659.25, 830.61, 987.77, 1318.51],
              step: 0.17, attack: 0.04, decay: 0.6, partials: warm, swell: 0.5),
        Sound(id: "breeze", name: "Ветерок", isLoud: false, notes: [783.99, 880, 1046.5, 1174.66, 1046.5],
              step: 0.14, attack: 0.07, decay: 0.5, partials: warm, swell: 0.4),
        Sound(id: "dingDongUp", name: "Динь-дон вверх", isLoud: false, notes: [659.25, 987.77],
              step: 0.28, attack: 0.06, decay: 0.8, partials: chime, swell: 0.3),
        Sound(id: "lowTrill", name: "Низкая трель", isLoud: false, notes: [329.63, 369.99, 329.63, 369.99, 329.63, 369.99],
              step: 0.15, attack: 0.08, decay: 0.5, partials: mellow, swell: 0.5),
        Sound(id: "marimba", name: "Маримба", isLoud: false, notes: [261.63, 329.63, 392, 523.25],
              step: 0.18, attack: 0.05, decay: 0.55, partials: [(1, 1), (4, 0.12)], swell: 0.4),
        Sound(id: "warmChord", name: "Тёплый аккорд", isLoud: false, notes: [329.63, 392, 493.88],
              step: 0.22, attack: 0.15, decay: 0.9, partials: mellow, swell: 0.2),
        Sound(id: "lowDingDong", name: "Низкий динь-дон", isLoud: false, notes: [392, 329.63],
              step: 0.45, attack: 0.08, decay: 1.0, partials: [(1, 1), (2.76, 0.08)], swell: 0),
        Sound(id: "vibraphone", name: "Вибрафон", isLoud: false, notes: [220, 277.18, 329.63, 440],
              step: 0.2, attack: 0.1, decay: 0.8, partials: mellow, swell: 0.4),
        Sound(id: "bell", name: "Колокол", isLoud: true, notes: [1046.5, 783.99, 523.25],
              step: 0.35, attack: 0.004, decay: 0.7, partials: bright, swell: 0),
        Sound(id: "lowBell", name: "Колокол пониже", isLoud: true, notes: [523.25, 392, 261.63],
              step: 0.35, attack: 0.01, decay: 0.9, partials: deep, swell: 0),
        Sound(id: "loudVibraphone", name: "Громкий вибрафон", isLoud: true, notes: [329.63, 415.3, 493.88, 659.25, 493.88, 415.3],
              step: 0.18, attack: 0.02, decay: 0.9, partials: deep, swell: 0),
        Sound(id: "chimes", name: "Куранты", isLoud: true, notes: [329.63, 261.63, 293.66, 196],
              step: 0.5, attack: 0.01, decay: 1.2, partials: deep, swell: 0),
        Sound(id: "doorbell", name: "Дверной звонок", isLoud: true, notes: [392, 329.63, 392, 329.63],
              step: 0.45, attack: 0.01, decay: 0.9, partials: deep, swell: 0),
    ]

    /// Тихое «тк-тк», деревянная коробочка: им Butler предупреждает, что сам открывает МТС Линк.
    static let knock = Sound(id: "knock", name: "Тк-тк", isLoud: false, notes: [1250, 1250],
                             step: 0.16, attack: 0.0015, decay: 0.018, partials: [(1, 1), (2.4, 0.35)], swell: 0)

    /// Сколько звучит: последняя нота и её затухание.
    var length: Double { Double(notes.count - 1) * step + decay * 5 }

    static func named(_ id: String) -> Sound? {
        all.first { $0.id == id }
    }

    @MainActor private static var recorded: [String: Data] = [:]

    /// WAV синтезируется при первом проигрывании и дальше берётся из памяти.
    @MainActor var wav: Data {
        if let data = Self.recorded[id] { return data }
        let data = Self.synthesize(notes.enumerated().map { ($1, Double($0) * step) }, decay: decay,
                                   volume: isLoud ? 0.9 : 0.35, attack: attack, swell: swell,
                                   partials: partials.enumerated().map { ($1.ratio, $1.gain, 1 / Double($0 + 1)) })
        Self.recorded[id] = data
        return data
    }

    /// Колокол: основной тон и обертоны, гаснущие быстрее него; WAV 44,1 кГц, моно, 16 бит.
    /// Ноты с затуханием `decay`; `attack` — плавное начало каждой ноты, `swell` — насколько первая нота
    /// тише последней; обертоны — (кратность, громкость, во сколько раз короче затухают).
    private static func synthesize(_ notes: [(frequency: Double, at: Double)], decay: Double, volume: Double, attack: Double,
                                   swell: Double, partials: [(ratio: Double, gain: Double, decay: Double)]) -> Data {
        let rate = 44_100.0
        let tail = Int(decay * 5 * rate)
        var samples = [Double](repeating: 0, count: Int((notes.map(\.at).max() ?? 0) * rate) + tail)
        for (n, (frequency, at)) in notes.enumerated() {
            let start = Int(at * rate)
            let level = 1 - swell + swell * Double(n) / Double(max(1, notes.count - 1))
            for i in 0..<min(tail, samples.count - start) {
                let t = Double(i) / rate
                let rise = t < attack ? 0.5 - 0.5 * cos(.pi * t / attack) : 1 // плавное начало — без щелчка
                let tone = partials.reduce(0.0) { sum, p in
                    sum + p.gain * exp(-t / (decay * p.decay)) * sin(2 * .pi * frequency * p.ratio * t)
                }
                samples[start + i] += level * rise * exp(-t / decay) * tone
            }
        }
        let peak = samples.map(abs).max() ?? 1
        var wav = Data()
        func put<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 2)
        wav.append(contentsOf: Array("RIFF".utf8)); put(36 + bytes)
        wav.append(contentsOf: Array("WAVEfmt ".utf8)); put(UInt32(16)); put(UInt16(1)); put(UInt16(1))
        put(UInt32(rate)); put(UInt32(rate * 2)); put(UInt16(2)); put(UInt16(16))
        wav.append(contentsOf: Array("data".utf8)); put(bytes)
        for sample in samples { put(Int16((sample / peak * volume * 32_767).rounded())) }
        return wav
    }
}

/// Присутствие пользователя у экрана и звуки напоминания. Мягкие звуки — на текущей громкости, звук
/// «не у компьютера» — на своей громкости во встроенных динамиках.
@MainActor
final class Alarm: NSObject, AVAudioPlayerDelegate {
    private var locked = false
    private var player: AVAudioPlayer?
    /// Проба из настроек — отдельно, чтобы не глушить звенящее напоминание.
    private var trial: AVAudioPlayer?
    private var knocker: AVAudioPlayer?
    private var loudTimer: Timer?
    /// Сколько ещё раз прозвучит звук «не у компьютера»; меньше нуля — без предела.
    private var loudLeft = 0
    private var saved: (device: AudioObjectID, volume: Float32, mute: UInt32)?

    var isLoud: Bool { loudTimer != nil }
    var hasSpeakers: Bool { speakers() != nil }

    override init() {
        super.init()
        let center = DistributedNotificationCenter.default()
        center.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.locked = true }
        }
        center.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.locked = false }
        }
    }

    /// У экрана — экран не заблокирован и клавиатура или мышь трогались меньше `minutes` минут назад.
    func isPresent(after minutes: Double) -> Bool {
        let anyInput = CGEventType(rawValue: ~0)!
        return !locked && CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput) < minutes * 60
    }

    /// Звук напоминания для ситуации. «Не у компьютера» — сразу и дальше каждые 10 секунд, сколько
    /// задано, пока не позовут `stopLoud`; остальные — один раз. Снятая галочка — тишина.
    func ring(_ situation: Situation, _ config: Config) {
        guard config.plays(situation), let sound = Sound.named(config.sound(situation)) else { return }
        guard situation == .away else {
            player = play(sound, volume: nil)
            return
        }
        guard loudTimer == nil else { return }
        loudLeft = config.awayRepeats == 0 ? -1 : config.awayRepeats
        let volume = config.awayVolume
        let timer = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.playLoud(sound, volume) }
        }
        RunLoop.main.add(timer, forMode: .common)
        loudTimer = timer
        playLoud(sound, volume)
    }

    func stopLoud() {
        loudTimer?.invalidate()
        loudTimer = nil
        if saved != nil {
            player?.stop()
            restoreVolume()
        }
    }

    /// Проба из настроек — так, как звук прозвучит в напоминании для этой ситуации, один раз.
    /// Новая проба обрывает прежнюю, напоминание не трогает.
    func preview(_ sound: Sound, _ situation: Situation, _ config: Config) {
        trial?.stop()
        trial = play(sound, volume: situation == .away ? config.awayVolume : nil)
    }

    /// «Тк-тк» вполголоса — мимо напоминания и пробы, их не обрывает.
    func knock() {
        knocker = play(.knock, volume: nil)
        knocker?.volume = 0.5
    }

    private func playLoud(_ sound: Sound, _ volume: Int) {
        player = play(sound, volume: volume)
        loudLeft -= 1
        if loudLeft == 0 {
            loudTimer?.invalidate()
            loudTimer = nil
        }
    }

    /// Во встроенные динамики, а без них — в выход по умолчанию. С `volume` (в процентах) громкость
    /// динамиков на время звука выставляется своя; вернётся она, когда замолчат и напоминание, и проба.
    private func play(_ sound: Sound, volume: Int?) -> AVAudioPlayer? {
        let speakers = speakers()
        if let volume, let speakers {
            if saved == nil,
               let current = audioValue(speakers.id, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, Float32(0), scope: kAudioObjectPropertyScopeOutput),
               let mute = audioValue(speakers.id, kAudioDevicePropertyMute, UInt32(0), scope: kAudioObjectPropertyScopeOutput) {
                saved = (speakers.id, current, mute)
            }
            setAudioValue(speakers.id, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, Float32(volume) / 100)
            setAudioValue(speakers.id, kAudioDevicePropertyMute, UInt32(0))
        }
        guard let player = try? AVAudioPlayer(data: sound.wav) else { return nil }
        player.currentDevice = speakers?.uid
        player.delegate = self
        player.play()
        return player
    }

    private func restoreVolume() {
        guard let saved, player?.isPlaying != true, trial?.isPlaying != true else { return }
        setAudioValue(saved.device, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, saved.volume)
        setAudioValue(saved.device, kAudioDevicePropertyMute, saved.mute)
        self.saved = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.restoreVolume() }
    }

    /// Встроенные динамики: встроенное устройство с выходом, которое сейчас не наушники в разъёме.
    private func speakers() -> (id: AudioObjectID, uid: String)? {
        let system = AudioObjectID(kAudioObjectSystemObject)
        let headphones: UInt32 = 0x6864_706E // 'hdpn'
        for id in audioArray(system, kAudioHardwarePropertyDevices) {
            guard audioValue(id, kAudioDevicePropertyTransportType, UInt32(0)) == kAudioDeviceTransportTypeBuiltIn,
                  !audioArray(id, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput).isEmpty,
                  audioValue(id, kAudioDevicePropertyDataSource, UInt32(0), scope: kAudioObjectPropertyScopeOutput) != headphones,
                  let uid = audioValue(id, kAudioDevicePropertyDeviceUID, Unmanaged<CFString>?.none) ?? nil
            else { continue }
            return (id, uid.takeRetainedValue() as String)
        }
        return nil
    }
}

// Чтение и запись свойств CoreAudio — нужны и здесь, и в MTSLink.swift.

private func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

func audioValue<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, _ initial: T,
                   scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> T? {
    var address = address(selector, scope)
    var value = initial
    var size = UInt32(MemoryLayout<T>.size)
    let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0) }
    return status == noErr ? value : nil
}

func audioArray(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
    var address = address(selector, scope)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr else { return [] }
    var values = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &values) == noErr else { return [] }
    return values
}

private func setAudioValue<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: T) {
    var address = address(selector, kAudioObjectPropertyScopeOutput)
    _ = withUnsafePointer(to: value) { AudioObjectSetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<T>.size), $0) }
}
