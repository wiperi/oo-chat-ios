import Foundation

enum HostedAgentClientError: LocalizedError {
    case invalidAddress
    case invalidURL(String)
    case badFrame
    case server(String)
    case closed
    case timeout

    var errorDescription: String? {
        switch self {
        case .invalidAddress:
            return "Enter a hosted agent address in 0x-prefixed Ed25519 format."
        case .invalidURL(let url):
            return "Invalid URL: \(url)"
        case .badFrame:
            return "Received an invalid hosted-agent frame."
        case .server(let message):
            return message
        case .closed:
            return "Connection closed before the agent replied."
        case .timeout:
            return "The hosted agent did not reply before the timeout."
        }
    }
}

final class HostedAgentClient {
    private let identityStore: IdentityStore
    private let session: URLSession
    private let relayURL = "wss://oo.openonion.ai"
    private let localEndpoints = ["http://localhost:8000", "http://127.0.0.1:8000"]

    init(identityStore: IdentityStore, session: URLSession = .shared) {
        self.identityStore = identityStore
        self.session = session
    }

    static func isHostedAgentAddress(_ address: String) -> Bool {
        address.range(of: #"^0x[0-9a-fA-F]{64}$"#, options: .regularExpression) != nil
    }

    func connect(agentAddress: String, conversation: Conversation) async throws -> HostedAgentResult {
        guard Self.isHostedAgentAddress(agentAddress) else {
            throw HostedAgentClientError.invalidAddress
        }
        let endpoint = try await resolveEndpoint(agentAddress: agentAddress)
        let socket = session.webSocketTask(with: endpoint.wsURL)
        socket.resume()
        defer {
            socket.cancel(with: .normalClosure, reason: nil)
        }

        let connectFrame = try buildConnectFrame(agentAddress: agentAddress, conversation: conversation, endpoint: endpoint)
        try await send(connectFrame, over: socket)

        while true {
            let frame = try await receiveFrame(from: socket)
            switch frame["type"]?.stringValue {
            case "PING":
                try await send(["type": .string("PONG")], over: socket)
            case "CONNECTED":
                return HostedAgentResult(output: nil, endpointLabel: endpoint.label, serverSession: extractServerSession(from: frame))
            case "ERROR":
                throw HostedAgentClientError.server(messageText(frame))
            default:
                continue
            }
        }
    }

    func sendPrompt(agentAddress: String, conversation: Conversation, prompt: String) async throws -> HostedAgentResult {
        guard Self.isHostedAgentAddress(agentAddress) else {
            throw HostedAgentClientError.invalidAddress
        }
        let endpoint = try await resolveEndpoint(agentAddress: agentAddress)
        let socket = session.webSocketTask(with: endpoint.wsURL)
        socket.resume()
        defer {
            socket.cancel(with: .normalClosure, reason: nil)
        }

        let connectFrame = try buildConnectFrame(agentAddress: agentAddress, conversation: conversation, endpoint: endpoint)
        try await send(connectFrame, over: socket)

        var inputSent = false
        var serverSession = conversation.serverSession
        while true {
            let frame = try await receiveFrame(from: socket)
            switch frame["type"]?.stringValue {
            case "PING":
                try await send(["type": .string("PONG")], over: socket)
            case "CONNECTED":
                if let session = extractServerSession(from: frame) {
                    serverSession = session
                }
                if !inputSent {
                    inputSent = true
                    let inputFrame = try buildInputFrame(agentAddress: agentAddress, prompt: prompt, endpoint: endpoint)
                    try await send(inputFrame, over: socket)
                }
            case "OUTPUT":
                if let session = extractServerSession(from: frame) {
                    serverSession = session
                }
                return HostedAgentResult(output: messageText(frame), endpointLabel: endpoint.label, serverSession: serverSession)
            case "ERROR":
                throw HostedAgentClientError.server(messageText(frame))
            case "ask_user":
                throw HostedAgentClientError.server(messageText(frame))
            default:
                continue
            }
        }
    }

    private func resolveEndpoint(agentAddress: String) async throws -> ResolvedEndpoint {
        for httpURL in localEndpoints {
            if let endpoint = try await probe(httpURL: httpURL, agentAddress: agentAddress, timeout: 1.2) {
                return endpoint
            }
        }

        let normalizedRelay = relayURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let relayHTTP = normalizedRelay.replacingOccurrences(of: "wss://", with: "https://")
            .replacingOccurrences(of: "ws://", with: "http://")
        if let url = URL(string: "\(relayHTTP)/api/relay/agents/\(agentAddress)"),
           let relayInfo: AgentInfo = try? await fetchJSON(url: url, timeout: 3.0) {
            for httpURL in sortByProximity(relayInfo.endpoints ?? []) where httpURL.hasPrefix("http") {
                if let endpoint = try await probe(httpURL: httpURL, agentAddress: agentAddress, timeout: 2.5) {
                    return endpoint
                }
            }
        }

        guard let relaySocketURL = URL(string: "\(normalizedRelay)/ws/input") else {
            throw HostedAgentClientError.invalidURL("\(normalizedRelay)/ws/input")
        }
        return ResolvedEndpoint(wsURL: relaySocketURL, kind: .relay, label: normalizedRelay)
    }

    private func probe(httpURL: String, agentAddress: String, timeout: TimeInterval) async throws -> ResolvedEndpoint? {
        guard let url = URL(string: "\(httpURL)/info") else {
            return nil
        }
        guard let info: AgentInfo = try? await fetchJSON(url: url, timeout: timeout), info.address == agentAddress else {
            return nil
        }
        guard let wsURL = URL(string: httpToWebSocket(httpURL)) else {
            throw HostedAgentClientError.invalidURL(httpURL)
        }
        return ResolvedEndpoint(wsURL: wsURL, kind: .direct, label: info.name.map { "\($0) at \(httpURL)" } ?? httpURL)
    }

    private func fetchJSON<T: Decodable>(url: URL, timeout: TimeInterval) async throws -> T {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw HostedAgentClientError.server("Endpoint \(url.absoluteString) did not return OK.")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func sortByProximity(_ endpoints: [String]) -> [String] {
        endpoints.sorted { left, right in
            priority(left) < priority(right)
        }
    }

    private func priority(_ endpoint: String) -> Int {
        if endpoint.contains("localhost") || endpoint.contains("127.0.0.1") {
            return 0
        }
        if endpoint.contains("192.168.") || endpoint.contains("10.") || endpoint.contains("172.16.") {
            return 1
        }
        return 2
    }

    private func httpToWebSocket(_ httpURL: String) -> String {
        let base = httpURL.replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let scheme = httpURL.hasPrefix("https://") ? "wss" : "ws"
        return "\(scheme)://\(base)/ws"
    }

    private func buildConnectFrame(agentAddress: String, conversation: Conversation, endpoint: ResolvedEndpoint) throws -> [String: JSONValue] {
        let timestamp = Double(Int(Date().timeIntervalSince1970))
        let payload: [String: JSONValue] = [
            "timestamp": .number(timestamp),
            "to": .string(agentAddress),
        ]
        var frame = try identityStore.signedEnvelope(type: "CONNECT", payload: payload)
        frame["session_id"] = .string(conversation.id)
        frame["session"] = .object(sessionPayload(for: conversation))
        if endpoint.kind == .relay {
            frame["to"] = .string(agentAddress)
        }
        return frame
    }

    private func sessionPayload(for conversation: Conversation) -> [String: JSONValue] {
        var session = conversation.serverSession ?? [:]
        session["session_id"] = .string(conversation.id)
        session["mode"] = .string(conversation.mode.rawValue)
        if conversation.mode == .ulw {
            if session["ulw_turns"] == nil {
                session["ulw_turns"] = .number(100)
            }
            if session["ulw_turns_used"] == nil {
                session["ulw_turns_used"] = .number(0)
            }
        } else {
            session.removeValue(forKey: "ulw_turns")
            session.removeValue(forKey: "ulw_turns_used")
        }
        return session
    }

    private func buildInputFrame(agentAddress: String, prompt: String, endpoint: ResolvedEndpoint) throws -> [String: JSONValue] {
        let timestamp = Double(Int(Date().timeIntervalSince1970))
        var payload: [String: JSONValue] = [
            "prompt": .string(prompt),
            "timestamp": .number(timestamp),
        ]
        if endpoint.kind == .relay {
            payload["to"] = .string(agentAddress)
        }
        var frame = try identityStore.signedEnvelope(type: "INPUT", payload: payload)
        frame["input_id"] = .string(UUID().uuidString)
        frame["prompt"] = .string(prompt)
        if endpoint.kind == .relay {
            frame["to"] = .string(agentAddress)
        }
        return frame
    }

    private func extractServerSession(from frame: [String: JSONValue]) -> [String: JSONValue]? {
        if case .object(let session)? = frame["session"] {
            return session
        }
        return nil
    }

    private func send(_ frame: [String: JSONValue], over socket: URLSessionWebSocketTask) async throws {
        let data = try JSONEncoder().encode(frame)
        guard let text = String(data: data, encoding: .utf8) else {
            throw HostedAgentClientError.badFrame
        }
        try await socket.send(.string(text))
    }

    private func receiveFrame(from socket: URLSessionWebSocketTask, timeout: TimeInterval = 45.0) async throws -> [String: JSONValue] {
        try await withThrowingTaskGroup(of: [String: JSONValue].self) { group in
            group.addTask {
                try await self.readFrame(from: socket)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw HostedAgentClientError.timeout
            }

            guard let frame = try await group.next() else {
                throw HostedAgentClientError.closed
            }
            group.cancelAll()
            return frame
        }
    }

    private func readFrame(from socket: URLSessionWebSocketTask) async throws -> [String: JSONValue] {
        let message = try await socket.receive()
        switch message {
        case .string(let text):
            guard let data = text.data(using: .utf8) else {
                throw HostedAgentClientError.badFrame
            }
            return try JSONDecoder().decode([String: JSONValue].self, from: data)
        case .data(let data):
            return try JSONDecoder().decode([String: JSONValue].self, from: data)
        @unknown default:
            throw HostedAgentClientError.badFrame
        }
    }

    private func messageText(_ frame: [String: JSONValue]) -> String {
        for key in ["result", "message", "error", "text", "content"] {
            if let value = frame[key]?.stringValue {
                return value
            }
        }
        return "Hosted agent returned \(frame["type"]?.stringValue ?? "an event")."
    }
}
