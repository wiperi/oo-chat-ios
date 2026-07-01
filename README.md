# OO Chat iOS

Native SwiftUI iOS client for the ConnectOnion hosted-agent chat protocol.

This mirrors the React Native example's core flow without React Native:

- Keychain-backed Ed25519 identity using CryptoKit.
- Signed CONNECT and INPUT protocol frames.
- Local simulator fallback for agents hosted at `http://localhost:8000`.
- Relay endpoint discovery through `wss://oo.openonion.ai`.
- SwiftUI tabs for agent selection, chat, and identity/settings.
- Server session state is saved with each conversation and sent back on the next CONNECT.
- UserDefaults-backed conversation snapshots, with private key material kept out of ordinary persistence.

## Build

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild \
  -project OOChatIOS.xcodeproj \
  -scheme OOChatIOS \
  -configuration Debug \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  build
```

## Install to a Booted Simulator

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcrun simctl install booted build/DerivedData/Build/Products/Debug-iphonesimulator/OOChatIOS.app

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcrun simctl launch booted com.connectonion.oochatios
```

## Local Agent Smoke Path

Start a local hosted agent with `relay_url=None`, then copy the address from `/info`:

```sh
python3 server.py
curl http://localhost:8000/info
```

In the app, open the Agents tab, paste the address, tap `Use Address`, then send `hello`.
