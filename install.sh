#!/usr/bin/env bash
# install.sh — install dont-stop on this machine.
#
# Does four things, all idempotent:
#   1. creates ~/.claude/dont-stop.json with the defaults (if missing)
#   2. registers the marketplace in ~/.claude/settings.json
#   3. wraps statusLine so rate_limits get cached (free usage, no network);
#      any statusLine you already had is preserved as statuslineDelegate
#   4. runs `claude plugin install`
#
# settings.json is always backed up before being touched.
# --dry-run shows the diff and writes nothing.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETTINGS="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"
CFG="${CLAUDE_DONT_STOP_CONFIG:-$HOME/.claude/dont-stop.json}"
DRY=0; [[ "${1:-}" == "--dry-run" ]] && DRY=1

command -v jq >/dev/null || { echo "ERROR: jq is required (apt install jq)" >&2; exit 1; }
command -v curl >/dev/null || { echo "ERROR: curl is required" >&2; exit 1; }
chmod +x "$HERE"/bin/* 2>/dev/null || true
mkdir -p "$(dirname "$SETTINGS")"
[[ -f "$SETTINGS" ]] || echo '{}' > "$SETTINGS"

# --- 1. config -----------------------------------------------------------------
if [[ ! -f "$CFG" ]] && (( DRY )); then
  echo "(--dry-run) would create $CFG with the default values"
elif [[ ! -f "$CFG" ]]; then
  cat > "$CFG" <<'EOF'
{
  "enabled": true,
  "threshold": 95,
  "injectOnPrompt": true,
  "maxSleepSecs": 21600,
  "weeklyMaxWaitSecs": 28800,
  "graceSecs": 60
}
EOF
  echo "created $CFG"
else
  echo "$CFG already exists, leaving it alone"
fi

# --- 2 and 3. settings.json ----------------------------------------------------
NEW=$(jq \
  --arg root "$HERE" \
  --arg sl "$HERE/bin/dont-stop-statusline" '
  # Local marketplace (the plugin itself is installed separately, with
  # `claude plugin install`: setting enabledPlugins by hand is NOT enough,
  # it has to be installed once)
  .extraKnownMarketplaces["claude-dont-stop"] = { source: { source: "directory", path: $root } }

  # statusLine: wrap whatever was there, without clobbering it or double-wrapping
  | if (.statusLine.command // "") == $sl then .
    else
      ( if (.statusLine.command // "") == "" then .
        else .["_dontStopPrevStatusLine"] = .statusLine.command end )
      | .statusLine = { type: "command", command: $sl }
    end
  ' "$SETTINGS")

# The delegate lives in dont-stop.json, not in settings.json.
PREV=$(jq -r '.["_dontStopPrevStatusLine"] // empty' <<<"$NEW")
NEW=$(jq 'del(.["_dontStopPrevStatusLine"])' <<<"$NEW")

echo
echo "--- diff of $SETTINGS ---"
diff <(jq -S . "$SETTINGS") <(jq -S . <<<"$NEW") || true
echo "-------------------------"

if (( DRY )); then echo "(--dry-run: nothing was written)"; exit 0; fi

BAK="$SETTINGS.bak.$(date +%Y%m%d%H%M%S)"
cp "$SETTINGS" "$BAK"; echo "backup: $BAK"
printf '%s\n' "$NEW" > "$SETTINGS"

if [[ -n "$PREV" ]]; then
  tmp=$(mktemp); jq --arg d "$PREV" '.statuslineDelegate = $d' "$CFG" > "$tmp" && mv "$tmp" "$CFG"
  echo "previous statusLine preserved as statuslineDelegate: $PREV"
fi

# --- 4. install the plugin -----------------------------------------------------
# NOTE: `claude plugin install` COPIES the plugin into ~/.claude/plugins/cache.
# Changes you make in this repo are not picked up until you reinstall.
echo
# The marketplace has to be registered through the CLI: writing it into
# extraKnownMarketplaces is not enough for an already-running process (it reads
# that at startup), and `plugin install` would fail with "not found in marketplace".
claude plugin marketplace add "$HERE" 2>/dev/null \
  || claude plugin marketplace update claude-dont-stop 2>/dev/null \
  || true

if claude plugin list 2>/dev/null | grep -q "dont-stop@claude-dont-stop"; then
  echo "plugin already installed, reinstalling to pick up changes"
  claude plugin uninstall dont-stop@claude-dont-stop >/dev/null 2>&1 || true
fi
claude plugin install dont-stop@claude-dont-stop || {
  echo "ERROR: 'claude plugin install' failed. Install it by hand with:" >&2
  echo "  claude plugin install dont-stop@claude-dont-stop" >&2; exit 1; }

echo
claude plugin list 2>/dev/null | grep -A3 dont-stop || true
echo
echo "Done. Restart Claude Code so open sessions load the plugin."
echo "Check with:  $HERE/bin/dont-stop-ctl status"
