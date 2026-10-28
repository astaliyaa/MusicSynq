import AVFoundation

/**
 * iOS suspends apps shortly after they leave the screen, which would freeze
 * sync the moment the host switches to the Music app or anyone locks their
 * phone. Apps with the "audio" background mode keep running while they have
 * audio going, so during a party we play silence, mixed with other audio so
 * it never interrupts the actual music.
 *
 * Note for App Store review: Apple may push back on playing silence to stay
 * awake. For personal use and TestFlight it works fine; you can also turn it
 * off in Settings (then keep the app open during a party).
 */
@MainActor
final class BackgroundKeepAlive {
    private var engine = AVAudioEngine()
    private var player = AVAudioPlayerNode()
    private var isConfigured = false
    private(set) var isActive = false
    private var observers: [Task<Void, Never>] = []

    func start() {
        guard !isActive else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            configureIfNeeded()
            try engine.start()
            player.play()
            isActive = true
            observeInterruptions()
        } catch {
            print("[KeepAlive] couldn't start: \(error)")
        }
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        observers.forEach { $0.cancel() }
        observers.removeAll()
        player.stop()
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func configureIfNeeded() {
        guard !isConfigured else { return }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100) else { return }
        buffer.frameLength = buffer.frameCapacity
        if let channels = buffer.floatChannelData {
            for channel in 0..<Int(format.channelCount) {
                channels[channel].update(repeating: 0, count: Int(buffer.frameLength))
            }
        }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        player.scheduleBuffer(buffer, at: nil, options: .loops)
        isConfigured = true
    }

    /** A phone call or Siri stops our engine; start it again afterwards. */
    private func observeInterruptions() {
        observers.append(Task { [weak self] in
            for await notification in NotificationCenter.default.notifications(named: AVAudioSession.interruptionNotification) {
                guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      AVAudioSession.InterruptionType(rawValue: raw) == .ended else { continue }
                self?.restart()
            }
        })
        observers.append(Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: AVAudioSession.mediaServicesWereResetNotification) {
                self?.rebuild()
            }
        })
    }

    private func restart() {
        guard isActive else { return }
        stop()
        start()
    }

    /** After the system's media services restart, the old engine is dead. */
    private func rebuild() {
        guard isActive else { return }
        stop()
        engine = AVAudioEngine()
        player = AVAudioPlayerNode()
        isConfigured = false
        start()
    }
}
