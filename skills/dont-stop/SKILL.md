---
name: dont-stop
description: Inspect or adjust the Claude usage-window guard (dont-stop) — check current 5-hour and 7-day window usage, change the pause threshold, or turn automatic waiting on and off. Use when the user asks how much usage they have left, when their window resets, or wants to enable, disable or reconfigure the automatic wait before a long run.
argument-hint: "[status | on | off | <threshold 1-100>]"
allowed-tools: Bash(dont-stop-ctl:*), Bash(claude-usage:*), Read, Edit
---

# dont-stop

Usage-window guard. You normally **do not need to invoke this**: the plugin's
hooks act on their own. This is the escape hatch for inspecting and reconfiguring.

## How it works (for answering the user's questions)

Three hooks, all with `asyncRewake: true`, so they run in the **background** and
block nothing:

- `Stop` — at the end of each turn, checks the 5-hour window. If it hit the
  threshold, waits for the reset and resumes the session on its own.
- `StopFailure` — safety net: if the turn dies with `error: "rate_limit"` despite
  the gate, it waits anyway and resumes.
- `SubagentStop` — the same for each subagent, so they **do not lose their
  context**. Everyone waits until the same absolute instant (`resets_at`), so the
  waits never chain.

Usage is read from the cache written by the statusLine wrapper (free, no network);
the `/api/oauth/usage` endpoint is only the fallback and the post-wake re-check.

If the **weekly** cap is what ran out: it waits when the reset is less than
`weeklyMaxWaitSecs` away (8h by default); if it is days away it **stops and warns**
— sleeping cannot fix a reset that is days out.

## Actions

Run whatever the user asks for and **show the output verbatim**:

| Request | Command |
|---|---|
| check state / how much is left | `dont-stop-ctl status` |
| enable automatic waiting | `dont-stop-ctl on` |
| disable it | `dont-stop-ctl off` |
| change the threshold | `dont-stop-ctl threshold <N>` |
| see the wait history | `dont-stop-ctl log` |

With no arguments, run `dont-stop-ctl status`.

`dont-stop-ctl` writes to `~/.claude/dont-stop.json`. Threshold and on/off changes
apply **immediately**, including to the running session: the hooks re-read the
config every time they fire.

## After resuming from a wait

When the session wakes up after a pause, the hook tells you so on stderr. Do what
it asks: **say in one line that you were paused and for how long**, then continue
the task where it left off. Do not restart the work or ask for confirmation.

## Mind the endpoint's rate limit

`claude-usage --fresh` hits `/api/oauth/usage`, which has its own aggressive rate
limit: ~7 calls in 4 minutes return HTTP 429, and the 429 lasts ~4 minutes even
after you stop calling. **Never call it in a loop.** Without `--fresh` it is served
from cache and costs no network.
