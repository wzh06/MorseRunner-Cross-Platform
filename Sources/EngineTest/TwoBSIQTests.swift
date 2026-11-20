import XCTest
@testable import MorseRunnerCore

@MainActor
final class TwoBSIQTests: XCTestCase {
    private let rate = AudioConstants.defaultRate

    func testExchangeUsesOwnZoneAndLogsOncePerBand() async {
        let station = station("JA1ABC", zone: 25, entity: "Japan", continent: "AS")
        let session = TwoBSIQSession(call: "BH5HIE", zone: 24, wpm: 35, pitch: 600, stations: [station])
        let clock = Clock(session)

        XCTAssertTrue(session.send(.cq, on: .a, enteredCall: ""))
        XCTAssertEqual(session.display(for: .a).transmission, "CQ TEST BH5HIE")
        XCTAssertTrue(session.send(.cq, on: .b, enteredCall: ""))
        XCTAssertTrue(session.display(for: .b).queued)
        XCTAssertFalse(session.send(.cq, on: .b, enteredCall: ""))

        var heardAWithBTransmitting = false
        clock.until({
            session.suggestedAction(for: .a) == .exchange && session.suggestedAction(for: .b) == .exchange
        }, check: { block in
            if session.display(for: .b).transmission != nil && !session.display(for: .b).queued,
               block.left.contains(where: { $0 != 0 }) {
                heardAWithBTransmitting = true
                XCTAssertTrue(block.right.allSatisfy { $0 == 0 })
            }
        })
        XCTAssertTrue(heardAWithBTransmitting)

        XCTAssertTrue(session.send(.exchange, on: .a, enteredCall: " ja1abc "))
        XCTAssertEqual(session.display(for: .a).transmission, "JA1ABC ENN 24")
        XCTAssertTrue(session.send(.exchange, on: .b, enteredCall: "JA1ABC"))
        clock.until {
            session.suggestedAction(for: .a) == .finish && session.suggestedAction(for: .b) == .finish
        }
        XCTAssertTrue(session.log.isEmpty)
        XCTAssertTrue(session.send(.finish, on: .a, enteredCall: ""))
        XCTAssertEqual(session.display(for: .a).transmission, "TU BH5HIE")
        XCTAssertTrue(session.send(.finish, on: .b, enteredCall: ""))
        clock.until { session.log.count == 2 }
        XCTAssertEqual(session.log.map(\.call), ["JA1ABC", "JA1ABC"])
        XCTAssertEqual(session.log.map(\.zone), [25, 25])
        XCTAssertEqual(session.log.map(\.band), [.a, .b])
        XCTAssertEqual(session.score.qsos, 2)
        XCTAssertEqual(session.score.points, 2)
        XCTAssertEqual(session.score.multipliers, 4)
        XCTAssertEqual(session.score.total, 8)
        XCTAssertEqual(session.display(for: .a).status, "No remaining stations")
        clock.advance(by: rate)
        XCTAssertEqual(session.log.count, 2)
    }

    func testWrongCallSilenceRetryAndCancelPreserveOtherBand() async {
        let session = TwoBSIQSession(call: "BH5HIE", zone: 24, wpm: 30, pitch: 600,
                                     stations: [station("JA1ABC", zone: 25, entity: "Japan", continent: "AS")])
        let clock = Clock(session)
        XCTAssertTrue(session.send(.cq, on: .a, enteredCall: ""))
        clock.until { session.suggestedAction(for: .a) == .exchange }
        XCTAssertTrue(session.send(.exchange, on: .a, enteredCall: "JA1XYZ"))
        clock.until { session.display(for: .a).status == "No reply" }
        clock.advance(by: rate, check: { block in
            XCTAssertTrue(block.left.allSatisfy { $0 == 0 })
        })
        XCTAssertEqual(session.suggestedAction(for: .a), .exchange)
        XCTAssertTrue(session.send(.exchange, on: .a, enteredCall: "JA1ABC"))
        XCTAssertTrue(session.send(.cq, on: .b, enteredCall: ""))
        let aDraft = session.display(for: .a).draftVersion
        session.cancel(selected: .b)
        XCTAssertNil(session.display(for: .a).transmission)
        XCTAssertNil(session.display(for: .b).transmission)
        XCTAssertEqual(session.display(for: .a).draftVersion, aDraft)
        XCTAssertEqual(session.suggestedAction(for: .b), .cq)
        XCTAssertTrue(session.send(.exchange, on: .a, enteredCall: "JA1ABC"))
        clock.until { session.suggestedAction(for: .a) == .finish }
        XCTAssertTrue(session.send(.finish, on: .a, enteredCall: ""))
        session.cancel(selected: .a)
        XCTAssertTrue(session.log.isEmpty)
        XCTAssertEqual(session.suggestedAction(for: .a), .finish)
        clock.advance(by: 21 * rate)
        XCTAssertEqual(session.suggestedAction(for: .a), .cq)
        XCTAssertEqual(session.display(for: .a).status, "Caller timed out")
    }

    func testAcceptedQueueSurvivesReplyDeadline() async {
        let session = TwoBSIQSession(call: "BH5HIE", zone: 24, wpm: 30, pitch: 600,
                                     stations: [station("K1A", zone: 5, entity: "United States of America", continent: "NA")],
                                     waitSamples: rate / 8, replyDelay: 0)
        let clock = Clock(session)
        XCTAssertTrue(session.send(.cq, on: .a, enteredCall: ""))
        XCTAssertTrue(session.send(.cq, on: .b, enteredCall: ""))
        clock.until { session.suggestedAction(for: .a) == .exchange }
        XCTAssertTrue(session.send(.exchange, on: .a, enteredCall: "K1A"))
        XCTAssertTrue(session.display(for: .a).queued)
        clock.advance(by: rate / 4)
        XCTAssertEqual(session.display(for: .a).transmission, "K1A ENN 24")
        clock.until { session.suggestedAction(for: .a) == .finish }
    }

    func testTURollsIntoNextCaller() async {
        let session = TwoBSIQSession(call: "BH5HIE", zone: 24, wpm: 30, pitch: 600, stations: [
            station("JA1ABC", zone: 25, entity: "Japan", continent: "AS"),
            station("K1A", zone: 5, entity: "United States of America", continent: "NA")
        ])
        let clock = Clock(session)
        XCTAssertTrue(session.send(.cq, on: .a, enteredCall: ""))
        clock.until { session.suggestedAction(for: .a) == .exchange }
        XCTAssertTrue(session.send(.exchange, on: .a, enteredCall: "JA1ABC"))
        clock.until { session.suggestedAction(for: .a) == .finish }
        XCTAssertTrue(session.send(.finish, on: .a, enteredCall: ""))
        clock.until { session.suggestedAction(for: .a) == .exchange }
        XCTAssertEqual(session.log.map(\.call), ["JA1ABC"])
        XCTAssertTrue(session.send(.exchange, on: .a, enteredCall: "K1A"))
        clock.until { session.suggestedAction(for: .a) == .finish }
    }

    func testZonesPreferExactCallsAndRejectAmbiguousFallbacks() async {
        let catalog = TwoBSIQCatalog(history: """
            N1TEST,03,
            BH5ABC,23,
            VE2ABC,02,
            VE2ABC,05,
            JA1LONG,25,
            JA1ABC/P,25,
            JA1ABC,25,
            """)
        XCTAssertEqual(catalog.zone(for: " n1test "), 3)
        XCTAssertEqual(catalog.zone(for: "BH5ABC"), 23)
        XCTAssertEqual(catalog.zone(for: "BH5HIE"), 24)
        XCTAssertEqual(catalog.zone(for: "BY3GAB"), 23)
        XCTAssertEqual(catalog.zone(for: "BY3XAB"), 24)
        XCTAssertEqual(catalog.zone(for: "BY9SAB"), 23)
        XCTAssertEqual(catalog.zone(for: "BY9FAB"), 24)
        XCTAssertEqual(catalog.zone(for: "BG0DXC"), 23)
        XCTAssertEqual(catalog.zone(for: "JA1ZZZ"), 25)
        XCTAssertNil(catalog.zone(for: "VE2ABC"))
        XCTAssertNil(catalog.zone(for: "N1ZZZ"))
        XCTAssertNil(catalog.zone(for: "JA"))
        XCTAssertEqual(catalog.stations.map(\.call), ["BH5ABC", "JA1ABC", "N1TEST"])
    }

    func testCharacterBoundariesFollowTheKeyerAtDifferentSpeeds() async {
        for wpm in [10, 30, 120] {
            let keyer = Keyer()
            keyer.setWpm(wpm)
            let message = TwoBSIQMessage("E N", keyer: keyer)
            let unit = keyer.samplesPerUnit
            let eEnd = unit + keyer.rampLen
            XCTAssertEqual(message.remaining(after: eEnd - 1), "E N")
            XCTAssertEqual(message.remaining(after: eEnd), " N")
            XCTAssertEqual(message.remaining(after: 6 * unit), "N")
            XCTAssertEqual(message.remaining(after: 11 * unit + keyer.rampLen), "")
            XCTAssertEqual(message.sampleCount, 15 * unit)

            let session = TwoBSIQSession(call: "BH5HIE", zone: 24, wpm: wpm, pitch: 600, stations: [])
            let clock = Clock(session)
            XCTAssertTrue(session.send(.cq, on: .a, enteredCall: ""))
            let cq = TwoBSIQMessage("CQ TEST BH5HIE", keyer: keyer)
            clock.advance(by: cq.characterEnds[0] - 1)
            XCTAssertEqual(session.display(for: .a).transmission, "CQ TEST BH5HIE")
            clock.advance(by: 1)
            XCTAssertEqual(session.display(for: .a).transmission, "Q TEST BH5HIE")
        }
    }

    func testStereoSeparationEndpointsAndMidpoint() async {
        let a: SampleArray = [1, 0]
        let b: SampleArray = [0, 1]
        let mono = TwoBSIQSession.mix(a: a, b: b, separation: 0)
        XCTAssertEqual(mono.left, [0.5, 0.5])
        XCTAssertEqual(mono.left, mono.right)
        let half = TwoBSIQSession.mix(a: a, b: b, separation: 0.5)
        XCTAssertEqual(half.left, [0.75, 0.25])
        XCTAssertEqual(half.right, [0.25, 0.75])
        let stereo = TwoBSIQSession.mix(a: a, b: b, separation: 1)
        XCTAssertEqual(stereo.left, a)
        XCTAssertEqual(stereo.right, b)
    }

    func testSpeedChangesKeepTheCurrentCallersSpeed() async {
        let session = TwoBSIQSession(call: "BH5HIE", zone: 24, wpm: 60, pitch: 600, stations: [
            station("JA1ABC", zone: 25, entity: "Japan", continent: "AS")
        ], replyDelay: 0)
        let clock = Clock(session)
        XCTAssertTrue(session.send(.cq, on: .a, enteredCall: ""))
        clock.until { session.display(for: .a).stage == .receivingCall }

        session.setSpeed(wpm: 32, slowerBy: 4, fasterBy: 6)
        XCTAssertEqual(session.receiveSpeedRange, 28...38)
        session.setSpeed(wpm: 10, slowerBy: 10, fasterBy: 2)
        XCTAssertEqual(session.receiveSpeedRange, 10...12)
        session.setSpeed(wpm: 120, slowerBy: 2, fasterBy: 10)
        XCTAssertEqual(session.receiveSpeedRange, 118...120)
        clock.until { session.suggestedAction(for: .a) == .exchange }
        XCTAssertTrue(session.send(.exchange, on: .a, enteredCall: "JA1ABC"))

        let keyer = Keyer()
        keyer.setWpm(120)
        let outgoing = TwoBSIQMessage("JA1ABC ENN 24", keyer: keyer)
        clock.advance(by: outgoing.sampleCount - 1)
        XCTAssertNotNil(session.display(for: .a).transmission)
        clock.advance(by: 1)
        XCTAssertEqual(session.display(for: .a).stage, .receivingReport)

        keyer.setWpm(60)
        let report = TwoBSIQMessage("5NN 25", keyer: keyer)
        let bufferLead = clock.rendered - clock.played
        clock.advance(by: bufferLead + report.sampleCount - 1)
        XCTAssertEqual(session.display(for: .a).stage, .receivingReport)
        clock.advance(by: 1)
        XCTAssertEqual(session.display(for: .a).stage, .awaitingTU)
    }

    private func station(_ call: String, zone: Int, entity: String, continent: String) -> TwoBSIQCatalog.Station {
        .init(call: call, zone: zone, entity: entity, continent: continent)
    }

    @MainActor
    private final class Clock {
        let session: TwoBSIQSession
        var played = 0
        var rendered = 0

        init(_ session: TwoBSIQSession) { self.session = session }

        func advance(by samples: Int, check: (TwoBSIQStereoBlock) -> Void = { _ in }) {
            let target = played + samples
            while rendered < target {
                let block = session.renderAudio()
                check(block)
                rendered += AudioConstants.defaultBufSize
                session.advancePlayback(to: min(rendered, target))
            }
            played = target
            session.advancePlayback(to: played)
        }

        func until(_ matches: () -> Bool, check: (TwoBSIQStereoBlock) -> Void = { _ in }) {
            for _ in 0..<700 {
                if matches() { return }
                advance(by: AudioConstants.defaultBufSize, check: check)
            }
            XCTFail("Timed out waiting for a radio state")
        }
    }
}
