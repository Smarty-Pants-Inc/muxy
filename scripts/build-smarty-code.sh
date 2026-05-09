#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_ROOT="$PROJECT_ROOT/build/smarty-code"
CHANNEL=""
INSTALL=0
QUIT_RUNNING=0
INSTALL_DIR="/Applications"
SIGN_IDENTITY="-"
SENTRY_DSN="${SENTRY_DSN:-}"
STABLE_FEED_URL="${SMARTY_CODE_STABLE_FEED_URL:-}"
BETA_FEED_URL="${SMARTY_CODE_BETA_FEED_URL:-}"
VERSION="${SMARTY_CODE_VERSION:-0.1.0}"
ARCH="$(uname -m)"

usage() {
    cat <<USAGE
Usage: $0 --channel <stable|dev> [--install] [--install-dir <dir>] [--quit-running] [--sign-identity <identity>] [--no-sign] [--version <x.y.z>] [--stable-feed-url <url>] [--beta-feed-url <url>] [--sentry-dsn <dsn>]
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --channel)
            CHANNEL="$2"
            shift 2
            ;;
        --install)
            INSTALL=1
            shift
            ;;
        --install-dir)
            INSTALL_DIR="$2"
            shift 2
            ;;
        --quit-running)
            QUIT_RUNNING=1
            shift
            ;;
        --sign-identity)
            SIGN_IDENTITY="$2"
            shift 2
            ;;
        --no-sign)
            SIGN_IDENTITY=""
            shift
            ;;
        --version)
            VERSION="$2"
            shift 2
            ;;
        --stable-feed-url)
            STABLE_FEED_URL="$2"
            shift 2
            ;;
        --beta-feed-url)
            BETA_FEED_URL="$2"
            shift 2
            ;;
        --sentry-dsn)
            SENTRY_DSN="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

if [[ "$CHANNEL" != "stable" && "$CHANNEL" != "dev" ]]; then
    usage >&2
    exit 1
fi

if [[ "$ARCH" != "arm64" && "$ARCH" != "x86_64" ]]; then
    echo "Unsupported architecture: $ARCH" >&2
    exit 1
fi

if [[ "$CHANNEL" == "stable" ]]; then
    APP_NAME="Smarty Code"
    BUNDLE_ID="com.smartypants.smarty-code"
    APP_SUPPORT_NAME="Smarty Code"
    URL_SCHEME="smarty-code"
    SOCKET_NAME="smarty-code.sock"
    CLI_COMMAND="smarty-code"
    SENTRY_ENVIRONMENT="smarty-code"
else
    APP_NAME="Smarty Code Dev"
    BUNDLE_ID="com.smartypants.smarty-code.dev"
    APP_SUPPORT_NAME="Smarty Code Dev"
    URL_SCHEME="smarty-code-dev"
    SOCKET_NAME="smarty-code-dev.sock"
    CLI_COMMAND="smarty-code-dev"
    SENTRY_ENVIRONMENT="smarty-code-dev"
fi

TRIPLE="${ARCH}-apple-macosx14.0"
BUILD_NUMBER="$(git -C "$PROJECT_ROOT" rev-list --count HEAD)"
APP_BUNDLE="$BUILD_ROOT/$CHANNEL/${APP_NAME}.app"
APP_PLIST="$APP_BUNDLE/Contents/Info.plist"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
SPARKLE_FRAMEWORK="$PROJECT_ROOT/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"

plist_value() {
    local type="$1"
    local value="$2"
    if [[ "$type" == "bool" || "$type" == "integer" || "$type" == "real" ]]; then
        printf '%s' "$value"
        return
    fi
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    printf '"%s"' "$value"
}

plist_set() {
    local key="$1"
    local type="$2"
    local value="$3"
    local encoded
    encoded="$(plist_value "$type" "$value")"
    if /usr/libexec/PlistBuddy -c "Print :$key" "$APP_PLIST" >/dev/null 2>&1; then
        /usr/libexec/PlistBuddy -c "Set :$key $encoded" "$APP_PLIST"
    else
        /usr/libexec/PlistBuddy -c "Add :$key $type $encoded" "$APP_PLIST"
    fi
}
plist_delete_if_present() {
    local key="$1"
    /usr/libexec/PlistBuddy -c "Delete :$key" "$APP_PLIST" >/dev/null 2>&1 || true
}

replace_privacy_name() {
    local key="$1"
    local current
    current="$(/usr/libexec/PlistBuddy -c "Print :$key" "$APP_PLIST" 2>/dev/null || true)"
    [[ -n "$current" ]] || return 0
    local needle
    local replacement
    needle="A process running in Muxy"
    needle="${needle}'s terminal"
    replacement="A process running inside $APP_NAME"
    current="${current//$needle/$replacement}"
    local encoded
    encoded="$(plist_value string "$current")"
    /usr/libexec/PlistBuddy -c "Set :$key $encoded" "$APP_PLIST"
}

patch_cli() {
    local script_path="$1"
    /usr/bin/python3 - "$script_path" "$APP_NAME" "$CLI_COMMAND" "$URL_SCHEME" "$BUNDLE_ID" "$APP_SUPPORT_NAME" "$SOCKET_NAME" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
values = {
    "APP_NAME": sys.argv[2],
    "CLI_COMMAND": sys.argv[3],
    "URL_SCHEME": sys.argv[4],
    "BUNDLE_ID": sys.argv[5],
    "APP_SUPPORT_NAME": sys.argv[6],
    "SOCKET_NAME": sys.argv[7],
}
text = path.read_text()
for key, value in values.items():
    text = text.replace(f'{key}="Muxy"', f'{key}="{value}"')
    text = text.replace(f'{key}="muxy"', f'{key}="{value}"')
    text = text.replace(f'{key}="com.muxy.app"', f'{key}="{value}"')
    text = text.replace(f'{key}="muxy.sock"', f'{key}="{value}"')
path.write_text(text)
PY
    chmod +x "$script_path"
}

safe_install() {
    local target="$INSTALL_DIR/${APP_NAME}.app"
    mkdir -p "$INSTALL_DIR"
    if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
        if [[ "$QUIT_RUNNING" -ne 1 ]]; then
            echo "$APP_NAME is running. Quit it first or pass --quit-running." >&2
            exit 1
        fi
        osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
        for _ in {1..30}; do
            pgrep -x "$APP_NAME" >/dev/null 2>&1 || break
            sleep 1
        done
        if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
            echo "$APP_NAME did not quit; refusing to overwrite $target" >&2
            exit 1
        fi
    fi
    if [[ -e "$target" ]]; then
        local backup="$target.previous.$(date +%Y%m%d%H%M%S)"
        mv "$target" "$backup"
        echo "Previous app moved to: $backup"
    fi
    ditto "$APP_BUNDLE" "$target"
    echo "Installed: $target"
}

echo "==> Building $APP_NAME for $ARCH ($TRIPLE)"
cd "$PROJECT_ROOT"
swift build -c release --triple "$TRIPLE"
SPM_BUILD_DIR="$(swift build -c release --triple "$TRIPLE" --show-bin-path)"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources" "$APP_BUNDLE/Contents/Frameworks"
cp "$SPM_BUILD_DIR/Muxy" "$APP_BINARY"
install_name_tool -add_rpath @executable_path/../Frameworks "$APP_BINARY" 2>/dev/null || true
strip -Sx "$APP_BINARY" 2>/dev/null || true

if [[ -d "$SPM_BUILD_DIR/Muxy_Muxy.bundle" ]]; then
    cp -R "$SPM_BUILD_DIR/Muxy_Muxy.bundle" "$APP_BUNDLE/Contents/Resources/Muxy_Muxy.bundle"
fi

cp "$PROJECT_ROOT/Muxy/Info.plist" "$APP_PLIST"
plist_set CFBundleIdentifier string "$BUNDLE_ID"
plist_set CFBundleName string "$APP_NAME"
plist_set CFBundleDisplayName string "$APP_NAME"
plist_set CFBundleExecutable string "$APP_NAME"
plist_set CFBundleShortVersionString string "$VERSION"
plist_set CFBundleVersion string "$BUILD_NUMBER"
plist_set MuxyApplicationSupportName string "$APP_SUPPORT_NAME"
plist_set MuxyURLScheme string "$URL_SCHEME"
plist_set MuxySocketName string "$SOCKET_NAME"
plist_set MuxyCLICommandName string "$CLI_COMMAND"
plist_set SentryEnvironment string "$SENTRY_ENVIRONMENT"
plist_set SUEnableAutomaticChecks bool false
/usr/libexec/PlistBuddy -c "Set :CFBundleURLTypes:0:CFBundleURLName $(plist_value string "$BUNDLE_ID")" "$APP_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleURLTypes:0:CFBundleURLSchemes:0 $(plist_value string "$URL_SCHEME")" "$APP_PLIST"

if [[ -n "$SENTRY_DSN" ]]; then
    plist_set SentryDSN string "$SENTRY_DSN"
fi

plist_delete_if_present MuxyStableFeedURL
plist_delete_if_present MuxyBetaFeedURL
if [[ -n "$STABLE_FEED_URL" ]]; then
    plist_set MuxyStableFeedURL string "$STABLE_FEED_URL"
fi
if [[ -n "$BETA_FEED_URL" ]]; then
    plist_set MuxyBetaFeedURL string "$BETA_FEED_URL"
fi
if [[ -n "$STABLE_FEED_URL" || -n "$BETA_FEED_URL" ]]; then
    plist_set SUEnableAutomaticChecks bool true
fi

for key in NSAppleEventsUsageDescription NSBluetoothAlwaysUsageDescription NSCalendarsUsageDescription NSCameraUsageDescription NSContactsUsageDescription NSLocalNetworkUsageDescription NSLocationUsageDescription NSMicrophoneUsageDescription NSMotionUsageDescription NSPhotoLibraryUsageDescription NSRemindersUsageDescription NSSpeechRecognitionUsageDescription NSSystemAdministrationUsageDescription; do
    replace_privacy_name "$key"
done

"$SCRIPT_DIR/create-icns.sh" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

if [[ ! -d "$SPARKLE_FRAMEWORK" ]]; then
    echo "Sparkle.framework not found at $SPARKLE_FRAMEWORK" >&2
    exit 1
fi
cp -R "$SPARKLE_FRAMEWORK" "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"

while IFS= read -r -d '' cli_script; do
    patch_cli "$cli_script"
done < <(find "$APP_BUNDLE/Contents/Resources" -type f -name muxy-cli -print0)

if [[ -n "$SIGN_IDENTITY" ]]; then
    SPARKLE_DIR="$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
    for nested in \
        "$SPARKLE_DIR/Versions/B/XPCServices/Installer.xpc" \
        "$SPARKLE_DIR/Versions/B/XPCServices/Downloader.xpc" \
        "$SPARKLE_DIR/Versions/B/Updater.app" \
        "$SPARKLE_DIR/Versions/B/Autoupdate" \
        "$SPARKLE_DIR"; do
        if [[ -e "$nested" ]]; then
            /usr/bin/codesign --force --options runtime --sign "$SIGN_IDENTITY" "$nested"
        fi
    done
    while IFS= read -r -d '' binary; do
        if file "$binary" | grep -q "Mach-O"; then
            /usr/bin/codesign --force --options runtime --sign "$SIGN_IDENTITY" "$binary"
        fi
    done < <(find "$APP_BUNDLE/Contents/Resources" -type f -perm -u+x -print0)
    /usr/bin/codesign --force --options runtime --entitlements "$PROJECT_ROOT/Muxy/Muxy.entitlements" --sign "$SIGN_IDENTITY" "$APP_BUNDLE"
fi

if [[ -n "$SIGN_IDENTITY" ]]; then
    codesign --verify --deep --strict "$APP_BUNDLE"
fi

if [[ "$INSTALL" -eq 1 ]]; then
    safe_install
fi

echo "Built: $APP_BUNDLE"
echo "Bundle ID: $BUNDLE_ID"
echo "State: ~/Library/Application Support/$APP_SUPPORT_NAME"
echo "URL scheme: $URL_SCHEME"
echo "Socket: ~/Library/Application Support/$APP_SUPPORT_NAME/$SOCKET_NAME"
echo "CLI command: $CLI_COMMAND"
