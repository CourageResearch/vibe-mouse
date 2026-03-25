import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

@MainActor
final class SoundCuePlayer {
    enum Cue: String {
        case start
        case stop
    }

    enum PlaybackMode: String {
        case preparedPlayer = "prepared_player"
        case systemSound = "system_sound"
        case userAlert = "user_alert"
    }

    struct PlaybackStart {
        let mode: PlaybackMode
        let started: Bool
    }

    private struct PreparedCue {
        let player: AVAudioPlayer
        let delegate: CuePlayerDelegate
        let filePath: String
    }

    private struct FallbackCue {
        let soundID: SystemSoundID
        let filePath: String
    }

    private struct OutputDeviceInfo {
        let uid: String?
        let name: String?
    }

    private final class CuePlayerDelegate: NSObject, AVAudioPlayerDelegate {
        var onFinish: ((Bool) -> Void)?

        func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
            onFinish?(flag)
            onFinish = nil
        }

        func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
            onFinish?(false)
            onFinish = nil
        }
    }

    private var preparedCues: [Cue: PreparedCue] = [:]
    private var fallbackCues: [Cue: FallbackCue] = [:]

    init(startPath: String, stopPath: String) {
        if let preparedStart = Self.makePreparedCue(path: startPath) {
            preparedCues[.start] = preparedStart
        }
        if let preparedStop = Self.makePreparedCue(path: stopPath) {
            preparedCues[.stop] = preparedStop
        }

        if let fallbackStart = Self.makeFallbackCue(path: startPath) {
            fallbackCues[.start] = fallbackStart
        }
        if let fallbackStop = Self.makeFallbackCue(path: stopPath) {
            fallbackCues[.stop] = fallbackStop
        }
    }

    deinit {
        for fallbackCue in fallbackCues.values {
            AudioServicesDisposeSystemSoundID(fallbackCue.soundID)
        }
    }

    @discardableResult
    func play(
        _ cue: Cue,
        completion: (@escaping @Sendable (PlaybackMode, Bool) -> Void)
    ) -> PlaybackStart {
        if let preparedCue = preparedCues[cue] {
            let outputDevice = Self.defaultOutputDeviceInfo()
            preparedCue.player.stop()
            preparedCue.player.currentTime = 0
            preparedCue.player.currentDevice = outputDevice?.uid
            preparedCue.delegate.onFinish = { success in
                DispatchQueue.main.async {
                    completion(.preparedPlayer, success)
                }
            }

            let prepared = preparedCue.player.prepareToPlay()
            let started = preparedCue.player.play()
            if prepared && started {
                return PlaybackStart(mode: .preparedPlayer, started: true)
            }

            preparedCue.delegate.onFinish = nil
        }

        if let fallbackCue = fallbackCues[cue] {
            AudioServicesPlaySystemSoundWithCompletion(fallbackCue.soundID) {
                completion(.systemSound, true)
            }
            return PlaybackStart(mode: .systemSound, started: true)
        }

        AudioServicesPlayAlertSoundWithCompletion(kSystemSoundID_UserPreferredAlert) {
            completion(.userAlert, true)
        }
        return PlaybackStart(mode: .userAlert, started: true)
    }

    func descriptor(for cue: Cue) -> String {
        preparedCues[cue]?.filePath ?? fallbackCues[cue]?.filePath ?? "user_preferred_alert"
    }

    func currentOutputDescription() -> String {
        let outputDevice = Self.defaultOutputDeviceInfo()
        let name = outputDevice?.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let uid = outputDevice?.uid?.trimmingCharacters(in: .whitespacesAndNewlines)

        switch (name, uid) {
        case let (.some(name), .some(uid)) where !name.isEmpty && !uid.isEmpty:
            return "\(name) [\(uid)]"
        case let (.some(name), _ ) where !name.isEmpty:
            return name
        case let (_, .some(uid)) where !uid.isEmpty:
            return uid
        default:
            return "unknown_output"
        }
    }

    private static func makePreparedCue(path: String) -> PreparedCue? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        guard let player = try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: path)) else { return nil }

        let delegate = CuePlayerDelegate()
        player.delegate = delegate
        player.volume = 1
        player.numberOfLoops = 0
        _ = player.prepareToPlay()

        return PreparedCue(player: player, delegate: delegate, filePath: path)
    }

    private static func makeFallbackCue(path: String) -> FallbackCue? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }

        var soundID: SystemSoundID = 0
        let status = AudioServicesCreateSystemSoundID(URL(fileURLWithPath: path) as CFURL, &soundID)
        guard status == kAudioServicesNoError else { return nil }

        return FallbackCue(soundID: soundID, filePath: path)
    }

    private static func defaultOutputDeviceInfo() -> OutputDeviceInfo? {
        guard let deviceID = defaultOutputDeviceID() else { return nil }
        return OutputDeviceInfo(
            uid: stringProperty(
                selector: kAudioDevicePropertyDeviceUID,
                objectID: deviceID
            ),
            name: stringProperty(
                selector: kAudioObjectPropertyName,
                objectID: deviceID
            )
        )
    }

    private static func defaultOutputDeviceID() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )

        guard status == noErr, deviceID != 0 else { return nil }
        return deviceID
    }

    private static func stringProperty(
        selector: AudioObjectPropertySelector,
        objectID: AudioObjectID
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)

        let status = AudioObjectGetPropertyData(
            objectID,
            &address,
            0,
            nil,
            &size,
            &value
        )

        guard status == noErr else { return nil }
        return value as String?
    }
}
