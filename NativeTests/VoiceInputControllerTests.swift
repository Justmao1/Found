import Foundation
import XCTest
@testable import Lost_Found

@MainActor
final class VoiceInputControllerTests: XCTestCase {
    func testPermissionReplyAfterCancellationCannotStartMicrophone() async {
        let microphone = StubVoiceRecording()
        microphone.deferPermission = true
        let controller = VoiceInputController(recording: microphone)
        let start = Task { await controller.start(transcribe: { _ in "Item" }, onTranscription: { _ in XCTFail("Cancelled visitor received text") }) }
        await waitUntil { microphone.permissionReply != nil }
        XCTAssertEqual(controller.phase, .requestingPermission)

        controller.cancel()
        microphone.permissionReply?(true)
        await start.value

        XCTAssertEqual(microphone.startCount, 0)
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertNil(controller.errorMessage)
    }

    func testDeniedPermissionKeepsTypingAvailableWithoutStartingCapture() async {
        let microphone = StubVoiceRecording()
        microphone.permissionGranted = false
        let controller = VoiceInputController(recording: microphone)

        await controller.start(transcribe: { _ in "Item" }, onTranscription: { _ in XCTFail("No recording exists") })

        XCTAssertEqual(controller.phase, .idle)
        XCTAssertFalse(controller.isActive)
        XCTAssertNotNil(controller.errorMessage)
        XCTAssertEqual(microphone.startCount, 0)
    }

    func testFinishDiscardsAudioBeforeTranscribingAndAcceptsTextOnlyOnce() async {
        let microphone = StubVoiceRecording()
        let controller = VoiceInputController(recording: microphone)
        let request = ControlledTranscription()
        var received: [String] = []
        await controller.start(transcribe: { audio in try await request.send(audio) }, onTranscription: { received.append($0) })
        XCTAssertEqual(controller.phase, .recording)

        controller.finish()
        controller.finish()
        XCTAssertEqual(microphone.readCount, 1)
        XCTAssertFalse(microphone.hasRecording)
        XCTAssertEqual(controller.phase, .transcribing)
        await waitUntil { await request.isPending }
        let audio = await request.audio
        XCTAssertEqual(audio, Data([1, 2, 3]))
        await request.complete(.success("  Blue water bottle\n"))
        await waitUntil { controller.phase == .idle }

        XCTAssertEqual(received, ["Blue water bottle"])
        XCTAssertNil(controller.errorMessage)
    }

    func testLateTranscriptionCannotReplaceNewVisitorRecordingOrText() async {
        let microphone = StubVoiceRecording()
        let controller = VoiceInputController(recording: microphone)
        let oldRequest = ControlledTranscription()
        var received: [String] = []
        await controller.start(transcribe: { audio in try await oldRequest.send(audio) }, onTranscription: { received.append($0) })
        controller.finish()
        await waitUntil { await oldRequest.isPending }

        controller.cancel()
        await controller.start(transcribe: { _ in "Current visitor" }, onTranscription: { received.append($0) })
        await oldRequest.complete(.success("Previous visitor"))
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(controller.phase, .recording)
        XCTAssertTrue(received.isEmpty)
        controller.finish()
        await waitUntil { controller.phase == .idle }
        XCTAssertEqual(received, ["Current visitor"])
    }

    func testCancellationBeforeQueuedTranscriptionSkipsNetworkRequest() async {
        let microphone = StubVoiceRecording()
        let controller = VoiceInputController(recording: microphone)
        await controller.start(transcribe: { _ in XCTFail("Cancelled audio must not be sent"); return "Item" }, onTranscription: { _ in XCTFail("Cancelled visitor received text") })

        controller.finish()
        controller.cancel()
        await Task.yield()
        await Task.yield()

        XCTAssertFalse(microphone.hasRecording)
        XCTAssertEqual(controller.phase, .idle)
    }

    func testThirtySecondLimitFinishesFromRecorderTime() async {
        let microphone = StubVoiceRecording()
        let controller = VoiceInputController(recording: microphone)
        var received: String?
        await controller.start(transcribe: { _ in "Red keys" }, onTranscription: { received = $0 })
        XCTAssertEqual(microphone.maximumDuration, 30)
        microphone.currentTime = 30

        await waitUntil { received != nil }

        XCTAssertEqual(received, "Red keys")
        XCTAssertEqual(controller.elapsed, 30)
        XCTAssertEqual(microphone.readCount, 1)
        XCTAssertFalse(microphone.hasRecording)
        XCTAssertEqual(controller.phase, .idle)
    }

    func testRecorderCompletionAndManualFinishDoNotUploadTwice() async {
        let microphone = StubVoiceRecording()
        let controller = VoiceInputController(recording: microphone)
        let request = ControlledTranscription()
        await controller.start(transcribe: { audio in try await request.send(audio) }, onTranscription: { _ in })
        let staleEvent = microphone.onEvent
        staleEvent?(.finished(successfully: true))
        controller.finish()
        staleEvent?(.finished(successfully: true))
        await waitUntil { await request.isPending }
        await request.complete(.success("Wallet"))
        await waitUntil { controller.phase == .idle }

        XCTAssertEqual(microphone.readCount, 1)
        let count = await request.requestCount
        XCTAssertEqual(count, 1)
    }

    func testInterruptionAndRouteFailuresDiscardWithoutSendingAudio() async {
        for event: VoiceRecordingEvent in [.interrupted, .routeChanged, .mediaServicesReset, .encodingFailed, .finished(successfully: false)] {
            let microphone = StubVoiceRecording()
            let controller = VoiceInputController(recording: microphone)
            await controller.start(transcribe: { _ in XCTFail("Interrupted audio must not leave device"); return "Item" }, onTranscription: { _ in XCTFail("Interrupted capture produced text") })

            microphone.onEvent?(event)

            XCTAssertEqual(controller.phase, .idle)
            XCTAssertFalse(microphone.hasRecording)
            XCTAssertEqual(microphone.readCount, 0)
            XCTAssertNotNil(controller.errorMessage)
        }
    }

    func testCancelClearsMeterAndDiscardsActiveRecording() async {
        let microphone = StubVoiceRecording()
        let controller = VoiceInputController(recording: microphone)
        await controller.start(transcribe: { _ in XCTFail("Cancelled capture must not upload"); return "Item" }, onTranscription: { _ in })
        microphone.currentTime = 3.2
        microphone.level = 0.6
        await waitUntil { controller.elapsed > 0 }
        XCTAssertEqual(controller.level, 0.6)

        controller.cancel()

        XCTAssertEqual(controller.elapsed, 0)
        XCTAssertEqual(controller.level, 0)
        XCTAssertFalse(controller.isActive)
        XCTAssertFalse(microphone.hasRecording)
    }

    func testEmptyAndFailedTranscriptionReturnToIdleWithRetryMessage() async {
        for shouldFail in [false, true] {
            let microphone = StubVoiceRecording()
            let controller = VoiceInputController(recording: microphone)
            await controller.start(transcribe: { _ in
                if shouldFail { throw URLError(.notConnectedToInternet) }
                return " \n "
            }, onTranscription: { _ in XCTFail("Invalid transcription must not edit the query") })
            controller.finish()
            await waitUntil { controller.phase == .idle }

            XCTAssertFalse(microphone.hasRecording)
            XCTAssertNotNil(controller.errorMessage)
        }
    }

    func testRecordingStartAndReadFailuresCleanUp() async {
        for failStart in [false, true] {
            let microphone = StubVoiceRecording()
            microphone.failStart = failStart
            microphone.failRead = !failStart
            let controller = VoiceInputController(recording: microphone)
            await controller.start(transcribe: { _ in XCTFail("Failed capture must not upload"); return "Item" }, onTranscription: { _ in })
            controller.finish()

            XCTAssertEqual(controller.phase, .idle)
            XCTAssertFalse(microphone.hasRecording)
            XCTAssertNotNil(controller.errorMessage)
        }
    }

    func testReleasingControllerDiscardsAnUnfinishedRecording() async {
        let microphone = StubVoiceRecording()
        var controller: VoiceInputController? = VoiceInputController(recording: microphone)
        await controller?.start(transcribe: { _ in "Item" }, onTranscription: { _ in })
        XCTAssertTrue(microphone.hasRecording)

        controller = nil
        await waitUntil { !microphone.hasRecording }

        XCTAssertFalse(microphone.hasRecording)
    }

    private func waitUntil(_ condition: @escaping @MainActor () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = ContinuousClock.now + .seconds(3)
        while !(await condition()), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        let completed = await condition()
        XCTAssertTrue(completed, "Timed out waiting for voice lifecycle state", file: file, line: line)
    }
}

@MainActor
private final class StubVoiceRecording: VoiceRecording {
    var permissionGranted = true
    var deferPermission = false
    var permissionReply: ((Bool) -> Void)?
    var currentTime: TimeInterval = 0
    var level: Double = 0
    var maximumDuration: TimeInterval?
    var onEvent: (@MainActor (VoiceRecordingEvent) -> Void)?
    var hasRecording = false
    var startCount = 0
    var readCount = 0
    var failStart = false
    var failRead = false

    func requestPermission() async -> Bool {
        guard deferPermission else { return permissionGranted }
        return await withCheckedContinuation { continuation in
            permissionReply = { continuation.resume(returning: $0) }
        }
    }

    func start(maximumDuration: TimeInterval, onEvent: @escaping @MainActor (VoiceRecordingEvent) -> Void) throws {
        startCount += 1
        hasRecording = true
        if failStart { throw URLError(.unknown) }
        self.maximumDuration = maximumDuration
        self.onEvent = onEvent
    }

    func updateMeters() {}

    func readAndDiscard() throws -> Data {
        readCount += 1
        defer { discard() }
        if failRead { throw URLError(.cannotOpenFile) }
        return Data([1, 2, 3])
    }

    func discard() {
        hasRecording = false
        onEvent = nil
    }
}

private actor ControlledTranscription {
    var audio: Data?
    var requestCount = 0
    private var reply: CheckedContinuation<String, Error>?
    var isPending: Bool { reply != nil }

    func send(_ audio: Data) async throws -> String {
        self.audio = audio
        requestCount += 1
        return try await withCheckedThrowingContinuation { reply = $0 }
    }

    func complete(_ result: Result<String, Error>) {
        reply?.resume(with: result)
        reply = nil
    }
}
