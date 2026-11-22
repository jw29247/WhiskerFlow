#!/usr/bin/env bash
# Fails when app code sets a raw font size (.system(size: 13)) instead of a
# FlowStyle text style (FlowStyle.body, FlowStyle.caption.weight(.medium) …;
# see Sources/WhiskerFlow/Views/FlowStyle.swift). Raw sizes let hierarchy drift
# between screens and let unreadably small text back in.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCES="${TYPE_SCALE_SOURCES:-$ROOT_DIR/Sources/WhiskerFlow}"

PATTERN='\.system\(size:|systemFont\(ofSize:'

# Sizes that are not text, as "<file>:<text on the line>". Add an entry only
# with a comment saying why a text style would be wrong.
ALLOWED=(
  # The type scale itself.
  "Views/FlowStyle.swift:.system(size: style.size, weight: style.weight, design: style.design)"
  # A key cap drawn as a key: sized to its cap, not to the text around it.
  "Views/FlowStyle.swift:.font(.system(size: compact ? 12 : 21, weight: .medium, design: .rounded))"
  # SF Symbols sized as icons. Their size is the icon's size, not a text level.
  "Views/FlowStyle.swift:Image(systemName: symbol).font(.system(size: 30, weight: .light))"
  "Views/OnboardingView.swift:Image(systemName: symbol).font(.system(size: 30, weight: .light))"
  "Views/OnboardingView.swift:Image(systemName: \"checkmark\").font(.system(size: 8, weight: .bold))"
  "Views/AtlasSignInGate.swift:.font(.system(size: 46, weight: .light))"
  "Views/MeetingsView.swift:Image(systemName: \"calendar.badge.plus\").font(.system(size: 32, weight: .light))"
  "Views/MeetingsView.swift:Image(systemName: \"record.circle.fill\").font(.system(size: 28))"
  "Views/CallPromptHUD.swift:.font(.system(size: 22)).foregroundStyle(FlowStyle.recording)"
  "Views/OnboardingSteps.swift:Image(systemName: symbol).font(.system(size: 20))"
  "Views/LeaderboardView.swift:.font(.system(size: 18))"
  "Views/MeetingRecordingReminderView.swift:.font(.system(size: 16)).foregroundStyle(copied ? FlowStyle.accent : FlowStyle.recording)"
  "Views/RecordingHUD.swift:.font(.system(size: 16, weight: .semibold))"
  "Views/MeetingLibraryView.swift:Image(systemName: \"chevron.left\").font(.system(size: 15, weight: .semibold))"
)

# Prints each raw font size under $1 that is not allowed; fails if there is one.
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
      echo "FAIL: raw font size at ${file#"$ROOT_DIR"/}:$line — use a FlowStyle text style" >&2
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
printf 'Text("x").font(.system(size: 13, weight: .medium))\n' > "$FIXTURE/Views/Fixture.swift"
if scan "$FIXTURE" 2>/dev/null; then
  echo "FAIL: the raw font size check missed its fixture" >&2
  exit 1
fi

if ! scan "$SOURCES"; then
  echo "Raw font sizes found; see above." >&2
  exit 1
fi
echo "No raw font sizes."
