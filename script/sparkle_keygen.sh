#!/usr/bin/env bash
#
# One-time setup for Sparkle auto-updates.
#
# Generates the EdDSA signing key (stored in your login Keychain) and writes the
# matching PUBLIC key into Resources/Info.plist (SUPublicEDKey). The PRIVATE key
# never leaves your Keychain; sign_update reads it from there at release time.
#
# Run once per signing machine. Re-running is safe — it reuses the existing key.
#
#   script/sparkle_keygen.sh
#
# Back up the private key (so you don't lose the ability to ship updates) with:
#   .build/artifacts/sparkle/Sparkle/bin/generate_keys -x sparkle_private_key.txt
# Store that file somewhere safe and OUT of git.
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INFO_PLIST="$ROOT_DIR/Resources/Info.plist"
TOOLS_DIR="$ROOT_DIR/.build/artifacts/sparkle/Sparkle/bin"
GENERATE_KEYS="$TOOLS_DIR/generate_keys"

if [[ ! -x "$GENERATE_KEYS" ]]; then
  echo "==> Resolving Sparkle to fetch its tools…"
  (cd "$ROOT_DIR" && swift package resolve >/dev/null)
fi
[[ -x "$GENERATE_KEYS" ]] || { echo "ERROR: generate_keys not found at $GENERATE_KEYS" >&2; exit 1; }

# Reuse the existing key if there is one (-p just prints its public key);
# otherwise create one, then read it back. The Keychain may prompt for access —
# click "Allow".
if ! PUBLIC_KEY="$("$GENERATE_KEYS" -p 2>/dev/null)"; then
  echo "==> No existing Sparkle key — generating one (saved to your login Keychain)…"
  "$GENERATE_KEYS" >/dev/null
  PUBLIC_KEY="$("$GENERATE_KEYS" -p)"
fi

PUBLIC_KEY="$(printf '%s' "$PUBLIC_KEY" | tr -d '[:space:]')"
[[ -n "$PUBLIC_KEY" ]] || { echo "ERROR: could not read the public key from the Keychain." >&2; exit 1; }

/usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $PUBLIC_KEY" "$INFO_PLIST"

cat <<MSG
==> Done.
    SUPublicEDKey = $PUBLIC_KEY  (written to Resources/Info.plist)

Next:
  • Commit the updated Info.plist.
  • Back up the private key now and keep it safe (out of git):
      $GENERATE_KEYS -x sparkle_private_key.txt
MSG
