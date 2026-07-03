#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  deploy_rn_ios_sim.sh --repo PATH [--branch BRANCH] [--scheme SCHEME] [--configuration Release] [--bundle-id ID] [--app-name NAME.app] [--simulator NAME]

Cleanly rebuild and install a React Native iOS app on the booted iOS Simulator.
EOF
}

repo=""
branch=""
scheme=""
configuration="Release"
bundle_id=""
app_name=""
simulator=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) repo="${2:-}"; shift 2 ;;
    --branch) branch="${2:-}"; shift 2 ;;
    --scheme) scheme="${2:-}"; shift 2 ;;
    --configuration) configuration="${2:-}"; shift 2 ;;
    --bundle-id) bundle_id="${2:-}"; shift 2 ;;
    --app-name) app_name="${2:-}"; shift 2 ;;
    --simulator) simulator="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ -z "$repo" ]]; then
  echo "Missing --repo" >&2
  usage
  exit 2
fi

cd "$repo"

if [[ ! -f package.json || ! -d ios ]]; then
  echo "Repo must be a React Native project root with package.json and ios/" >&2
  exit 1
fi

if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "Worktree has uncommitted changes. Refusing to clean/build until they are handled." >&2
  git status --short
  exit 1
fi

if [[ -n "$branch" ]]; then
  git fetch origin "$branch"
  git checkout "$branch"
  git pull --ff-only origin "$branch"
fi

if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

if ! xcrun simctl list devices >/dev/null 2>&1; then
  echo "xcrun simctl is unavailable. Set DEVELOPER_DIR to a full Xcode installation." >&2
  exit 1
fi

if ! xcrun simctl list devices booted | grep -q "(Booted)"; then
  if [[ -z "$simulator" ]]; then
    echo "No booted simulator and no --simulator was provided." >&2
    xcrun simctl list devices available
    exit 1
  fi
  xcrun simctl boot "$simulator"
fi

workspace="$(find ios -maxdepth 1 -name '*.xcworkspace' | head -n 1)"
if [[ -z "$workspace" ]]; then
  echo "No ios/*.xcworkspace found. Run pod install or provide a React Native iOS workspace." >&2
  exit 1
fi

if [[ -z "$scheme" ]]; then
  scheme="$(basename "$workspace" .xcworkspace)"
fi

if [[ -z "$app_name" ]]; then
  app_name="${scheme}.app"
fi

echo "Repo: $(pwd)"
echo "Branch: $(git branch --show-current)"
echo "Workspace: $workspace"
echo "Scheme: $scheme"
echo "Configuration: $configuration"

echo "Cleaning stale native and bundler state..."
rm -rf ios/build
rm -rf ios/Pods
rm -rf node_modules/.cache
rm -rf "${TMPDIR:-/tmp}/metro-"* "${TMPDIR:-/tmp}/react-"* "${TMPDIR:-/tmp}/haste-map-"* 2>/dev/null || true

echo "Installing Pods from current checkout..."
(
  cd ios
  if [[ -f ../Gemfile ]]; then
    bundle exec pod install
  else
    pod install
  fi
)

hermes_cli="$PWD/node_modules/hermes-compiler/hermesc/osx-bin/hermesc"
extra_build_settings=()
if [[ -x "$hermes_cli" ]]; then
  extra_build_settings+=("HERMES_CLI_PATH=$hermes_cli")
fi

echo "Building current checkout..."
xcodebuild \
  -workspace "$workspace" \
  -scheme "$scheme" \
  -configuration "$configuration" \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath ios/build/SignedDerivedData \
  "${extra_build_settings[@]}" \
  build

app_path="ios/build/SignedDerivedData/Build/Products/${configuration}-iphonesimulator/${app_name}"
if [[ ! -d "$app_path" ]]; then
  echo "Built app not found at $app_path" >&2
  find ios/build/SignedDerivedData/Build/Products -maxdepth 3 -name '*.app' -print 2>/dev/null || true
  exit 1
fi

if [[ -z "$bundle_id" ]]; then
  bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_path/Info.plist")"
fi

echo "Installing $app_path..."
xcrun simctl install booted "$app_path"

echo "Launching $bundle_id..."
xcrun simctl launch booted "$bundle_id"
open -a Simulator
