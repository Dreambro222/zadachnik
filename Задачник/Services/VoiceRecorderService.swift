import Foundation
import AVFoundation
import Speech
import UniformTypeIdentifiers

// MARK: - Voice Recorder + Transcription

@MainActor
final class VoiceRecorderService: NSObject, ObservableObject {
    static let shared = VoiceRecorderService()

    @Published var isRecording = false
    @Published var isTranscribing = false
    @Published var recordingDuration: TimeInterval = 0
    @Published var audioLevel: Float = 0

    private var audioRecorder: AVAudioRecorder?
    private var audioPlayer: AVAudioPlayer?
    private var avPlayer: AVPlayer?          // fallback for formats AVAudioPlayer can't handle (ogg, opus, webm)
    private var timer: Timer?
    private var currentFileURL: URL?
    private var onFinishCallback: (() -> Void)?

    private override init() {
        super.init()
        createVoiceMemosDirectory()
    }

    private func createVoiceMemosDirectory() {
        let dir = voiceMemosDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    var voiceMemosDirectory: URL {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoiceMemos", isDirectory: true)
    }

    // MARK: - Recording

    func startRecording() throws -> URL {
        let fileName = "memo_\(UUID().uuidString).m4a"
        let fileURL = voiceMemosDirectory.appendingPathComponent(fileName)
        currentFileURL = fileURL

        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .default, options: [])
        try session.setActive(true)
        #endif

        let settings: [String: Any] = [
            AVFormatIDKey:             Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey:           44100,
            AVNumberOfChannelsKey:     1,
            AVEncoderAudioQualityKey:  AVAudioQuality.high.rawValue
        ]

        audioRecorder = try AVAudioRecorder(url: fileURL, settings: settings)
        audioRecorder?.isMeteringEnabled = true
        audioRecorder?.record()

        isRecording = true
        recordingDuration = 0

        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.recordingDuration += 0.1
            self.audioRecorder?.updateMeters()
            let power = self.audioRecorder?.averagePower(forChannel: 0) ?? -60
            self.audioLevel = max(0, (power + 60) / 60)
        }

        return fileURL
    }

    func stopRecording() -> (url: URL, duration: TimeInterval)? {
        guard isRecording, let recorder = audioRecorder else { return nil }
        let duration = recorder.currentTime
        recorder.stop()
        timer?.invalidate()
        timer = nil
        isRecording = false
        audioLevel = 0

        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif

        guard let url = currentFileURL else { return nil }
        return (url, duration)
    }

    // MARK: - Playback

    /// OGG/Opus/WebM go through AVPlayer; everything else through AVAudioPlayer.
    private static let avPlayerFormats: Set<String> = ["ogg", "oga", "opus", "webm"]

    func play(url: URL, onFinish: @escaping () -> Void) throws {
        stopPlayback()
        onFinishCallback = onFinish

        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif

        let ext = url.pathExtension.lowercased()
        if Self.avPlayerFormats.contains(ext) {
            let item = AVPlayerItem(url: url)
            avPlayer = AVPlayer(playerItem: item)
            // Observe end of playback
            NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak self] _ in
                self?.onFinishCallback?()
                self?.onFinishCallback = nil
            }
            avPlayer?.play()
        } else {
            audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer?.play()
            // Poll for completion (AVAudioPlayer delegate requires NSObject)
            let duration = audioPlayer?.duration ?? 0
            if duration > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
                    self?.onFinishCallback?()
                    self?.onFinishCallback = nil
                }
            }
        }
    }

    func stopPlayback() {
        audioPlayer?.stop()
        audioPlayer = nil
        avPlayer?.pause()
        avPlayer = nil
        NotificationCenter.default.removeObserver(self, name: .AVPlayerItemDidPlayToEndTime, object: nil)
        onFinishCallback = nil
    }

    // MARK: - Import external audio file (copies to VoiceMemos dir)

    /// Supported import formats (Whisper-compatible + AVFoundation-playable)
    static let importableTypes: [UTType] = [
        .audio, .mp3, .mpeg4Audio,
        UTType("audio/ogg") ?? .audio,
        UTType("audio/opus") ?? .audio,
        UTType("org.xiph.ogg") ?? .audio,
        UTType("public.ogg-vorbis") ?? .audio,
        UTType("audio/webm") ?? .audio,
        UTType(filenameExtension: "ogg") ?? .audio,
        UTType(filenameExtension: "opus") ?? .audio,
        UTType(filenameExtension: "webm") ?? .audio,
        .wav, .aiff
    ]

    /// Sync version for use in non-async contexts (duration may be 0 for ogg).
    func importAudioSync(from sourceURL: URL) throws -> (url: URL, duration: TimeInterval) {
        let ext  = sourceURL.pathExtension.isEmpty ? "ogg" : sourceURL.pathExtension
        let name = "import_\(UUID().uuidString).\(ext)"
        let dest = voiceMemosDirectory.appendingPathComponent(name)
        try FileManager.default.copyItem(at: sourceURL, to: dest)
        let asset    = AVURLAsset(url: dest)
        let seconds  = CMTimeGetSeconds(asset.duration)
        let duration = seconds.isNaN || seconds.isInfinite ? 0 : seconds
        return (dest, duration)
    }

    // MARK: - Transcription

    func transcribe(url: URL) async -> String {
        if SFSpeechRecognizer.authorizationStatus() != .authorized {
            await requestSpeechPermission()
            guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
                return ""
            }
        }

        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ru-RU"))
            ?? SFSpeechRecognizer(locale: Locale.current)

        guard let recognizer, recognizer.isAvailable else { return "" }

        return await withCheckedContinuation { continuation in
            let request = SFSpeechURLRecognitionRequest(url: url)
            request.shouldReportPartialResults = false

            recognizer.recognitionTask(with: request) { result, error in
                if let result, result.isFinal {
                    continuation.resume(returning: result.bestTranscription.formattedString)
                } else if error != nil {
                    continuation.resume(returning: "")
                }
            }
        }
    }

    private func requestSpeechPermission() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            SFSpeechRecognizer.requestAuthorization { _ in
                continuation.resume()
            }
        }
    }

    // MARK: - Permissions

    func requestMicrophonePermission() async -> Bool {
        #if os(iOS)
        return await AVAudioApplication.requestRecordPermission()
        #else
        return await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
        #endif
    }
}
