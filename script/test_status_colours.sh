#!/usr/bin/env bash
# Fails when app code uses a raw system colour (.orange, Color.green,
# NSColor.systemRed, a literal Color(red:…)) instead of a FlowStyle token.
# System orange, green and yellow are about 2:1 or less against the light
# canvas, so status text drawn in them can't be read. Use FlowStyle.danger,
# .warning, .success or .recording (see Sources/WhiskerFlow/Views/FlowStyle.swift).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCES="${STATUS_COLOUR_SOURCES:-$ROOT_DIR/Sources/WhiskerFlow}"

HUES='red|orange|yellow|green|mint|teal|cyan|blue|indigo|purple|pink|brown|gray|grey'
PATTERN="(^|[^A-Za-z0-9_])(Color)?\.($HUES)([^A-Za-z0-9_]|$)|NSColor\.system[A-Z]|Color\((red|hue|white):"

# Decorative uses that carry no status, as "<file>:<text on the line>".
# Add an entry only with a comment saying why the colour isn't a status.
ALLOWED=(
  # Gold, silver and bronze medals for the top three; the rank is also spoken.
  "Views/LeaderboardView.swift:[Color.yellow, Color.gray, Color.orange]"
  # A faint highlighter behind search matches in a meeting transcript.
  "Views/MeetingLibraryView.swift:Color.yellow.opacity(0.16)"
)

# Prints each raw colour under $1 that is not allowed; fails if there is one.
scan() {
  local root=$1 failures=0 match file rest line text trimmed relative allowed entry
  while IFS= read -r match; do
    file="${match%%:*}"
    rest="${match#*:}"
    line="${rest%%:*}"
    text="${rest#*:}"
    trimmed="${text#"${text%%[![:space:]]*}"}"
    [[ "$trimmed" == //* ]] && continue
    relative="${file#"$root"/}"
    allowed=0
    for entry in "${ALLOWED[@]}"; do
      if [[ "$relative" == "${entry%%:*}" && "$text" == *"${entry#*:}"* ]]; then allowed=1; break; fi
    done
    if [[ $allowed == 0 ]]; then
      echo "FAIL: raw system colour at ${file#"$ROOT_DIR"/}:$line — use a FlowStyle token" >&2
      echo "    $trimmed" >&2
      failures=$((failures + 1))
    fi
  done < <(grep -rnE --include='*.swift' "$PATTERN" "$root" || true)
  [[ $failures == 0 ]]
}

# The check must still catch a known offender.
FIXTURE="$(mktemp -d)"
trap 'rm -rf "$FIXTURE"' EXIT
mkdir -p "$FIXTURE/Views"
printf 'Text("x").foregroundStyle(.orange)\n.stroke(Color.green)\n' > "$FIXTURE/Views/Fixture.swift"
if scan "$FIXTURE" 2>/dev/null; then
  echo "FAIL: the raw colour check missed its fixture" >&2
  exit 1
fi

if ! scan "$SOURCES"; then
  echo "Raw status colours found; see above." >&2
  exit 1
fi
echo "No raw status colours."
