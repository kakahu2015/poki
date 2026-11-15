import AVFoundation
import CoreLocation
import Foundation

/// Keeps Poki running in the background while it is on, so the relay connection and the launcher stay
/// up. Silent audio does it; location is the backup only when it is needed: while a pairing waits in
/// Settings, and when the silent audio cannot play (it failed to start, or another app's audio
/// interrupted it), when iOS would otherwise suspend Poki mid-session. Then it is the coarsest
/// accuracy, with no indicator under Always Allow, and it stops again as soon as the audio is back.
/// The location is never read or sent anywhere.
@MainActor
@Observable
final class BackgroundKeeper: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var activity: CLBackgroundActivitySession?
    private let audio = KeepAlive()
    private(set) var authorization: CLAuthorizationStatus
    private(set) var isOn = false

    override init() {
        authorization = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        manager.distanceFilter = CLLocationDistanceMax
        manager.pausesLocationUpdatesAutomatically = false
    }

    var allowed: Bool { authorization == .authorizedWhenInUse || authorization == .authorizedAlways }
    var denied: Bool { authorization == .denied || authorization == .restricted }

    /// Always Allow lets Poki stay up without the location pill. iOS asks for While Using first and
    /// offers the upgrade on the second request.
    var always: Bool { authorization == .authorizedAlways }

    func requestPermission() {
        if authorization == .notDetermined { manager.requestWhenInUseAuthorization() } else { manager.requestAlwaysAuthorization() }
    }

    /// Called while Poki is in front (iOS only starts background location from the foreground).
    func start() {
        guard !isOn else { return }
        isOn = true
        // iOS 27 and later: the system's continued processing task keeps Poki up, with no audio and
        // no location. Silent audio only when iOS refuses it or ends it early.
        let run = ContinuedRun.shared
        continued = run
        run.onExpired = { [weak self] in
            guard let self, self.isOn else { return }
            self.startAudio(); self.watchInterruptions()
        }
        Task { @MainActor [weak self] in
            guard let self, self.isOn else { return }
            let began = await run.begin(subtitle: AppLocalization.text(LocalizedStringResource("Agents can reach this iPhone")))
            guard self.isOn else { run.end(); return }
            if began { return }
            self.startAudio()
            self.watchInterruptions()
        }
    }

    /// The iOS 27 continued run.
    private var continued: ContinuedRun?

    /// Silent audio could not hold Poki up (it would be suspended): location stands in until it can.
    private(set) var audioLost = false
    private var deactivationObserver: NSObjectProtocol?
    private var resumptionObserver: NSObjectProtocol?
    private var audioStart: Task<Void, Never>?

    private func startAudio() {
        guard isOn, !audioPaused, audioStart == nil else { return }
        audioStart = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled, self.isOn, !self.audioPaused else { return }
            do {
                try await self.audio.start()
                guard !Task.isCancelled, self.isOn, !self.audioPaused else { return }
                self.setAudioLost(false)
            } catch {
                guard !Task.isCancelled, self.isOn, !self.audioPaused else { return }
                self.setAudioLost(true)
            }
            self.audioStart = nil
        }
    }

    private func stopAudio() {
        audioStart?.cancel(); audioStart = nil
        audio.stop()
    }

    private func setAudioLost(_ lost: Bool) {
        guard lost != audioLost else { return }
        audioLost = lost
        AppLog.shared.add("background", lost ? "silent audio stopped: location keeps Poki running until it is back" : "silent audio back: location off")
        if lost { startLocation() } else if !pairingHold { stopLocation() }
    }

    private func watchInterruptions() {
        guard deactivationObserver == nil else { return }
        deactivationObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.didBecomeInactiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isOn, !self.audioPaused else { return }
                self.setAudioLost(true)
            }
        }
        resumptionObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.resumptionRecommendationNotification, object: nil, queue: .main) { [weak self] note in
            let context = note.userInfo?[AVAudioSession.resumptionContextKey] as? AVAudioSession.ResumptionContext
            guard context?.recommendation == .shouldResume else { return }
            Task { @MainActor in
                guard let self, self.isOn, !self.audioPaused else { return }
                // KeepAlive handles the recommendation too; allow it to restart before using location.
                try? await Task.sleep(for: .seconds(1))
                if self.audio.isOn { self.setAudioLost(false) } else { self.stopAudio(); self.startAudio() }
            }
        }
    }

    /// A voice conversation needs the audio session for the microphone; the voice-chat session keeps
    /// Poki running meanwhile. The silent audio comes back when it ends, if Poki is still on.
    /// While a voice conversation holds the audio session (it keeps Poki running itself).
    private var audioPaused = false
    func pauseAudio() { audioPaused = true; stopAudio() }
    func resumeAudio() {
        audioPaused = false
        guard isOn else { return }
        if continued?.isRunning == true { return }
        startAudio()
    }

    func stop() {
        guard isOn else { return }
        isOn = false
        continued?.end()
        continued = nil
        audioLost = false
        if let deactivationObserver { NotificationCenter.default.removeObserver(deactivationObserver) }
        if let resumptionObserver { NotificationCenter.default.removeObserver(resumptionObserver) }
        deactivationObserver = nil
        resumptionObserver = nil
        if !pairingHold { stopLocation() }
        stopAudio()
    }

    /// While a pairing waits in Settings, location keeps Poki running (with the silent audio), so the
    /// pairing listener answers when Settings connects. While Using is enough here: the updates start
    /// in front, and a CLBackgroundActivitySession carries them into the background (iOS shows its
    /// location indicator meanwhile). Ended when the pairing ends.
    private(set) var pairingHold = false
    func holdForPairing() {
        guard !pairingHold else { return }
        pairingHold = true
        if authorization == .notDetermined { manager.requestWhenInUseAuthorization() }
        startPairingLocation()
    }

    func releasePairing() {
        guard pairingHold else { return }
        pairingHold = false
        activity?.invalidate(); activity = nil
        if isOn && audioLost { startLocation() } else { stopLocation() }
    }

    private func startPairingLocation() {
        guard pairingHold, allowed else { return }
        if activity == nil { activity = CLBackgroundActivitySession() }
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = !always
        manager.startUpdatingLocation()
    }

    private func startLocation() {
        if pairingHold { startPairingLocation(); return }
        guard audioLost, allowed else { stopLocation(); return }
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = !always
        if !always, activity == nil { activity = CLBackgroundActivitySession() }
        manager.startUpdatingLocation()
    }

    private func stopLocation() {
        manager.stopUpdatingLocation()
        activity?.invalidate(); activity = nil
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorization = status
            if self.pairingHold || (self.isOn && self.audioLost) { self.startLocation() }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {}
    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
