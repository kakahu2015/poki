import AVFoundation

/// Keeps the app running in the background while a session is on, so the launcher's connections
/// (and with them the runner) stay up: a silent audio session mixed with whatever else is playing.
/// The Live Activity shows that Poki is running. Background hold measurements in Debug decide whether
/// this is enough.
@MainActor
final class KeepAlive {
    /// Keep-alives playing now (the session's and the pairing's). They share the app's one audio
    /// session, so only the last one to stop deactivates it.
    private static var playing = 0
    private var engine: AVAudioEngine?
    private var resumptionObserver: NSObjectProtocol?
    private var starting = false
    private var generation = 0

    var isOn: Bool { engine != nil }

    func start() async throws {
        try Task.checkCancellation()
        guard engine == nil, !starting else { return }
        starting = true
        generation += 1
        let number = generation
        // Reserve before suspension: a stop during activation must release this start exactly once.
        Self.playing += 1
        do {
            try await AudioSessionWork.perform {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, options: [.mixWithOthers])
                try session.setActive(true)
            }
            guard generation == number else { throw CancellationError() }
            try Task.checkCancellation()
            try startEngine()
            starting = false
        } catch {
            if generation == number {
                starting = false
                Self.playing -= 1
                Self.release()
            }
            throw error
        }
    }

    private func startEngine() throws {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        let format = engine.mainMixerNode.outputFormat(forBus: 0)
        try engine.connectNode(player, to: engine.mainMixerNode, format: format)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(format.sampleRate)) else {
            throw NSError(domain: "PokiAudio", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not allocate the silent audio buffer."])
        }
        buffer.frameLength = buffer.frameCapacity // zero-filled: silence
        engine.mainMixerNode.outputVolume = 0
        try engine.start()
        player.scheduleBuffer(buffer, at: nil, options: .loops)
        try player.playAudio()
        self.engine = engine
        // Another app can deactivate the session; resume only when iOS recommends it.
        resumptionObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.resumptionRecommendationNotification, object: nil, queue: .main) { [weak self] note in
            let context = note.userInfo?[AVAudioSession.resumptionContextKey] as? AVAudioSession.ResumptionContext
            guard context?.recommendation == .shouldResume else { return }
            Task { @MainActor in
                guard let self, let engine = self.engine else { return }
                let number = self.generation
                try? await AudioSessionWork.perform { try AVAudioSession.sharedInstance().setActive(true) }
                guard self.generation == number, self.engine === engine else { return }
                if !engine.isRunning { try? engine.start(); try? player.playAudio() }
            }
        }
    }

    /// Only a keep-alive that is playing stops anything, so stopping one never silences another.
    func stop() {
        guard engine != nil || starting else { return }
        generation += 1
        starting = false
        engine?.stop(); engine = nil
        if let resumptionObserver { NotificationCenter.default.removeObserver(resumptionObserver) }
        resumptionObserver = nil
        Self.playing -= 1
        Self.release()
    }

    private static func release() {
        if playing == 0 {
            AudioSessionWork.enqueue { try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation]) }
        }
    }
}
