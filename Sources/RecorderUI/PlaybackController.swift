import Combine
import Foundation

@MainActor
enum PlaybackState: Equatable {
    case stopped, playing, paused, finished, failed
}

@MainActor
final class PlaybackController: NSObject, ObservableObject {
    static let supportedRates: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 2]

    @Published private(set) var state: PlaybackState = .stopped
    @Published private(set) var activeID: UUID?
    @Published private(set) var title = ""
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var isScrubbing = false
    @Published private(set) var scrubPosition: TimeInterval = 0
    @Published private(set) var errorMessage: String?
    @Published private(set) var rate: Float
    @Published private(set) var volume: Float

    private let preferences: UserDefaults
    private var player: (any PlaybackPlayer)?
    private let makePlayer: (URL) throws -> any PlaybackPlayer
    private var timer: Timer?
    private var generation = UUID()
    private var resumeAfterScrubbing = false

    init(preferences: UserDefaults = .standard, makePlayer: @escaping (URL) throws -> any PlaybackPlayer = { try AVPlaybackPlayer(url: $0) }) {
        self.preferences = preferences
        self.makePlayer = makePlayer
        let storedRate = preferences.float(forKey: "playbackRate")
        self.rate = Self.supportedRates.contains(storedRate) ? storedRate : 1
        let storedVolume = preferences.object(forKey: "playbackVolume") == nil ? 1 : preferences.float(forKey: "playbackVolume")
        self.volume = storedVolume.isFinite ? min(1, max(0, storedVolume)) : 1
    }

    var isActive: Bool { activeID != nil }
    var displayedTime: TimeInterval { isScrubbing ? scrubPosition : currentTime }

    func toggle(id: UUID, title: String, url: URL) {
        if activeID == id {
            switch state {
            case .playing: pause()
            case .paused, .stopped, .finished: play()
            case .failed: start(id: id, title: title, url: url)
            }
        } else {
            start(id: id, title: title, url: url)
        }
    }

    func start(id: UUID, title: String, url: URL) {
        release()
        let token = UUID()
        generation = token
        do {
            let player = try makePlayer(url)
            guard player.duration.isFinite, player.duration > 0 else {
                throw PlaybackFailure("The recording has no playable duration.")
            }
            player.enableRate = true
            player.rate = rate
            player.volume = volume
            installDelegate(on: player, token: token)
            guard player.prepareToPlay(), player.play() else {
                throw PlaybackFailure("The recording could not be played.")
            }
            self.player = player
            activeID = id
            self.title = title
            duration = player.duration
            currentTime = player.currentTime
            scrubPosition = currentTime
            state = .playing
            errorMessage = nil
            startTimer(for: token)
        } catch {
            fail(error, id: id, title: title)
        }
    }

    func play() {
        guard let player else { return }
        generation = UUID()
        installDelegate(on: player, token: generation)
        if state == .finished || player.currentTime >= player.duration { player.currentTime = 0 }
        player.enableRate = true
        player.rate = rate
        player.volume = volume
        guard player.play() else {
            fail(PlaybackFailure("The recording could not be played."), id: activeID, title: title)
            return
        }
        currentTime = player.currentTime
        scrubPosition = currentTime
        state = .playing
        errorMessage = nil
        startTimer(for: generation)
    }

    func pause() {
        guard let player, state == .playing else { return }
        player.pause()
        generation = UUID()
        resumeAfterScrubbing = false
        currentTime = clamped(player.currentTime)
        scrubPosition = currentTime
        state = .paused
        stopTimer()
    }

    func stop() {
        guard let player else { return }
        generation = UUID()
        player.stop()
        player.currentTime = 0
        currentTime = 0
        scrubPosition = 0
        isScrubbing = false
        resumeAfterScrubbing = false
        state = .stopped
        stopTimer()
    }

    func release() {
        generation = UUID()
        player?.stop()
        player?.setCompletion(nil)
        player = nil
        stopTimer()
        activeID = nil
        title = ""
        currentTime = 0
        duration = 0
        scrubPosition = 0
        isScrubbing = false
        resumeAfterScrubbing = false
        state = .stopped
        errorMessage = nil
    }

    func updateTitle(_ value: String) { title = value }

    func skip(by seconds: TimeInterval) {
        let position = state == .finished ? duration : (player?.currentTime ?? currentTime)
        seek(to: position + seconds)
    }

    func seek(to seconds: TimeInterval) {
        guard seconds.isFinite, let player else { return }
        let position = clamped(seconds)
        player.currentTime = position
        currentTime = position
        scrubPosition = position
        if state == .finished && position < duration { state = .paused }
        if state == .playing && !isScrubbing {
            generation = UUID()
            installDelegate(on: player, token: generation)
            if position == duration {
                player.stop(); didFinish(successfully: true)
            } else {
                guard player.play() else { fail(PlaybackFailure("The recording could not be played."), id: activeID, title: title); return }
                startTimer(for: generation)
            }
        }
        // Seeking is not a play command. A paused player remains paused.
    }

    func beginScrubbing() {
        guard let player, !isScrubbing else { return }
        resumeAfterScrubbing = state == .playing
        player.pause()
        generation = UUID()
        stopTimer()
        currentTime = state == .finished ? duration : clamped(player.currentTime)
        isScrubbing = true
        scrubPosition = currentTime
    }

    func updateScrubPosition(_ seconds: TimeInterval) {
        guard seconds.isFinite, player != nil else { return }
        scrubPosition = clamped(seconds)
    }

    func endScrubbing() {
        guard isScrubbing else { return }
        isScrubbing = false
        let shouldResume = resumeAfterScrubbing
        if shouldResume { state = .paused }
        seek(to: scrubPosition)
        resumeAfterScrubbing = false
        if shouldResume {
            if currentTime == duration { player?.stop(); didFinish(successfully: true) }
            else { play() }
        }
    }

    func setRate(_ value: Float) {
        guard Self.supportedRates.contains(value) else { return }
        rate = value
        preferences.set(value, forKey: "playbackRate")
        player?.enableRate = true
        player?.rate = value
    }

    func setVolume(_ value: Float) {
        guard value.isFinite else { return }
        volume = min(1, max(0, value))
        preferences.set(volume, forKey: "playbackVolume")
        player?.volume = volume
    }

    private func startTimer(for token: UUID) {
        stopTimer()
        timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll(token: token) }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func poll(token: UUID) {
        // AVAudioPlayer resets currentTime at natural completion. Only its delegate
        // can distinguish completion from interruption; polling must not infer it.
        guard token == generation, state == .playing, !isScrubbing, let player, player.isPlaying else { return }
        if !isScrubbing {
            currentTime = clamped(player.currentTime)
            scrubPosition = currentTime
        }
    }

    private func clamped(_ value: TimeInterval) -> TimeInterval {
        min(max(0, value), duration)
    }

    private func installDelegate(on player: any PlaybackPlayer, token: UUID) {
        player.setCompletion { [weak self] success, error in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                if let error { self.fail(PlaybackFailure(error), id: self.activeID, title: self.title) }
                else { self.didFinish(successfully: success) }
            }
        }
    }

    private func didFinish(successfully: Bool) {
        guard successfully else {
            fail(PlaybackFailure("Playback ended unexpectedly."), id: activeID, title: title); return
        }
        stopTimer()
        currentTime = duration; scrubPosition = duration
        isScrubbing = false; resumeAfterScrubbing = false
        state = .finished
    }

    func fail(_ error: Error, id: UUID?, title: String) {
        generation = UUID()
        player?.stop()
        player?.setCompletion(nil)
        player = nil
        stopTimer()
        activeID = id
        self.title = title
        currentTime = 0
        duration = 0
        scrubPosition = 0
        isScrubbing = false
        resumeAfterScrubbing = false
        state = .failed
        errorMessage = error.localizedDescription
    }
}

private struct PlaybackFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
