import AVFoundation

/// A narrow player boundary keeps state/error tests independent of hardware timing.
@MainActor
protocol PlaybackPlayer: AnyObject {
    var duration: TimeInterval { get }
    var currentTime: TimeInterval { get set }
    var isPlaying: Bool { get }
    var enableRate: Bool { get set }
    var rate: Float { get set }
    var volume: Float { get set }
    func prepareToPlay() -> Bool
    func play() -> Bool
    func pause()
    func stop()
    func setCompletion(_ completion: (@Sendable (Bool, String?) -> Void)?)
}

@MainActor
final class AVPlaybackPlayer: PlaybackPlayer {
    private let player: AVAudioPlayer
    private var delegate: PlaybackDelegate?
    init(url: URL) throws { player = try AVAudioPlayer(contentsOf: url) }
    var duration: TimeInterval { player.duration }
    var currentTime: TimeInterval { get { player.currentTime } set { player.currentTime = newValue } }
    var isPlaying: Bool { player.isPlaying }
    var enableRate: Bool { get { player.enableRate } set { player.enableRate = newValue } }
    var rate: Float { get { player.rate } set { player.rate = newValue } }
    var volume: Float { get { player.volume } set { player.volume = newValue } }
    func prepareToPlay() -> Bool { player.prepareToPlay() }
    func play() -> Bool { player.play() }
    func pause() { player.pause() }
    func stop() { player.stop() }
    func setCompletion(_ completion: (@Sendable (Bool, String?) -> Void)?) {
        delegate = completion.map { PlaybackDelegate(completion: $0) }
        player.delegate = delegate
    }
}

/// Each play run gets a separate relay so late callbacks cannot finish a newer run.
private final class PlaybackDelegate: NSObject, AVAudioPlayerDelegate {
    let completion: @Sendable (Bool, String?) -> Void
    init(completion: @escaping @Sendable (Bool, String?) -> Void) { self.completion = completion }
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) { completion(flag, nil) }
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        completion(false, error?.localizedDescription ?? "The recording could not be decoded.")
    }
}
