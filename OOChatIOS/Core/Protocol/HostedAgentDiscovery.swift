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

    /// Matches on the parsed host, not the raw string: `contains("10.")` also hits
    /// `x.example.com:8010.` and misses most of 172.16.0.0/12.
    private func priority(_ endpoint: String) -> Int {
        guard let host = URLComponents(string: endpoint)?.host?.lowercased()
            ?? URLComponents(string: "http://\(endpoint)")?.host?.lowercased() else {
            return 2
        }
        if host == "localhost" || host == "127.0.0.1" || host == "::1" {
            return 0
        }
        return Self.isPrivateHost(host) ? 1 : 2
    }

    /// Hosts reachable only from the local network, which are worth probing before anything
    /// routed over the internet.
    static func isPrivateHost(_ host: String) -> Bool {
        isPrivateIPv4(host) || isPrivateIPv6(host)
    }

    /// RFC 4193 unique-local (fc00::/7) and RFC 4291 link-local (fe80::/10).
    private static func isPrivateIPv6(_ host: String) -> Bool {
        // URLComponents strips the brackets from "[fe80::1]", but a raw host may keep them.
        let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard bare.contains(":") else {
            return false
        }
        return bare.hasPrefix("fc") || bare.hasPrefix("fd") || bare.hasPrefix("fe8")
            || bare.hasPrefix("fe9") || bare.hasPrefix("fea") || bare.hasPrefix("feb")
    }

    /// RFC 1918 ranges: 10/8, 172.16/12, 192.168/16.
    static func isPrivateIPv4(_ host: String) -> Bool {
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4,
              let first = UInt8(octets[0]),
              let second = UInt8(octets[1]),
              octets[2...].allSatisfy({ UInt8($0) != nil }) else {
            return false
        }
        switch first {
        case 10:
            return true
        case 172:
            return (16...31).contains(second)
        case 192:
            return second == 168
        default:
            return false
        }
    }

    private func httpToWebSocket(_ httpURL: String) -> String {
        let base = httpURL.replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let scheme = httpURL.hasPrefix("https://") ? "wss" : "ws"
        return "\(scheme)://\(base)/ws"
    }
}
