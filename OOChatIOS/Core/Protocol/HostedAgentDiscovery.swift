import Foundation

struct HostedAgentDiscoveryResult {
    let endpoint: ResolvedEndpoint
    let skills: [AgentSkill]
    let metadataAvailable: Bool
}
/// Resolves both the connection route and the public metadata advertised by an agent.
/// Direct `/info` metadata is preferred; relay profile metadata is the fallback when
/// the host itself cannot be reached over HTTP.
actor HostedAgentDiscovery {
    private let session: URLSession
    private let relayURL: String
    private let localEndpoints: [String]

    init(session: URLSession, relayURL: String, localEndpoints: [String]) {
        self.session = session
        self.relayURL = relayURL
        self.localEndpoints = localEndpoints
    }

    func discover(agentAddress: String) async throws -> HostedAgentDiscoveryResult {
        for httpURL in localEndpoints {
            if let result = try await probe(httpURL: httpURL, agentAddress: agentAddress, timeout: 1.2) {
                return result
            }
        }

        let normalizedRelay = relayURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let relayHTTP = normalizedRelay.replacingOccurrences(of: "wss://", with: "https://")
            .replacingOccurrences(of: "ws://", with: "http://")
        var relaySkills: [AgentSkill] = []
        var relayMetadataAvailable = false
        if let url = URL(string: "\(relayHTTP)/api/relay/agents/\(agentAddress)"),
           let relayInfo: AgentInfo = try? await fetchJSON(url: url, timeout: 3.0) {
            relayMetadataAvailable = true
            relaySkills = normalizedSkills(relayInfo.advertisedSkills)
            for httpURL in sortByProximity(relayInfo.endpoints ?? []) where httpURL.hasPrefix("http") {
                if let result = try await probe(httpURL: httpURL, agentAddress: agentAddress, timeout: 2.5) {
                    return result
                }
            }
        }

        guard let relaySocketURL = URL(string: "\(normalizedRelay)/ws/input") else {
            throw HostedAgentClientError.invalidURL("\(normalizedRelay)/ws/input")
        }
        return HostedAgentDiscoveryResult(
            endpoint: ResolvedEndpoint(wsURL: relaySocketURL, kind: .relay, label: normalizedRelay),
            skills: relaySkills,
            metadataAvailable: relayMetadataAvailable
        )
    }

    private func probe(
        httpURL: String,
        agentAddress: String,
        timeout: TimeInterval
    ) async throws -> HostedAgentDiscoveryResult? {
        guard let url = URL(string: "\(httpURL)/info") else {
            return nil
        }
        guard let info: AgentInfo = try? await fetchJSON(url: url, timeout: timeout),
              info.address == agentAddress else {
            return nil
        }
        guard let wsURL = URL(string: httpToWebSocket(httpURL)) else {
            throw HostedAgentClientError.invalidURL(httpURL)
        }
        return HostedAgentDiscoveryResult(
            endpoint: ResolvedEndpoint(
                wsURL: wsURL,
                kind: .direct,
                label: info.name.map { "\($0) at \(httpURL)" } ?? httpURL
            ),
            skills: normalizedSkills(info.advertisedSkills),
            metadataAvailable: true
        )
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

    private func normalizedSkills(_ skills: [AgentSkill]) -> [AgentSkill] {
        var seen: Set<String> = []
        return skills.compactMap { skill in
            let name = skill.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, seen.insert(name.lowercased()).inserted else {
                return nil
            }
            return AgentSkill(
                name: name,
                description: skill.description.trimmingCharacters(in: .whitespacesAndNewlines),
                location: skill.location
            )
        }
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
}
