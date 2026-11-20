import AVFoundation
import MorseRunnerCore

@MainActor
final class TwoBSIQAudio {
    private let format = AVAudioFormat(standardFormatWithSampleRate: Double(AudioConstants.defaultRate), channels: 2)!
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var timer: Timer?
    private var scheduled = 0
    private var silenceStarted = 0.0

    /// Returns false if the device failed and the sample clock is running silently.
    @discardableResult
    func start(session: TwoBSIQSession, volume: Float, didAdvance: @escaping @MainActor () -> Void) -> Bool {
        stop()
        let silent = ProcessInfo.processInfo.environment["MORSE_RUNNER_NO_AUDIO"] == "1"
        if !silent {
            let engine = AVAudioEngine()
            let device = engine.outputNode.outputFormat(forBus: 0)
            if device.channelCount > 0, device.sampleRate > 0 {
                let player = AVAudioPlayerNode()
                engine.attach(player)
                engine.connect(player, to: engine.mainMixerNode, format: format)
                do {
                    try engine.start()
                    player.volume = volume
                    self.engine = engine
                    self.player = player
                    fill(session: session, played: 0, player: player)
                    player.play()
                } catch {
                    NSLog("2BSIQ audio: %@", String(describing: error))
                }
            }
        }
        silenceStarted = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: player == nil ? 0.01 : 0.004, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.advance(session)
                didAdvance()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        return silent || player != nil
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        player?.stop()
        engine?.stop()
        player = nil
        engine = nil
        scheduled = 0
    }

    private func advance(_ session: TwoBSIQSession) {
        if let player {
            let played = player.lastRenderTime
                .flatMap { player.playerTime(forNodeTime: $0) }
                .map { max(0, Int($0.sampleTime)) } ?? 0
            session.advancePlayback(to: played)
            fill(session: session, played: played, player: player)
        } else {
            let played = Int((ProcessInfo.processInfo.systemUptime - silenceStarted) * Double(AudioConstants.defaultRate))
            while scheduled < played {
                _ = session.renderAudio()
                scheduled += AudioConstants.defaultBufSize
                session.advancePlayback(to: min(played, scheduled))
            }
            session.advancePlayback(to: played)
        }
    }

    private func fill(session: TwoBSIQSession, played: Int, player: AVAudioPlayerNode) {
        let count = AudioConstants.defaultBufSize
        while scheduled - played < count {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
                  let channels = buffer.floatChannelData else { return }
            let block = session.renderAudio()
            buffer.frameLength = AVAudioFrameCount(count)
            for index in 0..<count {
                channels[0][index] = block.left[index]
                channels[1][index] = block.right[index]
            }
            scheduled += count
            player.scheduleBuffer(buffer, at: nil, options: [])
        }
    }
}
