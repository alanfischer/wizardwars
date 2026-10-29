#!/usr/bin/env bash
set -euo pipefail

USERDATA_DIR="$HOME/Library/Application Support/Godot/app_userdata/Wizard Wars"

: > "$USERDATA_DIR/client.log"
: > "$USERDATA_DIR/server.log"

echo "Cleared client.log and server.log"
