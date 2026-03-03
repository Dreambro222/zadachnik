import Foundation
import AVFoundation

// MARK: - Call Recorder via BlackHole or system mic
// Захватывает аудио с выбранного устройства (BlackHole 2ch или микрофон)
// и сохраняет в файл .m4a в Documents/VoiceMemos/

@MainActor
final class CallRecorderService: NSObject, ObservableObject {
    static let shared = CallRecorderService()

    @Published var isRecording = false
    @Published var recordingDuration: TimeInterval = 0
    @Published var audioLevel: Float = 0
    @Published var blackHoleAvailable = false
    @Published var selectedInputDevice: AVCaptureDevice? = nil

    private var engine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var currentFileURL: URL?
    private var timer: Timer?
    private var levelTimer: Timer?

    private override init() {
        super.init()
        checkBlackHoleAvailability()
    }

    // MARK: - BlackHole Detection

    func checkBlackHoleAvailability() {
        #if os(macOS)
        let devices = AVCaptureDevice.devices(for: .audio)
        blackHoleAvailable = devices.contains { $0.localizedName.lowercased().contains("blackhole") }
        NSLog("[CallRecorder] BlackHole available: \(blackHoleAvailable)")
        #else
        blackHoleAvailable = false
        #endif
    }

    /// Возвращает список доступных аудио-входов (для выбора в UI)
    func availableInputDevices() -> [AVCaptureDevice] {
        #if os(macOS)
        return AVCaptureDevice.devices(for: .audio)
        #else
        return []
        #endif
    }

    var blackHoleDevice: AVCaptureDevice? {
        #if os(macOS)
        AVCaptureDevice.devices(for: .audio)
            .first { $0.localizedName.lowercased().contains("blackhole") }
        #else
        nil
        #endif
    }

    // MARK: - Recording

    /// Начинает запись. useBlackHole=true — пишет системный звук (оба голоса).
    /// useBlackHole=false — пишет только микрофон.
    func startRecording(useBlackHole: Bool = true) throws -> URL {
        let fileName = "call_\(UUID().uuidString).m4a"
        let dir = voiceMemosDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = dir.appendingPathComponent(fileName)
        currentFileURL = fileURL

        NSLog("[CallRecorder] Start recording → \(fileName), useBlackHole=\(useBlackHole)")

        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [.allowBluetooth])
        try session.setActive(true)
        let newEngine = AVAudioEngine()
        let inputNode = newEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        audioFile = try AVAudioFile(forWriting: fileURL, settings: format.settings)
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            try? self?.audioFile?.write(from: buffer)
            let level = self?.calculateLevel(buffer: buffer) ?? 0
            Task { @MainActor in self?.audioLevel = level }
        }
        try newEngine.start()
        engine = newEngine

        #elseif os(macOS)
        let newEngine = AVAudioEngine()

        if useBlackHole, let bhDevice = blackHoleDevice {
            // Переключаем движок на BlackHole
            try setEngineInputToBlackHole(engine: newEngine, device: bhDevice)
        }

        let inputNode = newEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        guard format.sampleRate > 0 else {
            throw RecorderError.formatUnavailable
        }

        audioFile = try AVAudioFile(forWriting: fileURL, settings: format.settings)
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            try? self?.audioFile?.write(from: buffer)
            let level = self?.calculateLevel(buffer: buffer) ?? 0
            Task { @MainActor in self?.audioLevel = level }
        }
        try newEngine.start()
        engine = newEngine
        #endif

        isRecording = true
        recordingDuration = 0
        startTimers()
        return fileURL
    }

    func stopRecording() -> (url: URL, duration: TimeInterval)? {
        guard isRecording, let eng = engine else { return nil }
        let duration = recordingDuration

        eng.inputNode.removeTap(onBus: 0)
        eng.stop()
        engine = nil
        audioFile = nil

        stopTimers()
        isRecording = false
        audioLevel = 0

        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif

        NSLog("[CallRecorder] Stop recording, duration=\(duration)s")
        guard let url = currentFileURL else { return nil }
        return (url, duration)
    }

    // MARK: - macOS: set AVAudioEngine input to BlackHole

    #if os(macOS)
    private func setEngineInputToBlackHole(engine: AVAudioEngine, device: AVCaptureDevice) throws {
        // Устанавливаем CoreAudio device для AVAudioEngine через AudioUnit
        guard let audioUnit = engine.inputNode.audioUnit else {
            NSLog("[CallRecorder] No audioUnit on inputNode")
            return
        }

        var deviceID: AudioDeviceID = AudioDeviceID(kAudioDeviceUnknown)

        // Ищем AudioDeviceID по имени через CoreAudio
        var propSize: UInt32 = 0
        var propAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &propAddr, 0, nil, &propSize)
        let deviceCount = Int(propSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propAddr, 0, nil, &propSize, &deviceIDs)

        for id in deviceIDs {
            var nameSize: UInt32 = UInt32(MemoryLayout<CFString>.size)
            var nameAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceNameCFString,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var nameRef: CFString = "" as CFString
            AudioObjectGetPropertyData(id, &nameAddr, 0, nil, &nameSize, &nameRef)
            let name = nameRef as String
            if name.lowercased().contains("blackhole") {
                deviceID = id
                NSLog("[CallRecorder] Found BlackHole device ID: \(id), name: \(name)")
                break
            }
        }

        guard deviceID != AudioDeviceID(kAudioDeviceUnknown) else {
            NSLog("[CallRecorder] BlackHole device ID not found via CoreAudio, using default input")
            return
        }

        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        NSLog("[CallRecorder] Set BlackHole as input device, status=\(status)")
    }
    #endif

    // MARK: - Helpers

    private var voiceMemosDirectory: URL {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoiceMemos", isDirectory: true)
    }

    private func calculateLevel(buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0] else { return 0 }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<frameLength { sum += abs(data[i]) }
        return min(1.0, sum / Float(frameLength) * 10)
    }

    private func startTimers() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.recordingDuration += 0.1 }
        }
    }

    private func stopTimers() {
        timer?.invalidate()
        timer = nil
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

// MARK: - Errors

enum RecorderError: LocalizedError {
    case formatUnavailable
    case blackHoleNotFound

    var errorDescription: String? {
        switch self {
        case .formatUnavailable: return "Не удалось получить формат аудио устройства"
        case .blackHoleNotFound: return "BlackHole не найден. Установите через: brew install blackhole-2ch"
        }
    }
}
