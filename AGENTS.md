# Repository Guidelines

## Project Structure & Module Organization

This repository is the native SwiftUI iOS client for OO Chat and the ConnectOnion hosted-agent chat protocol. App source lives in `OOChatIOS/`: `App/ContentView.swift` defines the UI shell, `Features/Chat/ChatViewModel.swift` coordinates chat state, `Core/Protocol/HostedAgentClient.swift` handles signed protocol traffic, `Core/Identity/IdentityStore.swift` owns Keychain-backed identity, and `Core/Persistence/ConversationStore.swift` persists conversation snapshots. The Xcode project is `OOChatIOS.xcodeproj`.

Reference implementations and protocol context are kept as submodules under `submodules/`: `connectonion/` is the Python agent SDK, `connectonion-ts/` owns the TypeScript remote-agent/WebSocket client, and `oo-chat/` is the Next.js web UI. Treat these as upstream references unless a task explicitly asks to edit a submodule.

Repo-level Codex skills live in `.codex/skills/`.

## Build, Test, and Development Commands

Build for Simulator:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild -project OOChatIOS.xcodeproj -scheme OOChatIOS \
  -configuration Debug -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build/DerivedData build
```

Install and launch on a booted simulator:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcrun simctl install booted build/DerivedData/Build/Products/Debug-iphonesimulator/OOChatIOS.app

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcrun simctl launch booted com.connectonion.oochatios
```

Use the `DEVELOPER_DIR` prefix when this machine points `xcode-select` at Command Line Tools.

## Coding Style & Naming Conventions

Follow Swift API Design Guidelines: types in `UpperCamelCase`, methods/properties in `lowerCamelCase`, and clear protocol/data model names such as `HostedAgentClient` or `ConversationSnapshot`. Keep SwiftUI views small and move protocol, identity, persistence, and parsing logic into focused files. Prefer value types for protocol models and avoid persisting private key material outside Keychain.

## Testing Guidelines

Unit tests live in `OOChatIOSTests/` and run through the shared `OOChatIOS` scheme. Before opening a PR, run `xcodebuild test` on a simulator and manually smoke test: add/paste an agent address, send `hello`, verify CONNECT/INPUT succeeds, and confirm conversations restore after relaunch. Add focused XCTest coverage when introducing parsing, signing, persistence, or protocol state-machine changes.

## Commit & Pull Request Guidelines

The current history uses short imperative commit subjects, e.g. `Initial iOS chat app`. Keep subjects concise and focused. PRs should describe the user-visible change, list simulator/device verification, link related issues, and include screenshots or screen recordings for UI changes. Call out protocol changes and any divergence from `connectonion-ts` behavior.

## Agent-Specific Instructions

When implementing chat behavior, compare against `submodules/connectonion-ts/src/connect/` first. Preserve the app's native SwiftUI architecture; do not port React patterns wholesale.
