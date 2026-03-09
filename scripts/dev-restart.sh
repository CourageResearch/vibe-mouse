#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
if [[ -n "${VIBE_MOUSE_APP_PATH:-}" ]]; then
  APP_PATH="$VIBE_MOUSE_APP_PATH"
elif [[ -d "/Applications/Vibe Mouse.app" ]]; then
  APP_PATH="/Applications/Vibe Mouse.app"
elif [[ -d "/Applications/Mouse Chord Shot.app" ]]; then
  APP_PATH="/Applications/Mouse Chord Shot.app"
else
  APP_PATH="/Applications/Vibe Mouse.app"
fi
APP_BIN="$APP_PATH/Contents/MacOS/mouse"
APP_INFO_PLIST="$APP_PATH/Contents/Info.plist"
BUILD_BIN="$REPO_ROOT/.build/debug/vibe-mouse"
SIGNING_DIR="$HOME/.vibe-mouse-signing"
KEYCHAIN_PATH="$SIGNING_DIR/vibe-dev.keychain-db"
KEYCHAIN_PASS_FILE="$SIGNING_DIR/keychain.pass"
SIGNING_IDENTITY="Vibe Mouse Local Dev"
APP_BUNDLE_ID=""

ensure_keychain_in_search_list() {
  local existing_keychains=()
  while IFS= read -r keychain_line; do
    keychain_line="${keychain_line#"${keychain_line%%[![:space:]]*}"}"
    keychain_line="${keychain_line%\"}"
    keychain_line="${keychain_line#\"}"
    if [[ -n "$keychain_line" ]]; then
      existing_keychains+=("$keychain_line")
    fi
  done < <(security list-keychains -d user)

  local found=0
  local keychain
  for keychain in "${existing_keychains[@]}"; do
    if [[ "$keychain" == "$KEYCHAIN_PATH" ]]; then
      found=1
      break
    fi
  done
  if [[ "$found" -eq 0 ]]; then
    security list-keychains -d user -s "$KEYCHAIN_PATH" "${existing_keychains[@]}"
  fi
}

signing_identity_hash() {
  security find-identity -v -p codesigning "$KEYCHAIN_PATH" \
    | awk -v identity="$SIGNING_IDENTITY" '$0 ~ identity { print $2; exit }'
}

ensure_signing_identity() {
  mkdir -p "$SIGNING_DIR"

  if [[ ! -f "$KEYCHAIN_PASS_FILE" ]]; then
    openssl rand -hex 24 > "$KEYCHAIN_PASS_FILE"
    chmod 600 "$KEYCHAIN_PASS_FILE"
  fi
  local keychain_pass
  keychain_pass="$(cat "$KEYCHAIN_PASS_FILE")"

  if [[ ! -f "$KEYCHAIN_PATH" ]]; then
    security create-keychain -p "$keychain_pass" "$KEYCHAIN_PATH" >/dev/null
    security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH" >/dev/null
  fi
  security unlock-keychain -p "$keychain_pass" "$KEYCHAIN_PATH" >/dev/null
  ensure_keychain_in_search_list

  if security find-identity -v -p codesigning "$KEYCHAIN_PATH" | grep -q "$SIGNING_IDENTITY"; then
    return
  fi

  local tmp_dir
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' RETURN

  cat > "$tmp_dir/openssl.cnf" <<'EOF'
[ req ]
distinguished_name = dn
x509_extensions = v3_req
prompt = no

[ dn ]
CN = Vibe Mouse Local Dev
O = Local Development
C = US

[ v3_req ]
keyUsage = critical, digitalSignature
extendedKeyUsage = codeSigning
basicConstraints = critical, CA:FALSE
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
EOF

  openssl req -newkey rsa:2048 -nodes \
    -keyout "$tmp_dir/key.pem" \
    -x509 -days 3650 \
    -out "$tmp_dir/cert.pem" \
    -config "$tmp_dir/openssl.cnf" >/dev/null 2>&1
  openssl pkcs12 -export \
    -out "$tmp_dir/signing.p12" \
    -inkey "$tmp_dir/key.pem" \
    -in "$tmp_dir/cert.pem" \
    -name "$SIGNING_IDENTITY" \
    -passout pass:codex >/dev/null 2>&1

  security import "$tmp_dir/signing.p12" \
    -k "$KEYCHAIN_PATH" \
    -P "codex" \
    -T /usr/bin/codesign \
    -T /usr/bin/security >/dev/null
  security add-trusted-cert -d -k "$KEYCHAIN_PATH" -p codeSign "$tmp_dir/cert.pem" >/dev/null
  security set-key-partition-list -S apple-tool:,apple: -s -k "$keychain_pass" "$KEYCHAIN_PATH" >/dev/null
  ensure_keychain_in_search_list
}

if [[ ! -d "$APP_PATH" ]]; then
  echo "error: $APP_PATH not found"
  exit 1
fi
APP_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP_INFO_PLIST" 2>/dev/null || true)"

cd "$REPO_ROOT"
ensure_signing_identity

echo "Building..."
swift build

echo "Updating app binary..."
cp "$BUILD_BIN" "$APP_BIN"
chmod +x "$APP_BIN"

echo "Updating build number..."
BUILD_NUMBER="$(date +%Y%m%d%H%M%S)"
if /usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP_INFO_PLIST" >/dev/null 2>&1; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP_INFO_PLIST"
else
  /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $BUILD_NUMBER" "$APP_INFO_PLIST"
fi

echo "Signing app..."
SIGNING_HASH="$(signing_identity_hash)"
if [[ -z "$SIGNING_HASH" ]]; then
  echo "error: could not find signing identity '$SIGNING_IDENTITY' in $KEYCHAIN_PATH"
  exit 1
fi
codesign --force --deep --sign "$SIGNING_HASH" --keychain "$KEYCHAIN_PATH" "$APP_PATH"

echo "Restarting app..."
if [[ -n "$APP_BUNDLE_ID" ]]; then
  osascript -e "tell application id \"$APP_BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
fi
sleep 1
pkill -f "$APP_BIN" || true
open "$APP_PATH"
sleep 1

echo "App version:"
/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_INFO_PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP_INFO_PLIST" 2>/dev/null || true

echo "Designated requirement:"
codesign -d -r- "$APP_PATH" 2>&1 | sed -n 's/^designated => /  /p'

echo "Running process:"
pgrep -fal "$APP_BIN" || {
  echo "error: app did not start"
  exit 1
}
