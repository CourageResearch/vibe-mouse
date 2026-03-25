import Foundation

actor WhisperServerManager {
    enum ServerError: Error {
        case failed(String)
    }

    static let shared = WhisperServerManager()

    private let host = "127.0.0.1"
    private let port = 8177
    private let startupPollIntervalNanoseconds: UInt64 = 200_000_000
    private let startupTimeoutNanoseconds: UInt64 = 20_000_000_000

    private var process: Process?
    private var executablePath: String?
    private var modelPath: String?

    func prepareServer(executablePath: String, modelPath: String) async {
        _ = try? await ensureServerRunning(executablePath: executablePath, modelPath: modelPath)
    }

    func transcribe(
        serverExecutablePath: String,
        modelPath: String,
        recordingURL: URL,
        language: String
    ) async -> Result<String, ServerError> {
        do {
            try await ensureServerRunning(executablePath: serverExecutablePath, modelPath: modelPath)
            return try await sendInferenceRequest(recordingURL: recordingURL, language: language)
        } catch {
            return .failure(.failed(error.localizedDescription))
        }
    }

    private func ensureServerRunning(executablePath: String, modelPath: String) async throws {
        if isCurrentServerHealthy(executablePath: executablePath, modelPath: modelPath) {
            if await isHealthy() {
                return
            }
            stopServer()
        } else {
            stopServer()
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = [
            "--host", host,
            "--port", "\(port)",
            "-m", modelPath,
            "-l", "en",
            "-nt",
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try process.run()
        self.process = process
        self.executablePath = executablePath
        self.modelPath = modelPath

        let start = DispatchTime.now().uptimeNanoseconds
        while DispatchTime.now().uptimeNanoseconds - start < startupTimeoutNanoseconds {
            if process.isRunning, await isHealthy() {
                return
            }
            try await Task.sleep(nanoseconds: startupPollIntervalNanoseconds)
        }

        stopServer()
        throw NSError(
            domain: "WhisperServerManager",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for whisper-server to become ready."]
        )
    }

    private func isCurrentServerHealthy(executablePath: String, modelPath: String) -> Bool {
        guard let process else { return false }
        guard process.isRunning else { return false }
        return self.executablePath == executablePath && self.modelPath == modelPath
    }

    private func isHealthy() async -> Bool {
        guard let url = URL(string: "http://\(host):\(port)/health") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 0.5

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else { return false }
            return httpResponse.statusCode == 200
        } catch {
            return false
        }
    }

    private func sendInferenceRequest(recordingURL: URL, language: String) async throws -> Result<String, ServerError> {
        guard let url = URL(string: "http://\(host):\(port)/inference") else {
            return .failure(.failed("Could not construct whisper-server URL."))
        }

        let audioData = try Data(contentsOf: recordingURL)
        let boundary = "Boundary-\(UUID().uuidString)"

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = buildMultipartBody(
            boundary: boundary,
            audioData: audioData,
            language: language
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            return .failure(.failed("whisper-server returned an invalid response."))
        }

        let body = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard (200...299).contains(httpResponse.statusCode) else {
            return .failure(.failed(
                body.isEmpty ? "whisper-server returned HTTP \(httpResponse.statusCode)." : body
            ))
        }

        return .success(body)
    }

    private func buildMultipartBody(
        boundary: String,
        audioData: Data,
        language: String
    ) -> Data {
        var body = Data()
        let lineBreak = "\r\n"

        func append(_ string: String) {
            body.append(Data(string.utf8))
        }

        append("--\(boundary)\(lineBreak)")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"recording.wav\"\(lineBreak)")
        append("Content-Type: audio/wav\(lineBreak)\(lineBreak)")
        body.append(audioData)
        append(lineBreak)

        append("--\(boundary)\(lineBreak)")
        append("Content-Disposition: form-data; name=\"language\"\(lineBreak)\(lineBreak)")
        append("\(language)\(lineBreak)")

        append("--\(boundary)\(lineBreak)")
        append("Content-Disposition: form-data; name=\"response_format\"\(lineBreak)\(lineBreak)")
        append("text\(lineBreak)")

        append("--\(boundary)\(lineBreak)")
        append("Content-Disposition: form-data; name=\"temperature\"\(lineBreak)\(lineBreak)")
        append("0.0\(lineBreak)")

        append("--\(boundary)--\(lineBreak)")
        return body
    }

    private func stopServer() {
        process?.terminate()
        process = nil
        executablePath = nil
        modelPath = nil
    }
}
