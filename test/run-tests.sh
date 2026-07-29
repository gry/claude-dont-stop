#!/usr/bin/env bash
# dont-stop tests. Fully isolated: a temporary XDG_CACHE_HOME and config are
# used, the rate_limits cache is seeded by hand, and the network is NEVER touched
# (--cache-only everywhere usage is read), so this can be run in a loop without
# tripping the endpoint's rate limit.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$HERE/bin"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export XDG_CACHE_HOME="$TMP/cache"
export CLAUDE_DONT_STOP_CONFIG="$TMP/dont-stop.json"
export CLAUDE_DONT_STOP_USAGE_BIN="$BIN/claude-usage"
export CLAUDE_DONT_STOP_POSTCHECK_FLAGS="--cache-only"   # zero network in tests
DS="$XDG_CACHE_HOME/claude-dont-stop"
mkdir -p "$DS"
unset CLAUDE_DONT_STOP CLAUDE_DONT_STOP_THRESHOLD

PASS=0; FAIL=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n'   "$1"; printf '        %s\n' "$2"; FAIL=$((FAIL+1)); }
check(){ [[ "$2" == "$3" ]] && ok "$1" || bad "$1" "expected '$3', got '$2'"; }
has()  { grep -q -- "$3" <<<"$2" && ok "$1" || bad "$1" "could not find '$3' in: $2"; }

# seed <five_pct> <five_in_secs> <week_pct> <week_in_secs>
seed() {
  local now; now=$(date +%s)
  jq -nc --argjson f "$1" --argjson fr "$(( now + $2 ))" \
         --argjson w "$3" --argjson wr "$(( now + $4 ))" \
    '{five_pct:$f, five_reset:$fr, week_pct:$w, week_reset:$wr, written_by:"test"}' \
    > "$DS/rate_limits.json"
}
cfg() { jq -nc "$1" > "$CLAUDE_DONT_STOP_CONFIG"; }
run_gate_hook() { printf '%s' "$1" | "$BIN/dont-stop-gate"; }

echo "== claude-usage --gate: exit codes =="
cfg '{enabled:true, threshold:95}'

seed 37 5400 39 400000
OUT=$("$BIN/claude-usage" --gate 95 --cache-only); RC=$?
check "below threshold -> exit 0" "$RC" 0
has   "  and reports OK" "$OUT" "OK 5h=37%"

OUT=$("$BIN/claude-usage" --gate 30 --cache-only); RC=$?
check "5h above threshold -> exit 1" "$RC" 1
has   "  and gives an absolute deadline" "$OUT" "deadline="

seed 50 5400 100 3600          # weekly exhausted, resets in 1h
OUT=$("$BIN/claude-usage" --gate 95 --cache-only); RC=$?
check "weekly exhausted with a near reset -> exit 4" "$RC" 4
has   "  and points at the WEEKLY reset, not the 5h one" "$OUT" "BLOCKED_WEEKLY_WAIT"

seed 50 5400 100 400000        # weekly exhausted, resets in ~4.6 days
OUT=$("$BIN/claude-usage" --gate 95 --cache-only); RC=$?
check "weekly exhausted with a distant reset -> exit 3" "$RC" 3
has   "  and does not propose waiting" "$OUT" "BLOCKED_WEEKLY "

seed 99 5400 40 400000
OUT=$("$BIN/claude-usage" --gate 95 --cache-only); RC=$?
check "weekly wins over 5h when both apply" "$RC" 1

echo
echo "== endpoint path (no statusline cache) =="
# Regression: the endpoint returns "...+00:00" offsets, which jq's
# fromdateiso8601 cannot parse (it only accepts a literal "Z"). That used to sink
# the whole normalisation and leave the gate blind exactly at 100%.
rm -f "$DS/rate_limits.json"
FIVE_ISO=$(date -u -d "@$(( $(date +%s) + 3600 ))" '+%Y-%m-%dT%H:%M:%S.580242+00:00')
WEEK_ISO=$(date -u -d "@$(( $(date +%s) + 400000 ))" '+%Y-%m-%dT%H:%M:%S.580264+00:00')
jq -nc --arg f "$FIVE_ISO" --arg w "$WEEK_ISO" \
  '{five_hour:{utilization:100.0, resets_at:$f},
    seven_day:{utilization:51.0, resets_at:$w},
    extra_usage:{is_enabled:false, utilization:100.0, disabled_reason:"org_level_disabled_until"}}' \
  > "$DS/usage.json"

OUT=$("$BIN/claude-usage" --line --cache-only 2>&1); RC=$?
check "--line works off the endpoint response" "$RC" 0
has   "  parsing the +00:00 offset" "$OUT" "5h 100%"

OUT=$("$BIN/claude-usage" --norm --cache-only 2>&1)
jq -e '.five_reset | type == "number"' <<<"$OUT" >/dev/null 2>&1 \
  && ok "  and five_reset is a real epoch, not null" || bad "  five_reset did not parse" "$OUT"
jq -e '.extra_enabled == false' <<<"$OUT" >/dev/null 2>&1 \
  && ok "  and extra_usage is carried through" || bad "  extra_usage missing" "$OUT"

OUT=$("$BIN/claude-usage" --gate 95 --cache-only); RC=$?
check "  gate blocks at 100% via the endpoint" "$RC" 1
has   "  with a usable deadline" "$OUT" "deadline="
DL=$(sed -n 's/.*deadline=\([0-9]*\).*/\1/p' <<<"$OUT")
[[ -n "$DL" ]] && ok "  deadline is numeric ($DL)" || bad "  no numeric deadline" "$OUT"

# The hook must actually act on it rather than silently no-op.
cfg '{enabled:true, threshold:95, maxSleepSecs:60}'
OUT=$(run_gate_hook '{"hook_event_name":"Stop","stop_hook_active":false}'); RC=$?
check "  and the hook reacts instead of no-op'ing" "$RC" 0
has   "  (capped by maxSleepSecs, with a reason)" "$OUT" "maxSleepSecs"
rm -f "$DS/usage.json"

echo
echo "== dont-stop-gate hook: when it must do NOTHING =="
seed 99 5400 40 400000         # a blocking situation for all of these

cfg '{enabled:false, threshold:95}'
OUT=$(run_gate_hook '{"hook_event_name":"Stop","stop_hook_active":false}'); RC=$?
check "config enabled:false -> no-op (exit 0)" "$RC" 0
check "  and no output" "$OUT" ""

cfg '{enabled:true, threshold:95}'
OUT=$(CLAUDE_DONT_STOP=0 run_gate_hook '{"hook_event_name":"Stop","stop_hook_active":false}'); RC=$?
check "CLAUDE_DONT_STOP=0 overrides the config -> no-op" "$RC" 0

OUT=$(run_gate_hook '{"hook_event_name":"Stop","stop_hook_active":true}'); RC=$?
check "stop_hook_active:true -> no-op (loop guard)" "$RC" 0

OUT=$(run_gate_hook '{"hook_event_name":"StopFailure","error":"overloaded","stop_hook_active":false}'); RC=$?
check "StopFailure that is not a rate_limit -> no-op" "$RC" 0

seed 10 5400 20 400000         # low usage: nothing to do
OUT=$(run_gate_hook '{"hook_event_name":"Stop","stop_hook_active":false}'); RC=$?
check "usage below threshold -> no-op" "$RC" 0
check "  and no noise on stdout" "$OUT" ""

echo
echo "== dont-stop-gate hook: when it MUST act =="

# Deadline already past: must exit 2 immediately, without sleeping.
seed 99 -10 40 400000
START=$(date +%s)
OUT=$(run_gate_hook '{"hook_event_name":"Stop","stop_hook_active":false}' 2>"$TMP/err"); RC=$?
ELAPSED=$(( $(date +%s) - START ))
check "5h exhausted with the reset already past -> exit 2 (wakes the model)" "$RC" 2
[[ $ELAPSED -lt 5 ]] && ok "  and does not sleep (${ELAPSED}s)" || bad "  should not sleep" "took ${ELAPSED}s"
has   "  with an instruction to carry on" "$(cat "$TMP/err")" "Carry on"

# Weekly exhausted and far off: systemMessage and NO sleeping.
seed 50 5400 100 400000
OUT=$(run_gate_hook '{"hook_event_name":"Stop","stop_hook_active":false}'); RC=$?
check "weekly exhausted and far off -> exit 0, no sleep" "$RC" 0
jq -e '.systemMessage' <<<"$OUT" >/dev/null 2>&1 \
  && ok "  and warns in chat via systemMessage" \
  || bad "  should emit systemMessage" "$OUT"
has   "  saying it is stopping" "$OUT" "WEEKLY CAP EXHAUSTED"

# A real short wait: check it sleeps to the instant and exits 2.
seed 99 2 40 400000
cfg '{enabled:true, threshold:95, graceSecs:2, maxSleepSecs:21600}'
START=$(date +%s)
OUT=$(run_gate_hook '{"hook_event_name":"Stop","stop_hook_active":false}' 2>"$TMP/err2"); RC=$?
ELAPSED=$(( $(date +%s) - START ))
check "real short wait -> exit 2 after sleeping" "$RC" 2
[[ $ELAPSED -ge 3 && $ELAPSED -lt 40 ]] \
  && ok "  slept about as expected (${ELAPSED}s)" || bad "  odd duration" "${ELAPSED}s"

# Safety cap: a wait longer than maxSleepSecs -> do not sleep.
seed 99 999999 40 400000
cfg '{enabled:true, threshold:95, maxSleepSecs:60}'
START=$(date +%s)
OUT=$(run_gate_hook '{"hook_event_name":"Stop","stop_hook_active":false}'); RC=$?
ELAPSED=$(( $(date +%s) - START ))
check "wait > maxSleepSecs -> exit 0 without sleeping" "$RC" 0
[[ $ELAPSED -lt 5 ]] && ok "  and does not hang" || bad "  it hung" "${ELAPSED}s"
has   "  explaining why" "$OUT" "maxSleepSecs"

echo
echo "== shared deadline (subagents must not chain their waits) =="
rm -f "$DS/deadline"
seed 99 3 40 400000
cfg '{enabled:true, threshold:95, graceSecs:1}'
S=$(date +%s)
run_gate_hook '{"hook_event_name":"Stop","stop_hook_active":false}'            >/dev/null 2>&1 &
P1=$!
run_gate_hook '{"hook_event_name":"SubagentStop","agent_type":"a","stop_hook_active":false}' >/dev/null 2>&1 &
P2=$!
run_gate_hook '{"hook_event_name":"SubagentStop","agent_type":"b","stop_hook_active":false}' >/dev/null 2>&1 &
P3=$!
wait $P1 $P2 $P3
E=$(( $(date +%s) - S ))
[[ $E -lt 30 ]] && ok "3 concurrent waits finish together (${E}s, not 3x)" \
                || bad "the waits chained" "${E}s"

echo
echo "== dont-stop-context: output shape =="
seed 37 5400 39 400000
OUT=$(printf '{"hook_event_name":"UserPromptSubmit"}' | "$BIN/dont-stop-context")
jq -e '.hookSpecificOutput.hookEventName == "UserPromptSubmit" and
       (.hookSpecificOutput.additionalContext | length > 0)' <<<"$OUT" >/dev/null 2>&1 \
  && ok "UserPromptSubmit returns a valid hookSpecificOutput" \
  || bad "wrong shape" "$OUT"
has "  carrying the usage line" "$OUT" "5h 37%"

cfg '{enabled:true, injectOnPrompt:false}'
OUT=$(printf '{"hook_event_name":"UserPromptSubmit"}' | "$BIN/dont-stop-context")
check "injectOnPrompt:false -> injects nothing" "$OUT" ""

echo
echo "== dont-stop-statusline =="
cfg '{enabled:true, statuslineDelegate:"cat > '"$TMP/seen.json"'; echo DELEGATE-OK"}'
rm -f "$DS/rate_limits.json"
IN='{"model":{"display_name":"Opus 5"},"rate_limits":{"five_hour":{"used_percentage":42.0,"resets_at":1785325000},"seven_day":{"used_percentage":51.0,"resets_at":1785719600}}}'
OUT=$(printf '%s' "$IN" | "$BIN/dont-stop-statusline")
check "delegates to the previous statusline" "$OUT" "DELEGATE-OK"
jq -e '.model.display_name == "Opus 5"' "$TMP/seen.json" >/dev/null 2>&1 \
  && ok "  passing it the full JSON" || bad "  the delegate did not receive the JSON" "$(cat "$TMP/seen.json" 2>/dev/null)"
jq -e '.five_pct == 42 and .week_pct == 51' "$DS/rate_limits.json" >/dev/null 2>&1 \
  && ok "  and caching rate_limits for the gate" || bad "  did not cache" "$(cat "$DS/rate_limits.json" 2>/dev/null)"

# No rate_limits (e.g. before the first API response) must not break anything.
OUT=$(printf '{"model":{"display_name":"Opus 5"}}' | "$BIN/dont-stop-statusline"); RC=$?
check "no rate_limits in the input -> still delegates without breaking" "$RC" 0

echo
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
exit $(( FAIL > 0 ))
