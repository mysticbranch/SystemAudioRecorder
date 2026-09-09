// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SystemAudioRecorder",
    platforms: [.macOS("14.2")],
    products: [.executable(name: "SystemAudioRecorder", targets: ["RecorderApp"])],
    targets: [
        .target(name: "RNNoise", path: "Vendor/RNNoise", exclude: ["AUTHORS", "COPYING", "Makefile.am", "UPSTREAM-SHA256.json", "LOCAL-SHA256.json", "README.md", "examples"],
                sources: ["RecorderDenoise.c", "src/denoise.c", "src/rnn.c", "src/rnn_data.c", "src/pitch.c", "src/kiss_fft.c", "src/celt_lpc.c"], publicHeadersPath: "include",
                cSettings: [.headerSearchPath("src"), .define("RNNOISE_BUILD")]),
        .target(name: "AudioTransport", publicHeadersPath: "include"),
        .target(name: "RecorderCore"),
        .target(name: "RecorderAudio", dependencies: ["RecorderCore", "AudioTransport", "RNNoise"]),
        .target(name: "RecorderUI", dependencies: ["RecorderCore", "RecorderAudio"]),
        .executableTarget(name: "RecorderApp", dependencies: ["RecorderCore", "RecorderUI"]),
        .executableTarget(name: "RecorderChecks", dependencies: ["RecorderCore", "RecorderAudio", "RecorderUI", "AudioTransport"], path: "Tests/RecorderChecks"),
    ]
)
