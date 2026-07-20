import SwiftUI
import UIKit
import XCTest
@testable import OOChatIOS

@MainActor
enum ViewHost {
    private static let accessibilityEnabled: Bool = {
        guard
            let handle = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW),
            let symbol = dlsym(handle, "_AXSSetAutomationEnabled")
        else {
            return false
        }
        typealias SetAutomationEnabled = @convention(c) (Int32) -> Void
        unsafeBitCast(symbol, to: SetAutomationEnabled.self)(1)
        return true
    }()

    static func host(_ view: some View, size: CGSize = CGSize(width: 390, height: 844)) -> UIWindow {
        precondition(accessibilityEnabled, "Failed to enable accessibility automation in simulator")
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        pump()
        return window
    }

    static func pump(_ interval: TimeInterval = 0.08) {
        RunLoop.main.run(until: Date().addingTimeInterval(interval))
    }

    static func accessibilityElements(in window: UIWindow) -> [NSObject] {
        var found: [NSObject] = []
        var queue: [NSObject] = [window]
        var visited = Set<ObjectIdentifier>()

        while !queue.isEmpty {
            let node = queue.removeFirst()
            guard visited.insert(ObjectIdentifier(node)).inserted else {
                continue
            }
            found.append(node)

            if let elements = node.accessibilityElements as? [NSObject] {
                queue.append(contentsOf: elements)
            }
            let count = node.accessibilityElementCount()
            if count != NSNotFound, count > 0, count < 500 {
                for index in 0..<count {
                    if let element = node.accessibilityElement(at: index) as? NSObject {
                        queue.append(element)
                    }
                }
            }
            if let view = node as? UIView {
                queue.append(contentsOf: view.subviews)
            }
        }

        return found
    }

    static func element(
        identifier: String? = nil,
        labelContains: String? = nil,
        valueContains: String? = nil,
        in window: UIWindow
    ) -> NSObject? {
        accessibilityElements(in: window).first { element in
            if let identifier {
                guard accessibilityIdentifier(of: element) == identifier else {
                    return false
                }
            }
            if let labelContains {
                guard element.accessibilityLabel?.contains(labelContains) == true else {
                    return false
                }
            }
            if let valueContains {
                guard element.accessibilityValue?.contains(valueContains) == true else {
                    return false
                }
            }
            return true
        }
    }

    @discardableResult
    static func activate(
        identifier: String? = nil,
        labelContains: String? = nil,
        in window: UIWindow
    ) -> Bool {
        guard let match = element(identifier: identifier, labelContains: labelContains, in: window) else {
            return false
        }
        let activated = match.accessibilityActivate()
        pump()
        return activated
    }

    private static func accessibilityIdentifier(of element: NSObject) -> String? {
        if let identification = element as? UIAccessibilityIdentification,
           let identifier = identification.accessibilityIdentifier {
            return identifier
        }
        guard element.responds(to: NSSelectorFromString("accessibilityIdentifier")) else {
            return nil
        }
        return element.value(forKey: "accessibilityIdentifier") as? String
    }
}

@MainActor
final class InMemoryConversationRepository: ConversationRepository {
    private var snapshot: ChatSnapshot

    init(snapshot: ChatSnapshot = .empty) {
        self.snapshot = snapshot
    }

    func load() -> ChatSnapshot {
        snapshot
    }

    func upsertConversation(_ conversation: Conversation) {
        if let index = snapshot.conversations.firstIndex(where: { $0.id == conversation.id }) {
            snapshot.conversations[index] = conversation
        } else {
            snapshot.conversations.append(conversation)
        }
    }

    func deleteConversation(id: String) {
        snapshot.conversations.removeAll { $0.id == id }
    }

    func upsertAgent(_ agent: AgentConnection) {
        if let index = snapshot.agents.firstIndex(where: { $0.id == agent.id }) {
            snapshot.agents[index] = agent
        } else {
            snapshot.agents.append(agent)
        }
    }

    func deleteAgent(id: String) {
        snapshot.agents.removeAll { $0.id == id }
    }

    func saveActive(agentID: String?, conversationID: String?) {
        snapshot.activeAgentID = agentID
        snapshot.activeConversationID = conversationID
    }

    func search(_ query: String) -> [Conversation] {
        snapshot.conversations.filter { $0.title.localizedStandardContains(query) }
    }
}

enum ViewFixtures {
    static func agent(
        id: String = "agent1",
        address: String = "0x" + String(repeating: "ab", count: 32)
    ) -> AgentConnection {
        AgentConnection(id: id, address: address, name: "Test Agent")
    }

    static func conversation(
        id: String = "con1",
        agent: AgentConnection,
        messages: [ChatMessage] = []
    ) -> Conversation {
        Conversation(
            id: id,
            title: "Test Chat",
            agentID: agent.id,
            agentAddress: agent.address,
            mode: .safe,
            createdAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: 2_000),
            messages: messages,
            serverSession: nil
        )
    }

    static func toolMessage(
        id: String = UUID().uuidString,
        name: String? = "read_file",
        state: ToolCallState? = .completed,
        content: String = "",
        arguments: [String: JSONValue]? = ["path": .string("/tmp/example.txt")]
    ) -> ChatMessage {
        ChatMessage(
            id: id,
            role: .tool,
            content: content,
            toolName: name,
            toolArguments: arguments,
            toolState: state
        )
    }

    @MainActor
    static func chatViewModel(
        transport: MockAgentTransport = MockAgentTransport(),
        messages: [ChatMessage] = []
    ) -> ChatViewModel {
        let agent = agent()
        let conversation = conversation(agent: agent, messages: messages)
        let repo = InMemoryConversationRepository(
            snapshot: ChatSnapshot(
                agents: [agent],
                conversations: [conversation],
                activeAgentID: agent.id,
                activeConversationID: conversation.id
            )
        )
        let monitor = MockNetworkMonitor()
        return ChatViewModel(store: repo, client: transport, networkMonitor: monitor)
    }
}
