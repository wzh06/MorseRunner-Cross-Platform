import Foundation

/// A CW message and the sample positions at which its displayed characters
/// have finished. Both the waveform and the boundaries use the same keyer.
struct TwoBSIQMessage {
    let characters: [Character]
    let characterEnds: [Int]
    let envelope: SampleArray
    let sampleCount: Int

    var text: String { String(characters) }

    init(_ text: String, keyer: Keyer) {
        characters = Array(text)
        keyer.morseMsg = keyer.encode(text)
        envelope = keyer.getEnvelope()
        sampleCount = keyer.trueEnvelopeLen

        let unit = keyer.samplesPerUnit
        var units = 0
        characterEnds = characters.map { character in
            if character == " " {
                units += 2
                return units * unit
            }
            let code = keyer.morse[character] ?? ""
            for symbol in code {
                switch symbol {
                case ".": units += 2
                case "-": units += 4
                default: break
                }
            }
            // The final element is followed by one off unit, starting
            // with the fall ramp. Remove the letter when that ramp ends.
            let end = max(0, (units - 1) * unit + keyer.rampLen)
            units += 2
            return end
        }
    }

    func remaining(after samplesPlayed: Int) -> String {
        let firstPending = characterEnds.firstIndex { $0 > samplesPlayed } ?? characters.endIndex
        return String(characters[firstPending...])
    }
}
