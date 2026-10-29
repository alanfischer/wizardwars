#!/usr/bin/env bash
set -euo pipefail

# WizardWars Launcher — checks for updates and runs the game.
#
# release.sh fills in DEFAULT_SERVER_URL on the copy it ships. To point at another server:
#   WW_UPDATE_SERVER=http://192.168.1.5:8080 ./launcher.sh

DEFAULT_SERVER_URL=""
SERVER_URL="${WW_UPDATE_SERVER:-$DEFAULT_SERVER_URL}"
if [ -z "$SERVER_URL" ]; then
    echo "No server set. Run: WW_UPDATE_SERVER=http://<host>:8080 ./launcher.sh" >&2
    exit 1
fi

LAUNCHER_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="$LAUNCHER_DIR/WizardWars"
VERSION_FILE="$INSTALL_DIR/version.txt"

echo "WizardWars Launcher"
echo "==================="
echo "Server: $SERVER_URL"

# --- Check for updates ---
mkdir -p "$INSTALL_DIR"

REMOTE_VERSION=$(curl -sf "$SERVER_URL/version.txt" 2>/dev/null || echo "")
if [ -z "$REMOTE_VERSION" ]; then
    echo "Warning: Can't reach server. Launching cached version if available."
else
    LOCAL_VERSION=""
    if [ -f "$VERSION_FILE" ]; then
        LOCAL_VERSION="$(cat "$VERSION_FILE")"
    fi

    if [ "$REMOTE_VERSION" != "$LOCAL_VERSION" ]; then
        echo "Update available: ${LOCAL_VERSION:-none} -> $REMOTE_VERSION"
        echo "Downloading..."

        case "$(uname -s)" in
            Darwin) PLATFORM="mac" ;;
            Linux)  PLATFORM="linux" ;;
            *)      echo "Unsupported platform: $(uname -s)"; exit 1 ;;
        esac

        ZIP_NAME="WizardWars-${PLATFORM}.zip"
        TEMP_ZIP="$INSTALL_DIR/$ZIP_NAME"

        curl -f --progress-bar -o "$TEMP_ZIP" "$SERVER_URL/$ZIP_NAME"

        echo "Extracting..."
        find "$INSTALL_DIR" -mindepth 1 -not -name "$ZIP_NAME" -not -name "version.txt" -delete 2>/dev/null || true
        unzip -qo "$TEMP_ZIP" -d "$INSTALL_DIR"
        rm -f "$TEMP_ZIP"

        echo "$REMOTE_VERSION" > "$VERSION_FILE"

        if [ "$PLATFORM" = "mac" ] && [ -d "$INSTALL_DIR/WizardWars.app" ]; then
            xattr -cr "$INSTALL_DIR/WizardWars.app" 2>/dev/null || true
            chmod +x "$INSTALL_DIR/WizardWars.app/Contents/MacOS/"* 2>/dev/null || true
            echo "Gatekeeper cleared."
        fi

        if [ "$PLATFORM" = "linux" ] && [ -f "$INSTALL_DIR/WizardWars.x86_64" ]; then
            chmod +x "$INSTALL_DIR/WizardWars.x86_64"
        fi

        echo "Updated to $REMOTE_VERSION!"
    else
        echo "Up to date ($LOCAL_VERSION)"
    fi

    # Legacy: releases used to be patchable with a small patch.pck dropped next to
    # the executable. That is gone — clear one an older launcher may have installed.
    case "$(uname -s)" in
        Darwin) rm -f "$INSTALL_DIR/WizardWars.app/Contents/MacOS/patch.pck" ;;
        Linux)  rm -f "$INSTALL_DIR/patch.pck" ;;
    esac
    rm -f "$INSTALL_DIR/patch.txt"
fi

# --- Launch ---
echo "Launching WizardWars..."
echo ""

case "$(uname -s)" in
    Darwin)
        if [ -d "$INSTALL_DIR/WizardWars.app" ]; then
            open "$INSTALL_DIR/WizardWars.app"
        else
            echo "Error: WizardWars.app not found in $INSTALL_DIR"
            exit 1
        fi
        ;;
    Linux)
        if [ -f "$INSTALL_DIR/WizardWars.x86_64" ]; then
            "$INSTALL_DIR/WizardWars.x86_64" &
        else
            echo "Error: WizardWars.x86_64 not found in $INSTALL_DIR"
            exit 1
        fi
        ;;
esac
