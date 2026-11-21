import Foundation

public enum TwoBSIQBand: Int, CaseIterable, Sendable {
    case a, b

    public var name: String { self == .a ? "VFO A" : "VFO B" }
    public var meters: Int { self == .a ? 20 : 15 }
}

public enum TwoBSIQAction: Equatable {
    case cq, exchange, finish, repeatRequest
}

public enum TwoBSIQStage: Equatable {
    case idle, receivingCall, awaitingExchange, receivingReport, awaitingTU
}

public struct TwoBSIQLaneDisplay: Equatable {
    public let stage: TwoBSIQStage
    /// Non-nil while the field displays a TX message, including the empty tail.
    public let transmission: String?
    public let queued: Bool
    public let draftVersion: Int
    public let status: String?
    public let receivedZone: Int?
}

public struct TwoBSIQQSO {
    public let time: Date
    public let band: TwoBSIQBand
    public let call: String
    public let zone: Int
    public let points: Int
}

public struct TwoBSIQScore: Equatable {
    public init() {}

    public fileprivate(set) var qsos = 0
    public fileprivate(set) var points = 0
    public fileprivate(set) var multipliers = 0
    public var total: Int { points * multipliers }
}

public struct TwoBSIQStereoBlock {
    public let left: SampleArray
    public let right: SampleArray
}

/// Two independent RUN lanes on one sample clock. The local transmitter is
/// shared, while the second radio can receive through the entire transmission.
@MainActor
public final class TwoBSIQSession {
    private let call: String
    private let zone: Int
    private var wpm: Int
    private var slowerBy = 0
    private var fasterBy = 0
    private let pitch: Int
    private let ownLocation: DxccRec?
    private let keyer = Keyer()
    private let candidates: [TwoBSIQCatalog.Station]
    private let waitSamples: Int
    private let replyDelay: Int

    private struct Reception {
        let message: TwoBSIQMessage
        let start: Int
        var end: Int { start + message.sampleCount }
    }

    private struct Lane {
        var stage = TwoBSIQStage.idle
        var station: TwoBSIQCatalog.Station?
        var stationWpm = 25
        var reception: Reception?
        var deadline: Int?
        var status: String?
        var draftVersion = 0
        var nextCandidate = 0
        var worked = Set<String>()
        var entities = Set<String>()
        var zones = Set<Int>()

        mutating func reset(status: String? = nil, clearDraft: Bool = true) {
            stage = .idle
            station = nil
            reception = nil
            deadline = nil
            self.status = status
            if clearDraft { draftVersion += 1 }
        }
    }

    private struct Command {
        let band: TwoBSIQBand
        let action: TwoBSIQAction
        let text: String
        let addressedStation: Bool
    }

    private struct Transmission {
        let command: Command
        let start: Int
        let message: TwoBSIQMessage
        var end: Int { start + message.sampleCount }
    }

    private var lanes = [Lane(), Lane()]
    private var active: Transmission?
    private var queued: Command?
    private var playback = 0
    private var rendered = 0

    public private(set) var log: [TwoBSIQQSO] = []
    public private(set) var score = TwoBSIQScore()
    public var elapsedSeconds: Int { playback / AudioConstants.defaultRate }
    public var separation: Float = 1

    public convenience init(call: String, zone: Int, wpm: Int, pitch: Int, catalog: TwoBSIQCatalog) {
        self.init(call: call, zone: zone, wpm: wpm, pitch: pitch, stations: catalog.stations.shuffled())
    }

    init(call: String, zone: Int, wpm: Int, pitch: Int, stations: [TwoBSIQCatalog.Station],
         waitSamples: Int = 20 * AudioConstants.defaultRate, replyDelay: Int = AudioConstants.defaultRate / 4) {
        let normalizedCall = TwoBSIQCatalog.normalizedCall(call)
        self.call = normalizedCall
        self.zone = zone
        self.wpm = min(120, max(10, wpm))
        self.pitch = min(1_200, max(300, pitch))
        ownLocation = TwoBSIQCatalog.location(for: normalizedCall)
        candidates = stations.filter { $0.call != normalizedCall }
        self.waitSamples = waitSamples
        self.replyDelay = replyDelay
        // Start the two bands at different points in the shuffled pool.
        lanes[1].nextCandidate = candidates.count / 2
    }

    public static func exchangeSuffix(zone: Int) -> String {
        " ENN \(zone)"
    }

    public func setSpeed(wpm: Int, slowerBy: Int, fasterBy: Int) {
        self.wpm = min(120, max(10, wpm))
        self.slowerBy = min(10, max(0, slowerBy))
        self.fasterBy = min(10, max(0, fasterBy))
    }

    var receiveSpeedRange: ClosedRange<Int> {
        max(10, wpm - slowerBy)...min(120, wpm + fasterBy)
    }

    public func display(for band: TwoBSIQBand) -> TwoBSIQLaneDisplay {
        let lane = lanes[band.rawValue]
        let pending = queued?.band == band ? queued : nil
        let text: String?
        if let active, active.command.band == band {
            text = active.message.remaining(after: playback - active.start)
        } else {
            text = pending?.text
        }
        let copiedExchange = lane.stage == .receivingReport || lane.stage == .awaitingTU
        return TwoBSIQLaneDisplay(stage: lane.stage, transmission: text, queued: pending != nil,
                                 draftVersion: lane.draftVersion, status: lane.status,
                                 receivedZone: copiedExchange ? lane.station?.zone : nil)
    }

    public func canSend(_ action: TwoBSIQAction, on band: TwoBSIQBand) -> Bool {
        guard active?.command.band != band, queued == nil else { return false }
        let suggested = suggestedAction(for: band)
        return action == .repeatRequest ? (suggested == .exchange || suggested == .finish) : suggested == action
    }

    public func suggestedAction(for band: TwoBSIQBand) -> TwoBSIQAction? {
        switch lanes[band.rawValue].stage {
        case .idle: .cq
        case .awaitingExchange: .exchange
        case .awaitingTU: .finish
        case .receivingCall, .receivingReport: nil
        }
    }

    @discardableResult
    public func send(_ action: TwoBSIQAction, on band: TwoBSIQBand, enteredCall: String) -> Bool {
        guard canSend(action, on: band) else { return false }
        let index = band.rawValue
        let text: String
        let entered = TwoBSIQCatalog.normalizedCall(enteredCall)
        switch action {
        case .cq:
            text = "CQ TEST \(call)"
        case .exchange:
            guard TwoBSIQCatalog.isCall(entered) else {
                lanes[index].status = "Enter the caller’s callsign"
                return false
            }
            text = entered + Self.exchangeSuffix(zone: zone)
        case .finish:
            text = "TU \(call)"
        case .repeatRequest:
            text = "?"
        }
        let command = Command(band: band, action: action, text: text,
                              addressedStation: entered == lanes[index].station?.call)
        lanes[index].status = nil
        if active == nil {
            start(command)
        } else {
            queued = command
        }
        return true
    }

    public func cancel(selected band: TwoBSIQBand) {
        if active != nil {
            active = nil
            queued = nil
            // The drafts are owned by the input fields. Cancelling only
            // dismisses their read-only TX views, leaving the drafts intact.
            expireLanes()
        } else {
            lanes[band.rawValue].reset()
        }
    }

    /// The sink reports the number of stereo frames played, not just queued.
    /// TX progress, deadlines and logging all use that same timeline.
    public func advancePlayback(to samples: Int) {
        playback = min(rendered, max(playback, samples))
        if let active, playback >= active.end {
            self.active = nil
            finish(active.command)
            if let queued {
                self.queued = nil
                start(queued)
            }
        }

        for band in TwoBSIQBand.allCases {
            let index = band.rawValue
            guard let receive = lanes[index].reception, playback >= receive.end else { continue }
            lanes[index].reception = nil
            lanes[index].stage = lanes[index].stage == .receivingCall ? .awaitingExchange : .awaitingTU
            lanes[index].deadline = receive.end + waitSamples
        }
        expireLanes()
    }

    public func renderAudio() -> TwoBSIQStereoBlock {
        let a = receiveAudio(on: .a)
        let b = receiveAudio(on: .b)
        rendered += AudioConstants.defaultBufSize
        return Self.mix(a: a, b: b, separation: separation)
    }

    static func mix(a: SampleArray, b: SampleArray, separation: Float) -> TwoBSIQStereoBlock {
        let cross = (1 - min(1, max(0, separation))) / 2
        let direct = 1 - cross
        var left = a
        var right = b
        for index in a.indices {
            left[index] = direct * a[index] + cross * b[index]
            right[index] = cross * a[index] + direct * b[index]
        }
        return TwoBSIQStereoBlock(left: left, right: right)
    }

    private func start(_ command: Command) {
        keyer.setWpm(wpm)
        active = Transmission(command: command, start: rendered, message: TwoBSIQMessage(command.text, keyer: keyer))
    }

    private func finish(_ command: Command) {
        let band = command.band
        let index = band.rawValue
        switch command.action {
        case .cq:
            lanes[index].draftVersion += 1
            callNextStation(on: band)
        case .exchange:
            lanes[index].draftVersion += 1
            guard command.addressedStation, let station = lanes[index].station else {
                lanes[index].status = "No reply"
                return
            }
            receive("5NN \(station.zone)", on: band, stage: .receivingReport)
        case .finish:
            guard let station = lanes[index].station else { return }
            logContact(station, on: band)
            lanes[index].draftVersion += 1
            callNextStation(on: band)
        case .repeatRequest:
            guard let station = lanes[index].station else { return }
            if lanes[index].stage == .awaitingTU {
                receive("5NN \(station.zone)", on: band, stage: .receivingReport)
            } else {
                receive(station.call, on: band, stage: .receivingCall)
            }
        }
    }

    private func callNextStation(on band: TwoBSIQBand) {
        let index = band.rawValue
        guard !candidates.isEmpty, lanes[index].worked.count < candidates.count else {
            lanes[index].reset(status: "No remaining stations", clearDraft: false)
            return
        }
        // Walk the shuffled pool once before revisiting abandoned callers.
        var station: TwoBSIQCatalog.Station
        repeat {
            let next = lanes[index].nextCandidate
            station = candidates[next]
            lanes[index].nextCandidate = (next + 1) % candidates.count
        } while lanes[index].worked.contains(station.call)
        lanes[index].station = station
        lanes[index].stationWpm = Int.random(in: receiveSpeedRange)
        receive(station.call, on: band, stage: .receivingCall)
    }

    private func receive(_ text: String, on band: TwoBSIQBand, stage: TwoBSIQStage) {
        let index = band.rawValue
        keyer.setWpm(lanes[index].stationWpm)
        lanes[index].stage = stage
        lanes[index].deadline = nil
        lanes[index].reception = Reception(message: TwoBSIQMessage(text, keyer: keyer), start: rendered + replyDelay)
    }

    private func expireLanes() {
        for band in TwoBSIQBand.allCases where active?.command.band != band && queued?.band != band {
            let index = band.rawValue
            if let deadline = lanes[index].deadline, playback >= deadline {
                lanes[index].reset(status: "Caller timed out")
            }
        }
    }

    private func receiveAudio(on band: TwoBSIQBand) -> SampleArray {
        let count = AudioConstants.defaultBufSize
        var samples = SampleArray(repeating: 0, count: count)
        guard let receive = lanes[band.rawValue].reception,
              active?.command.band != band else { return samples }

        let first = max(0, receive.start - rendered)
        let end = min(count, receive.end - rendered)
        guard first < end else { return samples }
        let frequency = Double(pitch + (band == .a ? -50 : 50))
        let radians = 2 * Double.pi * frequency / Double(AudioConstants.defaultRate)
        for offset in first..<end {
            let position = rendered + offset - receive.start
            samples[offset] = 0.35 * receive.message.envelope[position] * Float(sin(radians * Double(position)))
        }
        return samples
    }

    private func logContact(_ station: TwoBSIQCatalog.Station, on band: TwoBSIQBand) {
        let index = band.rawValue
        guard lanes[index].worked.insert(station.call).inserted else { return }
        let points: Int
        if call.hasSuffix("/MM") || station.entity == ownLocation?.entity {
            points = 0
        } else if let ownLocation {
            points = station.continent == ownLocation.continent ? (station.continent == "NA" ? 2 : 1) : 3
        } else {
            // The caller can still practice using a manually supplied zone
            // when the local data has no entity for the operator's call.
            points = 0
        }
        log.append(TwoBSIQQSO(time: Date(), band: band, call: station.call, zone: station.zone, points: points))
        score.qsos += 1
        score.points += points
        if lanes[index].entities.insert(station.entity).inserted { score.multipliers += 1 }
        if lanes[index].zones.insert(station.zone).inserted { score.multipliers += 1 }
    }
}
