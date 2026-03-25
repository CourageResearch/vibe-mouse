@preconcurrency import Foundation
import AVFoundation

@MainActor
final class WhisperDictationService {
    enum WhisperError: Error {
        case failed(String)
    }

    enum ToggleResult {
        case started
        case transcribed(String)
    }

    enum ModelPreset: String, CaseIterable, Identifiable {
        case tinyEn
        case baseEn
        case smallEn
        case mediumEn
        case largeV3Turbo

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .tinyEn:
                return "tiny.en (fastest)"
            case .baseEn:
                return "base.en"
            case .smallEn:
                return "small.en (recommended)"
            case .mediumEn:
                return "medium.en"
            case .largeV3Turbo:
                return "large-v3-turbo (most accurate)"
            }
        }

        var fileName: String {
            switch self {
            case .tinyEn:
                return "ggml-tiny.en.bin"
            case .baseEn:
                return "ggml-base.en.bin"
            case .smallEn:
                return "ggml-small.en.bin"
            case .mediumEn:
                return "ggml-medium.en.bin"
            case .largeV3Turbo:
                return "ggml-large-v3-turbo.bin"
            }
        }
    }

    struct InputDeviceOption: Identifiable, Equatable {
        let id: String
        let displayName: String
        let deviceUniqueID: String?
        let localizedName: String?
        let isSystemDefault: Bool
    }

    struct Configuration {
        var modelPreset: ModelPreset
        var executablePath: String
        var modelDirectoryPath: String
        var language: String
        var keepDebugRecordings: Bool
        var microphoneSelectionID: String
    }

    nonisolated static let systemDefaultInputID = "systemDefault"

    nonisolated static var defaultModelDirectoryPath: String {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/vibe-mouse/whisper-models", isDirectory: true)
            .path
    }

    nonisolated static var debugRecordingsDirectoryPath: String {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/vibe-mouse/debug-recordings", isDirectory: true)
            .path
    }

    nonisolated static func availableInputOptions() -> [InputDeviceOption] {
        let devices = audioCaptureDevices()
        let defaultInput = currentSystemDefaultInputDevice()
        let defaultLabel = defaultInput.map { "System Default (\($0.localizedName))" } ?? "System Default"

        var options: [InputDeviceOption] = [
            InputDeviceOption(
                id: systemDefaultInputID,
                displayName: defaultLabel,
                deviceUniqueID: defaultInput?.uniqueID,
                localizedName: defaultInput?.localizedName,
                isSystemDefault: true
            )
        ]

        options.append(contentsOf: devices.map { device in
            InputDeviceOption(
                id: device.uniqueID,
                displayName: device.uniqueID == builtInMicrophoneUniqueID
                    ? "\(device.localizedName) (Recommended)"
                    : device.localizedName,
                deviceUniqueID: device.uniqueID,
                localizedName: device.localizedName,
                isSystemDefault: false
            )
        })

        return options
    }

    nonisolated static func preferredMicrophoneSelectionID() -> String {
        availableInputOptions().first(where: { $0.deviceUniqueID == builtInMicrophoneUniqueID })?.id
            ?? systemDefaultInputID
    }

    var eventLogger: ((String) -> Void)?

    var isRecording: Bool {
        activeRecording != nil
    }

    nonisolated private static let builtInMicrophoneUniqueID = "BuiltInMicrophoneDevice"

    private final class CaptureRecordingDelegate: NSObject, AVCaptureFileOutputRecordingDelegate {
        var onStart: (@Sendable (URL) -> Void)?
        var onFinish: (@Sendable (URL, Error?) -> Void)?

        func fileOutput(
            _ output: AVCaptureFileOutput,
            didStartRecordingTo outputFileURL: URL,
            from connections: [AVCaptureConnection]
        ) {
            onStart?(outputFileURL)
        }

        func fileOutput(
            _ output: AVCaptureFileOutput,
            didFinishRecordingTo outputFileURL: URL,
            from connections: [AVCaptureConnection],
            error: Error?
        ) {
            onFinish?(outputFileURL, error)
        }
    }

    private final class ActiveRecording {
        let id = UUID()
        let session: AVCaptureSession
        let fileOutput: AVCaptureAudioFileOutput
        let recordingDelegate: CaptureRecordingDelegate
        let runtimeErrorObserver: NSObjectProtocol
        let recordingURL: URL
        let executablePath: String
        let modelPath: String
        let language: String
        let keepDebugRecordings: Bool
        let requestedInputSelectionID: String
        let resolvedInputSelectionID: String
        let inputName: String
        let inputUniqueID: String
        var startCompletion: (@Sendable (Result<ToggleResult, WhisperError>) -> Void)?
        var stopCompletion: (@Sendable (Result<ToggleResult, WhisperError>) -> Void)?
        var didStartWriting = false

        init(
            session: AVCaptureSession,
            fileOutput: AVCaptureAudioFileOutput,
            recordingDelegate: CaptureRecordingDelegate,
            runtimeErrorObserver: NSObjectProtocol,
            recordingURL: URL,
            executablePath: String,
            modelPath: String,
            language: String,
            keepDebugRecordings: Bool,
            requestedInputSelectionID: String,
            resolvedInputSelectionID: String,
            inputName: String,
            inputUniqueID: String,
            startCompletion: (@escaping @Sendable (Result<ToggleResult, WhisperError>) -> Void)
        ) {
            self.session = session
            self.fileOutput = fileOutput
            self.recordingDelegate = recordingDelegate
            self.runtimeErrorObserver = runtimeErrorObserver
            self.recordingURL = recordingURL
            self.executablePath = executablePath
            self.modelPath = modelPath
            self.language = language
            self.keepDebugRecordings = keepDebugRecordings
            self.requestedInputSelectionID = requestedInputSelectionID
            self.resolvedInputSelectionID = resolvedInputSelectionID
            self.inputName = inputName
            self.inputUniqueID = inputUniqueID
            self.startCompletion = startCompletion
        }
    }

    private var activeRecording: ActiveRecording?

    func toggleRecording(
        configuration: Configuration,
        completion: @escaping @Sendable (Result<ToggleResult, WhisperError>) -> Void
    ) {
        if isRecording {
            stopRecordingAndTranscribe(completion: completion)
        } else {
            startRecording(configuration: configuration, completion: completion)
        }
    }

    func startRecording(
        configuration: Configuration,
        completion: @escaping @Sendable (Result<ToggleResult, WhisperError>) -> Void
    ) {
        guard activeRecording == nil else {
            completion(.failure(.failed("A whisper.cpp recording is already in progress.")))
            return
        }

        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            beginRecordingAfterPermissionCheck(configuration: configuration, completion: completion)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Task { @MainActor in
                    guard granted else {
                        completion(.failure(.failed("Microphone permission is required for whisper.cpp dictation.")))
                        return
                    }
                    self.beginRecordingAfterPermissionCheck(configuration: configuration, completion: completion)
                }
            }
        case .denied, .restricted:
            completion(.failure(.failed("Microphone access is denied. Enable it in macOS Privacy & Security > Microphone.")))
        @unknown default:
            completion(.failure(.failed("Unknown microphone permission state.")))
        }
    }

    func stopRecordingAndTranscribe(
        completion: @escaping @Sendable (Result<ToggleResult, WhisperError>) -> Void
    ) {
        guard let activeRecording else {
            completion(.failure(.failed("Dictation recording state was not available.")))
            return
        }

        guard activeRecording.stopCompletion == nil else {
            completion(.failure(.failed("whisper.cpp recording is already stopping.")))
            return
        }

        activeRecording.stopCompletion = completion
        logEvent("capture_file_output stop_requested path=\(activeRecording.recordingURL.path)")
        activeRecording.fileOutput.stopRecording()
    }

    private func beginRecordingAfterPermissionCheck(
        configuration: Configuration,
        completion: @escaping @Sendable (Result<ToggleResult, WhisperError>) -> Void
    ) {
        guard let executablePath = Self.resolveWhisperExecutablePath(configuredPath: configuration.executablePath) else {
            completion(.failure(.failed(
                "whisper-cli was not found. Install whisper.cpp (for example via Homebrew) or set a custom executable path in Settings."
            )))
            return
        }

        guard let modelPath = Self.resolveModelPath(
            preset: configuration.modelPreset,
            configuredModelDirectoryPath: configuration.modelDirectoryPath
        ) else {
            let configuredDirectory = Self.expandedPath(
                configuration.modelDirectoryPath.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            let fallbackDirectory = configuredDirectory.isEmpty ? Self.defaultModelDirectoryPath : configuredDirectory
            let expectedLocation = URL(fileURLWithPath: fallbackDirectory, isDirectory: true)
                .appendingPathComponent(configuration.modelPreset.fileName, isDirectory: false)
                .path
            completion(.failure(.failed(
                "Model file not found (\(configuration.modelPreset.fileName)). Expected at \(expectedLocation)."
            )))
            return
        }

        guard let resolvedInput = Self.resolveInputDevice(selectionID: configuration.microphoneSelectionID) else {
            completion(.failure(.failed("No usable microphone was found for whisper.cpp dictation.")))
            return
        }

        let recordingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vibe-mouse-\(UUID().uuidString)", isDirectory: false)
            .appendingPathExtension("wav")

        let captureSession = AVCaptureSession()
        let fileOutput = AVCaptureAudioFileOutput()
        fileOutput.audioSettings = Self.whisperRecordingSettings()

        let recordingDelegate = CaptureRecordingDelegate()

        do {
            let deviceInput = try AVCaptureDeviceInput(device: resolvedInput.device)

            captureSession.beginConfiguration()
            guard captureSession.canAddInput(deviceInput) else {
                captureSession.commitConfiguration()
                completion(.failure(.failed("Could not add the selected microphone to the capture session.")))
                return
            }
            captureSession.addInput(deviceInput)

            guard captureSession.canAddOutput(fileOutput) else {
                captureSession.commitConfiguration()
                completion(.failure(.failed("Could not add the audio file output to the capture session.")))
                return
            }
            captureSession.addOutput(fileOutput)
            captureSession.commitConfiguration()
        } catch {
            completion(.failure(.failed("Could not create audio capture input: \(error.localizedDescription)")))
            return
        }

        guard AVCaptureAudioFileOutput.availableOutputFileTypes().contains(.wav) else {
            completion(.failure(.failed("This Mac does not report WAV recording support for AVCaptureAudioFileOutput.")))
            return
        }

        let runtimeErrorObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification,
            object: captureSession,
            queue: .main
        ) { [weak self] notification in
            let errorDescription: String = {
                if let error = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError {
                    return error.localizedDescription
                }
                return "Unknown capture session error."
            }()
            Task { @MainActor [weak self] in
                self?.handleCaptureRuntimeError(errorDescription)
            }
        }

        let activeRecording = ActiveRecording(
            session: captureSession,
            fileOutput: fileOutput,
            recordingDelegate: recordingDelegate,
            runtimeErrorObserver: runtimeErrorObserver,
            recordingURL: recordingURL,
            executablePath: executablePath,
            modelPath: modelPath,
            language: configuration.language.isEmpty ? "en" : configuration.language,
            keepDebugRecordings: configuration.keepDebugRecordings,
            requestedInputSelectionID: configuration.microphoneSelectionID,
            resolvedInputSelectionID: resolvedInput.selectionID,
            inputName: resolvedInput.device.localizedName,
            inputUniqueID: resolvedInput.device.uniqueID,
            startCompletion: completion
        )

        recordingDelegate.onStart = { [weak self, recordingID = activeRecording.id] outputFileURL in
            Task { @MainActor [weak self] in
                self?.handleCaptureDidStart(recordingID: recordingID, outputFileURL: outputFileURL)
            }
        }
        recordingDelegate.onFinish = { [weak self, recordingID = activeRecording.id] outputFileURL, error in
            Task { @MainActor [weak self] in
                self?.handleCaptureDidFinish(recordingID: recordingID, outputFileURL: outputFileURL, error: error)
            }
        }

        self.activeRecording = activeRecording

        logEvent(
            "capture_input requested_selection=\(configuration.microphoneSelectionID) resolved_selection=\(resolvedInput.selectionID) name=\(resolvedInput.device.localizedName) uid=\(resolvedInput.device.uniqueID) fallback=\(resolvedInput.usedFallback ? 1 : 0)"
        )
        logEvent("capture_file_output configured type=wav sample_rate=16000 channels=1 format=lpcm")

        if let serverExecutablePath = Self.resolveWhisperServerExecutablePath(
            configuredCLIPath: executablePath
        ) {
            Task.detached(priority: .utility) {
                await WhisperServerManager.shared.prepareServer(
                    executablePath: serverExecutablePath,
                    modelPath: modelPath
                )
            }
        }

        captureSession.startRunning()
        logEvent("capture_session start_requested running=\(captureSession.isRunning ? 1 : 0)")

        fileOutput.startRecording(
            to: recordingURL,
            outputFileType: .wav,
            recordingDelegate: recordingDelegate
        )
        logEvent("capture_file_output start_requested path=\(recordingURL.path)")
    }

    private func handleCaptureDidStart(recordingID: UUID, outputFileURL: URL) {
        guard let activeRecording, activeRecording.id == recordingID else { return }
        activeRecording.didStartWriting = true
        let startCompletion = activeRecording.startCompletion
        activeRecording.startCompletion = nil
        logEvent(
            "capture_file_output started path=\(outputFileURL.path) input_name=\(activeRecording.inputName) input_uid=\(activeRecording.inputUniqueID)"
        )
        startCompletion?(.success(.started))
    }

    private func handleCaptureDidFinish(recordingID: UUID, outputFileURL: URL, error: Error?) {
        guard let activeRecording, activeRecording.id == recordingID else { return }

        self.activeRecording = nil
        NotificationCenter.default.removeObserver(activeRecording.runtimeErrorObserver)
        activeRecording.recordingDelegate.onStart = nil
        activeRecording.recordingDelegate.onFinish = nil

        if activeRecording.session.isRunning {
            activeRecording.session.stopRunning()
        }
        logEvent("capture_session stopped running=\(activeRecording.session.isRunning ? 1 : 0)")

        let normalizedError = Self.normalizedRecordingError(error)
        let stopCompletion = activeRecording.stopCompletion
        let startCompletion = activeRecording.startCompletion

        if let normalizedError {
            let message = normalizedError.localizedDescription
            logEvent("capture_file_output finished error=\(message)")
            try? FileManager.default.removeItem(at: outputFileURL)

            if let stopCompletion {
                stopCompletion(.failure(.failed("Could not finish microphone recording: \(message)")))
            } else {
                startCompletion?(.failure(.failed("Could not start microphone recording: \(message)")))
            }
            return
        }

        logEvent("capture_file_output finished error=none path=\(outputFileURL.path)")

        if let stopCompletion {
            let executablePath = activeRecording.executablePath
            let modelPath = activeRecording.modelPath
            let recordingURL = activeRecording.recordingURL
            let language = activeRecording.language
            let keepDebugRecordings = activeRecording.keepDebugRecordings

            Task.detached(priority: .userInitiated) {
                if keepDebugRecordings {
                    try? Self.saveDebugRecording(from: recordingURL)
                }
                let result = await Self.runWhisperTranscription(
                    executablePath: executablePath,
                    modelPath: modelPath,
                    recordingURL: recordingURL,
                    language: language
                )
                try? FileManager.default.removeItem(at: recordingURL)

                await MainActor.run {
                    switch result {
                    case .success(let transcript):
                        stopCompletion(.success(.transcribed(transcript)))
                    case .failure(let error):
                        stopCompletion(.failure(error))
                    }
                }
            }
            return
        }

        startCompletion?(.failure(.failed("Microphone recording ended before it fully started.")))
        try? FileManager.default.removeItem(at: outputFileURL)
    }

    private func handleCaptureRuntimeError(_ errorDescription: String) {
        guard let activeRecording else { return }

        logEvent("capture_session runtime_error=\(errorDescription)")

        guard activeRecording.startCompletion != nil, !activeRecording.didStartWriting else { return }

        let startCompletion = activeRecording.startCompletion
        cleanupActiveRecording(activeRecording, removeRecordingFile: true)
        startCompletion?(.failure(.failed("Capture session runtime error: \(errorDescription)")))
    }

    private func cleanupActiveRecording(_ activeRecording: ActiveRecording, removeRecordingFile: Bool) {
        if self.activeRecording?.id == activeRecording.id {
            self.activeRecording = nil
        }

        NotificationCenter.default.removeObserver(activeRecording.runtimeErrorObserver)
        activeRecording.recordingDelegate.onStart = nil
        activeRecording.recordingDelegate.onFinish = nil

        if activeRecording.fileOutput.isRecording {
            activeRecording.fileOutput.stopRecording()
        }
        if activeRecording.session.isRunning {
            activeRecording.session.stopRunning()
        }

        if removeRecordingFile {
            try? FileManager.default.removeItem(at: activeRecording.recordingURL)
        }
    }

    private func logEvent(_ message: String) {
        eventLogger?(message)
    }

    nonisolated private static func runWhisperTranscription(
        executablePath: String,
        modelPath: String,
        recordingURL: URL,
        language: String
    ) async -> Result<String, WhisperError> {
        if let serverExecutablePath = resolveWhisperServerExecutablePath(configuredCLIPath: executablePath) {
            let serverResult = await WhisperServerManager.shared.transcribe(
                serverExecutablePath: serverExecutablePath,
                modelPath: modelPath,
                recordingURL: recordingURL,
                language: language
            )

            switch serverResult {
            case .success(let transcript):
                return .success(transcript)
            case .failure:
                break
            }
        }

        return runWhisperCLITranscription(
            executablePath: executablePath,
            modelPath: modelPath,
            recordingURL: recordingURL,
            language: language
        )
    }

    nonisolated private static func runWhisperCLITranscription(
        executablePath: String,
        modelPath: String,
        recordingURL: URL,
        language: String
    ) -> Result<String, WhisperError> {
        let outputPrefixURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vibe-mouse-whisper-\(UUID().uuidString)", isDirectory: false)

        defer {
            cleanupTranscriptionOutputs(prefixURL: outputPrefixURL)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = [
            "-m", modelPath,
            "-f", recordingURL.path,
            "-l", language,
            "-nt",
            "-of", outputPrefixURL.path,
            "-otxt",
        ]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return .failure(.failed("Could not start whisper-cli: \(error.localizedDescription)"))
        }

        guard process.terminationStatus == 0 else {
            let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let cleanedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if cleanedOutput.isEmpty {
                return .failure(.failed("whisper-cli failed with exit code \(process.terminationStatus)."))
            }
            return .failure(.failed("whisper-cli failed: \(cleanedOutput)"))
        }

        let transcriptURL = outputPrefixURL.appendingPathExtension("txt")
        guard let transcript = try? String(contentsOf: transcriptURL, encoding: .utf8) else {
            return .failure(.failed("whisper-cli did not produce a transcript file."))
        }

        return .success(transcript.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    nonisolated private static func cleanupTranscriptionOutputs(prefixURL: URL) {
        let paths = [
            prefixURL.appendingPathExtension("txt").path,
            prefixURL.appendingPathExtension("json").path,
            prefixURL.appendingPathExtension("srt").path,
            prefixURL.appendingPathExtension("vtt").path,
            prefixURL.appendingPathExtension("csv").path,
            prefixURL.appendingPathExtension("lrc").path,
            prefixURL.path,
        ]

        let fileManager = FileManager.default
        for path in paths where fileManager.fileExists(atPath: path) {
            try? fileManager.removeItem(atPath: path)
        }
    }

    nonisolated private static func saveDebugRecording(from recordingURL: URL) throws {
        let directoryURL = URL(fileURLWithPath: debugRecordingsDirectoryPath, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let destinationURL = directoryURL
            .appendingPathComponent("dictation-\(formatter.string(from: Date())).wav", isDirectory: false)

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.copyItem(at: recordingURL, to: destinationURL)
    }

    nonisolated private static func resolveWhisperExecutablePath(configuredPath: String) -> String? {
        let configured = expandedPath(configuredPath.trimmingCharacters(in: .whitespacesAndNewlines))
        let candidates = [
            configured,
            "/opt/homebrew/bin/whisper-cli",
            "/usr/local/bin/whisper-cli",
            "/opt/homebrew/bin/whisper-cpp",
            "/usr/local/bin/whisper-cpp",
        ]

        let fileManager = FileManager.default
        for candidate in candidates where !candidate.isEmpty {
            if fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }

        return nil
    }

    nonisolated private static func resolveWhisperServerExecutablePath(configuredCLIPath: String) -> String? {
        let configuredCLIURL = URL(fileURLWithPath: configuredCLIPath)
        let siblingCandidate = configuredCLIURL.deletingLastPathComponent()
            .appendingPathComponent("whisper-server", isDirectory: false)
            .path
        let candidates = [
            siblingCandidate,
            NSString(string: "~/.local/bin/whisper-server").expandingTildeInPath,
            "/opt/homebrew/bin/whisper-server",
            "/usr/local/bin/whisper-server",
        ]

        let fileManager = FileManager.default
        for candidate in candidates where !candidate.isEmpty {
            if fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }

        return nil
    }

    nonisolated private static func resolveModelPath(
        preset: ModelPreset,
        configuredModelDirectoryPath: String
    ) -> String? {
        let configuredDirectory = expandedPath(configuredModelDirectoryPath.trimmingCharacters(in: .whitespacesAndNewlines))
        let candidateDirectories = [
            configuredDirectory,
            defaultModelDirectoryPath,
            "/opt/homebrew/share/whisper.cpp",
            "/usr/local/share/whisper.cpp",
        ]

        let fileManager = FileManager.default
        for directory in candidateDirectories where !directory.isEmpty {
            let candidate = URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent(preset.fileName, isDirectory: false)
                .path
            if fileManager.fileExists(atPath: candidate) {
                return candidate
            }
        }

        return nil
    }

    private struct ResolvedInputDevice {
        let selectionID: String
        let device: AVCaptureDevice
        let usedFallback: Bool
    }

    nonisolated private static func resolveInputDevice(selectionID: String) -> ResolvedInputDevice? {
        let devices = audioCaptureDevices()
        let defaultDevice = currentSystemDefaultInputDevice() ?? devices.first

        if selectionID == systemDefaultInputID {
            guard let defaultDevice else { return nil }
            return ResolvedInputDevice(
                selectionID: systemDefaultInputID,
                device: defaultDevice,
                usedFallback: false
            )
        }

        if let matchedDevice = devices.first(where: { $0.uniqueID == selectionID }) {
            return ResolvedInputDevice(
                selectionID: selectionID,
                device: matchedDevice,
                usedFallback: false
            )
        }

        let fallbackSelectionID = preferredMicrophoneSelectionID()
        if fallbackSelectionID == systemDefaultInputID {
            guard let defaultDevice else { return nil }
            return ResolvedInputDevice(
                selectionID: systemDefaultInputID,
                device: defaultDevice,
                usedFallback: true
            )
        }

        if let builtInDevice = devices.first(where: { $0.uniqueID == fallbackSelectionID }) {
            return ResolvedInputDevice(
                selectionID: fallbackSelectionID,
                device: builtInDevice,
                usedFallback: true
            )
        }

        guard let defaultDevice else { return nil }
        return ResolvedInputDevice(
            selectionID: systemDefaultInputID,
            device: defaultDevice,
            usedFallback: true
        )
    }

    nonisolated private static func audioCaptureDevices() -> [AVCaptureDevice] {
        let deviceTypes: [AVCaptureDevice.DeviceType]
        if #available(macOS 14.0, *) {
            deviceTypes = [.microphone, .external]
        } else {
            deviceTypes = [.builtInMicrophone, .externalUnknown]
        }

        return AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .audio,
            position: .unspecified
        ).devices.sorted { lhs, rhs in
            let lhsIsBuiltIn = lhs.uniqueID == builtInMicrophoneUniqueID
            let rhsIsBuiltIn = rhs.uniqueID == builtInMicrophoneUniqueID
            if lhsIsBuiltIn != rhsIsBuiltIn {
                return lhsIsBuiltIn
            }
            return lhs.localizedName.localizedCaseInsensitiveCompare(rhs.localizedName) == .orderedAscending
        }
    }

    nonisolated private static func whisperRecordingSettings() -> [String: Any] {
        [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
    }

    nonisolated private static func currentSystemDefaultInputDevice() -> AVCaptureDevice? {
        AVCaptureDevice.default(for: .audio) ?? audioCaptureDevices().first
    }

    nonisolated private static func normalizedRecordingError(_ error: Error?) -> Error? {
        guard let error = error as NSError? else { return nil }
        if let finished = error.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool, finished {
            return nil
        }
        return error
    }

    nonisolated private static func expandedPath(_ path: String) -> String {
        NSString(string: path).expandingTildeInPath
    }
}
