import AVFoundation
import Foundation
import Observation

@MainActor
@Observable
final class VoiceInputController {
    enum Phase: Equatable { case idle, requestingPermission, recording, transcribing }

    static let maximumDuration: TimeInterval = 30
    private(set) var phase: Phase = .idle
    private(set) var errorMessage: String?
    private(set) var elapsed: TimeInterval = 0
    private(set) var level: Double = 0
    var isActive: Bool { phase != .idle }

    @ObservationIgnored private let recording: any VoiceRecording
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var meterTask: Task<Void, Never>?
    @ObservationIgnored private var transcriptionTask: Task<Void, Never>?
    @ObservationIgnored private var transcribe: (@Sendable (Data) async throws -> String)?
    @ObservationIgnored private var onTranscription: (@MainActor (String) -> Void)?

    init(recording: (any VoiceRecording)? = nil) {
        self.recording = recording ?? MicrophoneRecording()
    }

    deinit {
        meterTask?.cancel()
        transcriptionTask?.cancel()
        let recording = recording
        Task { @MainActor in recording.discard() }
    }

    func start(
        transcribe: @escaping @Sendable (Data) async throws -> String,
        onTranscription: @escaping @MainActor (String) -> Void
    ) async {
        guard !Task.isCancelled, !isActive else { return }
        cancel()
        let attempt = generation
        phase = .requestingPermission
        let granted = await recording.requestPermission()
        guard generation == attempt else { return }
        guard !Task.isCancelled else { cancel(); return }
        guard granted else {
            fail("Microphone access is off. You can type instead, or ask staff for help.")
            return
        }

        self.transcribe = transcribe
        self.onTranscription = onTranscription
        phase = .recording
        do {
            try recording.start(maximumDuration: Self.maximumDuration) { [weak self] event in
                guard let self, self.generation == attempt, self.phase == .recording else { return }
                switch event {
                case .finished(successfully: true): self.finish()
                case .finished(successfully: false), .encodingFailed:
                    self.fail("The recording couldn’t be saved. Please try again or type instead.")
                case .interrupted:
                    self.fail("Recording was interrupted. Tap the microphone to try again, or type instead.")
                case .routeChanged:
                    self.fail("The microphone connection changed. Please try again or type instead.")
                case .mediaServicesReset:
                    self.fail("The microphone became unavailable. Please try again or type instead.")
                }
            }
            guard generation == attempt, phase == .recording else { return }
            meterTask = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(80)) }
                    catch { return }
                    guard let self, self.generation == attempt, self.phase == .recording else { return }
                    self.recording.updateMeters()
                    self.elapsed = min(Self.maximumDuration, max(0, self.recording.currentTime))
                    self.level = min(1, max(0, self.recording.level))
                    if self.elapsed >= Self.maximumDuration {
                        self.finish()
                        return
                    }
                }
            }
        } catch {
            fail("The microphone couldn’t start. Please try again or type instead.")
        }
    }

    func finish() {
        guard phase == .recording, let transcribe, let onTranscription else { return }
        let attempt = generation
        meterTask?.cancel()
        meterTask = nil
        level = 0
        phase = .transcribing
        do {
            // The recording is finalized and removed from disk before any network request.
            let audio = try recording.readAndDiscard()
            guard !audio.isEmpty else { throw VoiceRecordingError.emptyRecording }
            self.transcribe = nil
            self.onTranscription = nil
            transcriptionTask = Task { [weak self] in
                guard !Task.isCancelled else { return }
                do {
                    let text = try await transcribe(audio).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !Task.isCancelled, let self, self.generation == attempt else { return }
                    guard !text.isEmpty else {
                        self.fail("No speech was detected. Please try again or type instead.")
                        return
                    }
                    self.transcriptionTask = nil
                    self.phase = .idle
                    onTranscription(text)
                } catch {
                    guard !Task.isCancelled, let self, self.generation == attempt else { return }
                    self.fail(error.localizedDescription)
                }
            }
        } catch {
            fail("The recording couldn’t be read. Please try again or type instead.")
        }
    }

    func cancel() {
        generation = UUID()
        meterTask?.cancel()
        meterTask = nil
        transcriptionTask?.cancel()
        transcriptionTask = nil
        recording.discard()
        transcribe = nil
        onTranscription = nil
        phase = .idle
        errorMessage = nil
        elapsed = 0
        level = 0
    }

    private func fail(_ message: String) {
        cancel()
        errorMessage = message
    }
}

enum VoiceRecordingEvent: Sendable {
    case finished(successfully: Bool), interrupted, routeChanged, mediaServicesReset, encodingFailed
}

/// The device boundary is injectable so cancellation and interruptions can be verified without a microphone.
@MainActor
protocol VoiceRecording: AnyObject {
    var currentTime: TimeInterval { get }
    var level: Double { get }
    func requestPermission() async -> Bool
    func start(maximumDuration: TimeInterval, onEvent: @escaping @MainActor (VoiceRecordingEvent) -> Void) throws
    func updateMeters()
    func readAndDiscard() throws -> Data
    func discard()
}

private enum VoiceRecordingError: Error { case unavailable, emptyRecording }

@MainActor
private final class MicrophoneRecording: NSObject, VoiceRecording, AVAudioRecorderDelegate {
    private var recorder: AVAudioRecorder?
    private var fileURL: URL?
    private var observers: [NSObjectProtocol] = []
    private var onEvent: (@MainActor (VoiceRecordingEvent) -> Void)?
    private var sessionActive = false
    private var runID: UUID?

    var currentTime: TimeInterval { recorder?.currentTime ?? 0 }
    var level: Double {
        guard let recorder else { return 0 }
        // Ignore the background noise floor, then map the current measured power to 0...1.
        return min(1, max(0, (Double(recorder.averagePower(forChannel: 0)) + 55) / 55))
    }

    func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    func start(maximumDuration: TimeInterval, onEvent: @escaping @MainActor (VoiceRecordingEvent) -> Void) throws {
        discard()
        let audioSession = AVAudioSession.sharedInstance()
        let runID = UUID()
        self.runID = runID
        self.onEvent = onEvent
        do {
            try audioSession.setCategory(.record, mode: .measurement)
            try audioSession.setActive(true)
            sessionActive = true
            guard audioSession.isInputAvailable else { throw VoiceRecordingError.unavailable }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("FoundVoice-\(UUID().uuidString).wav")
            fileURL = url
            let recorder = try AVAudioRecorder(url: url, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsFloatKey: false
            ])
            self.recorder = recorder
            recorder.delegate = self
            recorder.isMeteringEnabled = true
            guard recorder.prepareToRecord(), recorder.record(forDuration: maximumDuration) else {
                throw VoiceRecordingError.unavailable
            }
            observeSession(audioSession, runID: runID)
        } catch {
            discard()
            throw error
        }
    }

    func updateMeters() { recorder?.updateMeters() }

    func readAndDiscard() throws -> Data {
        recorder?.delegate = nil
        recorder?.stop()
        defer { discard() }
        guard let fileURL else { throw VoiceRecordingError.emptyRecording }
        return try Data(contentsOf: fileURL)
    }

    func discard() {
        runID = nil
        onEvent = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        recorder?.delegate = nil
        recorder?.stop()
        recorder = nil
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
        fileURL = nil
        if sessionActive {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            sessionActive = false
        }
    }

    private func observeSession(_ session: AVAudioSession, runID: UUID) {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] note in
            guard let rawType = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: rawType) == .began else { return }
            Task { @MainActor [weak self] in
                guard let self, self.runID == runID else { return }
                self.onEvent?(.interrupted)
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: .main) { [weak self] note in
            guard let rawReason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: rawReason),
                  reason == .oldDeviceUnavailable || reason == .newDeviceAvailable else { return }
            Task { @MainActor [weak self] in
                guard let self, self.runID == runID else { return }
                self.onEvent?(.routeChanged)
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.runID == runID else { return }
                self.onEvent?(.mediaServicesReset)
            }
        })
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        let url = recorder.url
        Task { @MainActor [weak self] in
            guard let self, self.fileURL == url else { return }
            self.onEvent?(.finished(successfully: flag))
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        let url = recorder.url
        Task { @MainActor [weak self] in
            guard let self, self.fileURL == url else { return }
            self.onEvent?(.encodingFailed)
        }
    }
}
