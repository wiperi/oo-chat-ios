import AVFAudio
import Combine
import Foundation
import Speech

enum VoiceInputState: Equatable {
    case idle
    case requestingPermission
    case listening
}

enum VoiceInputError: LocalizedError {
    case speechRecognitionDenied
    case speechRecognitionRestricted
    case microphoneDenied
    case recognizerUnavailable
    case invalidAudioInput

    var errorDescription: String? {
        switch self {
        case .speechRecognitionDenied:
            return "Speech recognition permission was denied. You can enable it in Settings."
        case .speechRecognitionRestricted:
            return "Speech recognition is restricted on this device."
        case .microphoneDenied:
            return "Microphone access was denied. You can enable it in Settings."
        case .recognizerUnavailable:
            return "Speech recognition is currently unavailable."
        case .invalidAudioInput:
            return "The microphone could not provide audio for speech recognition."
        }
    }
}

@MainActor
protocol SpeechTranscribing: AnyObject {
    func requestAuthorization() async throws
    func start(
        resultHandler: @escaping (_ transcript: String, _ isFinal: Bool) -> Void,
        failureHandler: @escaping (Error) -> Void
    ) throws
    func stop()
}

@MainActor
final class AppleSpeechTranscriber: SpeechTranscribing {
    private let audioEngine = AVAudioEngine()
    private let speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var hasInstalledAudioTap = false
    private var hasActiveAudioSession = false
    private var previousAudioCategory: AVAudioSession.Category?
    private var previousAudioMode: AVAudioSession.Mode?
    private var previousAudioOptions: AVAudioSession.CategoryOptions = []

    init(locale: Locale = .current) {
        speechRecognizer = SFSpeechRecognizer(locale: locale)
    }

    func requestAuthorization() async throws {
        let speechStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }

        switch speechStatus {
        case .authorized:
            break
        case .restricted:
            throw VoiceInputError.speechRecognitionRestricted
        case .denied, .notDetermined:
            throw VoiceInputError.speechRecognitionDenied
        @unknown default:
            throw VoiceInputError.speechRecognitionDenied
        }

        try Task.checkCancellation()
        let microphoneGranted = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
        guard microphoneGranted else {
            throw VoiceInputError.microphoneDenied
        }
    }

    func start(
        resultHandler: @escaping (_ transcript: String, _ isFinal: Bool) -> Void,
        failureHandler: @escaping (Error) -> Void
    ) throws {
        stop()

        guard let speechRecognizer, speechRecognizer.isAvailable else {
            throw VoiceInputError.recognizerUnavailable
        }

        try configureAudioSession()

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        recognitionRequest = request

        try installAudioTap(for: request)

        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self, weak request] result, error in
            Task { @MainActor in
                guard let self, self.recognitionRequest === request else {
                    return
                }

                if let result {
                    resultHandler(result.bestTranscription.formattedString, result.isFinal)
                    if result.isFinal {
                        self.cleanup()
                        return
                    }
                }

                if let error {
                    self.cleanup()
                    failureHandler(error)
                }
            }
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            cleanup()
            throw error
        }
    }

    func stop() {
        cleanup()
    }

    private func configureAudioSession() throws {
        let audioSession = AVAudioSession.sharedInstance()
        previousAudioCategory = audioSession.category
        previousAudioMode = audioSession.mode
        previousAudioOptions = audioSession.categoryOptions
        do {
            try audioSession.setCategory(.record, mode: .measurement, options: [])
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
            hasActiveAudioSession = true
        } catch {
            restoreAudioSessionConfiguration()
            throw error
        }
    }

    private func installAudioTap(
        for request: SFSpeechAudioBufferRecognitionRequest
    ) throws {
        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        guard recordingFormat.sampleRate > 0, recordingFormat.channelCount > 0 else {
            cleanup()
            throw VoiceInputError.invalidAudioInput
        }

        inputNode.installTap(
            onBus: 0,
            bufferSize: 1_024,
            format: recordingFormat
        ) { [weak request] buffer, _ in
            request?.append(buffer)
        }
        hasInstalledAudioTap = true
    }

    private func cleanup() {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        if hasInstalledAudioTap {
            audioEngine.inputNode.removeTap(onBus: 0)
            hasInstalledAudioTap = false
        }

        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil

        if hasActiveAudioSession {
            try? AVAudioSession.sharedInstance().setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
            hasActiveAudioSession = false
        }
        restoreAudioSessionConfiguration()
    }

    private func restoreAudioSessionConfiguration() {
        defer {
            previousAudioCategory = nil
            previousAudioMode = nil
            previousAudioOptions = []
        }
        guard let previousAudioCategory, let previousAudioMode else {
            return
        }
        try? AVAudioSession.sharedInstance().setCategory(
            previousAudioCategory,
            mode: previousAudioMode,
            options: previousAudioOptions
        )
    }
}

@MainActor
final class VoiceInputController: ObservableObject {
    @Published private(set) var state: VoiceInputState = .idle

    var isActive: Bool {
        state != .idle
    }

    private let transcriber: SpeechTranscribing
    private var authorizationTask: Task<Void, Never>?
    private var activeSessionID: UUID?
    private var targetConversationID: String?
    private var promptPrefix = ""
    private var transcriptHandler: ((_ conversationID: String, _ text: String) -> Void)?
    private var failureHandler: ((_ conversationID: String, _ message: String) -> Void)?

    init(transcriber: SpeechTranscribing? = nil) {
        self.transcriber = transcriber ?? AppleSpeechTranscriber()
    }

    func start(
        promptPrefix: String,
        conversationID: String,
        transcriptHandler: @escaping (_ conversationID: String, _ text: String) -> Void,
        failureHandler: @escaping (_ conversationID: String, _ message: String) -> Void
    ) {
        guard state == .idle else {
            return
        }

        let sessionID = UUID()
        activeSessionID = sessionID
        targetConversationID = conversationID
        self.promptPrefix = promptPrefix
        self.transcriptHandler = transcriptHandler
        self.failureHandler = failureHandler
        state = .requestingPermission

        authorizationTask = Task { [weak self] in
            guard let self else {
                return
            }

            do {
                try await transcriber.requestAuthorization()
                try Task.checkCancellation()
                guard activeSessionID == sessionID else {
                    return
                }

                state = .listening
                try transcriber.start(
                    resultHandler: { [weak self] transcript, isFinal in
                        self?.handleTranscript(
                            transcript,
                            isFinal: isFinal,
                            sessionID: sessionID
                        )
                    },
                    failureHandler: { [weak self] error in
                        self?.handleFailure(error, sessionID: sessionID)
                    }
                )
            } catch is CancellationError {
                return
            } catch {
                handleFailure(error, sessionID: sessionID)
            }
        }
    }

    func stop() {
        guard state != .idle || activeSessionID != nil else {
            return
        }
        authorizationTask?.cancel()
        authorizationTask = nil
        activeSessionID = nil
        clearSessionContext()
        transcriber.stop()
        state = .idle
    }

    private func handleTranscript(
        _ transcript: String,
        isFinal: Bool,
        sessionID: UUID
    ) {
        guard activeSessionID == sessionID, let targetConversationID else {
            return
        }

        transcriptHandler?(
            targetConversationID,
            Self.mergedPrompt(prefix: promptPrefix, transcript: transcript)
        )

        if isFinal {
            authorizationTask = nil
            activeSessionID = nil
            clearSessionContext()
            state = .idle
        }
    }

    private func handleFailure(_ error: Error, sessionID: UUID) {
        guard activeSessionID == sessionID, let targetConversationID else {
            return
        }

        let failureHandler = failureHandler
        authorizationTask = nil
        activeSessionID = nil
        clearSessionContext()
        transcriber.stop()
        state = .idle
        failureHandler?(targetConversationID, error.localizedDescription)
    }

    private func clearSessionContext() {
        targetConversationID = nil
        promptPrefix = ""
        transcriptHandler = nil
        failureHandler = nil
    }

    private static func mergedPrompt(prefix: String, transcript: String) -> String {
        guard !prefix.isEmpty else {
            return transcript
        }
        guard !transcript.isEmpty else {
            return prefix
        }
        if prefix.last?.isWhitespace == true {
            return prefix + transcript
        }
        return prefix + " " + transcript
    }
}
