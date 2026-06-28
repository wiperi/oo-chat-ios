# ConnectOnion React Native iOS

React Native iOS client for the ConnectOnion hosted-agent chat experience.

## What is included

- Agent address editor, conversation list, active chat, and identity/settings tabs.
- ChatItem rendering for user, agent, thinking, tool_call, files_received, tool_blocked, onboarding, and pending human gates.
- Human gate UI for ask_user, approval_needed, onboard_required, plan_review, and ulw_turns_reached.
- Approval mode controls for safe, plan, accept_edits, and ulw.
- Image and file picker integration for mobile attachments.
- AsyncStorage-backed conversation persistence.
- Keychain-backed Ed25519 identity with signed CONNECT, INPUT, and onboarding payloads.
- React Native WebSocket hosted-agent transport with local simulator fallback and relay fallback.

The session driver talks to hosted agents over the ConnectOnion WebSocket protocol. In simulator development it first probes `http://localhost:8000/info`, which supports agents started with `relay_url=None`; if that does not match the requested agent address, it falls back to relay endpoint discovery and `wss://oo.openonion.ai/ws/input`.

## Setup

```sh
npm install
bundle install --path vendor/bundle
npm run ios:pods
```

If Node is not installed globally, put a local Node binary on `PATH` before running npm, CocoaPods, or Xcode commands.

## Checks

```sh
npm run typecheck
npm test -- --runInBand
npm run lint
```

## Build and install on a booted simulator

```sh
npm run ios:build:sim
npm run ios:install:booted
```

The Release simulator build embeds `main.jsbundle`, so the installed app does not need Metro to render.

## Local hosted-agent smoke path

Start a local agent, copy the address from `/info`, then use the Agents tab in the simulator:

```sh
python3 server.py
curl http://localhost:8000/info
```

Tap `Use Address`, send `hello`, and the app will sign CONNECT/INPUT from the Keychain identity and render the hosted agent's real `OUTPUT`.
