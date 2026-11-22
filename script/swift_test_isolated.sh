#!/usr/bin/env bash
# Runs `swift test` with the user's WhiskerFlow data, Keychain, Contacts,
# privacy prompts and the network out of reach, for a developer's own Mac.
#
#   script/swift_test_isolated.sh [swift test arguments, e.g. --filter X]
#
# The tests already use temporary folders and fakes. This guards against what
# they cannot control: loading the app's test bundle makes XCTest realise every
# Objective-C class, and macOS's ContactsUICore (pulled in by Translation's
# SwiftUI support) then opens the address book. Not used in CI.
set -euo pipefail

cd "$(dirname "$0")/.."

profile="$(mktemp -t wf-test-sandbox)"
trap 'rm -f "$profile"' EXIT
cat > "$profile" <<'EOF'
(version 1)
(allow default)
(deny file-read* file-write*
  (subpath (string-append (param "HOME") "/Library/Application Support/WhiskerFlow"))
  (subpath (string-append (param "HOME") "/Library/Logs/WhiskerFlow"))
  (subpath (string-append (param "HOME") "/Library/Application Support/AddressBook"))
  (subpath (string-append (param "HOME") "/Library/Keychains"))
  (literal (string-append (param "HOME") "/Library/Preferences/agency.thatworks.WhiskerFlow.plist")))
(deny mach-lookup
  (global-name "com.apple.tccd")
  (global-name "com.apple.tccd.system")
  (global-name "com.apple.SecurityServer")
  (global-name "com.apple.securityd.xpc")
  (global-name "com.apple.contactsd")
  (global-name "com.apple.contactsd.persistence")
  (global-name "com.apple.AddressBook.ContactsAccountsService")
  (global-name "com.apple.AddressBook.abd")
  (global-name "com.apple.dnssd.service"))
(deny network-outbound (remote ip "*:*"))
(allow network-outbound (remote ip "localhost:*"))
EOF

# SwiftPM cannot nest its own manifest sandbox inside this one.
exec sandbox-exec -D HOME="$HOME" -f "$profile" swift test --disable-sandbox "$@"
