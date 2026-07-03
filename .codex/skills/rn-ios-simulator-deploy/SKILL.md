---
name: rn-ios-simulator-deploy
description: Cleanly rebuild and install a React Native iOS app on an Apple iOS Simulator. Use when the user asks to deploy, rebuild, reinstall, launch, or run a React Native iOS branch on a simulator, especially after branch changes, stale Pods, stale DerivedData, bad Hermes paths, or mismatched cached native configuration.
---

# RN iOS Simulator Deploy

## Core Rule

Always prefer a clean rebuild over reusing previous simulator artifacts after switching branches or updating native dependencies.

The correct order is:

1. Confirm the target repo, branch, and a clean worktree.
2. Clean old React Native/iOS generated state that can preserve stale absolute paths.
3. Reinstall iOS Pods from the current checkout.
4. Build the current checkout.
5. Install and launch the freshly built app on the booted simulator.

Do not install an existing `.app` bundle until after a successful build from the current branch.

## Recommended Script

Use `scripts/deploy_rn_ios_sim.sh` from this repo-level skill when possible.
From the repository root:

```bash
.codex/skills/rn-ios-simulator-deploy/scripts/deploy_rn_ios_sim.sh --repo /path/to/react-native-app --branch ui-update
```

For the ConnectOnion chat iOS example:

```bash
.codex/skills/rn-ios-simulator-deploy/scripts/deploy_rn_ios_sim.sh \
  --repo /Users/cliff/connectonion/examples/oo-chat-react-native-ios \
  --branch ui-update
```

The script cleans `ios/build`, `ios/Pods`, Metro caches, and temporary React Native caches, then runs `pod install`, `xcodebuild`, `simctl install`, and `simctl launch`.

## Manual Workflow

Run these steps from the React Native project root.

1. Verify repo and branch:

```bash
git status --short --branch
git branch --all --list '*target-branch*'
```

If a target branch was requested, switch to it only when the worktree is clean or the user explicitly approves handling local changes.

2. Sync the requested branch:

```bash
git pull --ff-only origin target-branch
```

3. Use Xcode's developer directory when `xcrun simctl` is unavailable because `xcode-select` points at Command Line Tools:

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

Do this per command/session unless the user asks to change global `xcode-select`.

4. Confirm a simulator is booted:

```bash
xcrun simctl list devices booted
```

Boot one if needed:

```bash
xcrun simctl boot "iPhone 17"
open -a Simulator
```

5. Clean stale native and bundler state before building:

```bash
rm -rf ios/build
rm -rf ios/Pods
rm -rf node_modules/.cache
rm -rf "$TMPDIR/metro-"* "$TMPDIR/react-"* "$TMPDIR/haste-map-"*
```

Do not delete user source files. Do not delete `node_modules` unless dependencies are missing or the user asks for a full JS dependency reinstall.

6. Reinstall Pods from the current checkout:

```bash
cd ios
bundle exec pod install
cd ..
```

7. Build the current checkout. If Hermes resolves to an old absolute path, override `HERMES_CLI_PATH` explicitly:

```bash
HERMES_CLI_PATH="$PWD/node_modules/hermes-compiler/hermesc/osx-bin/hermesc" \
xcodebuild \
  -workspace ios/ConnectOnionIOS.xcworkspace \
  -scheme ConnectOnionIOS \
  -configuration Release \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath ios/build/SignedDerivedData \
  build
```

Use the workspace and scheme from the app if they differ.

8. Install and launch the freshly built app:

```bash
xcrun simctl install booted ios/build/SignedDerivedData/Build/Products/Release-iphonesimulator/ConnectOnionIOS.app
xcrun simctl launch booted org.reactjs.native.example.ConnectOnionIOS
open -a Simulator
```

Read the bundle id from `package.json`, the install script, or `ios/*/Info.plist` when it differs.

## Failure Checks

If build output mentions a path from an old project or old branch, search generated iOS files before retrying:

```bash
rg "old-project-name|HERMES_CLI_PATH|hermesc" ios/Pods ios/build node_modules/react-native
```

If stale paths remain under `ios/Pods`, remove `ios/Pods` and rerun `pod install`. If they remain only in build output, remove `ios/build` and rebuild. If `simctl` is missing, use `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

Report the exact build command, app path, bundle id, simulator name, and launch process id in the final answer.
