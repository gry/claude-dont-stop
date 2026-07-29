# dont-stop

A Claude Code plugin that **pauses the session when the 5-hour usage window runs
out and resumes it automatically once the window resets**. If the weekly cap is
what ran out, it only waits when the reset is close; if it is days away, it stops
and tells you.

Built for long unattended runs — overnight coverage work, bulk migrations,
codebase-wide sweeps — where the work used to die halfway through with a 429.

## What it actually does

Three hooks, all with `asyncRewake: true` — they run in the **background**, never
block the UI, and when they exit with code 2 Claude Code wakes the model and hands
it their stderr as instructions.

| Hook | When | What it does |
|---|---|---|
| `Stop` | end of every turn | if the 5h window hit the threshold, waits for the reset and resumes |
| `StopFailure` | the turn died with `error: "rate_limit"` | safety net: waits and resumes even if the gate did not see it coming |
| `SubagentStop` | a subagent finishes | same, so subagents **keep their context** instead of dying |
| `SessionStart`, `UserPromptSubmit` | — | inject usage state into the model's context via `hookSpecificOutput.additionalContext` |

**It sleeps until an absolute instant (`resets_at`), never for "N seconds".** That
is what makes several concurrent sleepers (main thread plus subagents) all wake at
the same moment instead of chaining their waits; whoever joins late sleeps zero.

**Usage is read for free.** Claude Code hands `rate_limits` to the statusLine
command on every render. `dont-stop-statusline` caches that to disk and everything
else reads from there: no network, no rate limit. The `/api/oauth/usage` endpoint
is only the fallback (startup, and re-verification after waking).

## Requirements

`jq`, `curl`, Claude Code >= 2.1.220, and a signed-in subscription account.

## Install

```bash
git clone https://github.com/gry/claude-dont-stop ~/tools/claude-dont-stop
cd ~/tools/claude-dont-stop
./install.sh            # --dry-run to see the diff without writing anything
```

`install.sh` does four things, all idempotent:

1. creates `~/.claude/dont-stop.json` with the defaults;
2. registers the local marketplace in `~/.claude/settings.json` (backing it up first);
3. wraps `statusLine` to cache usage — if you already had one, it is preserved and
   still invoked (stored as `statuslineDelegate`);
4. runs `claude plugin install dont-stop@claude-dont-stop`.

Restart Claude Code, then check with `bin/dont-stop-ctl status`.

> **`claude plugin install` copies the plugin** into `~/.claude/plugins/cache/`.
> Setting `enabledPlugins` by hand in `settings.json` is **not enough**. If you
> edit this repo, re-run `./install.sh` to pick the changes up.

### From the marketplace, without cloning

```bash
claude plugin marketplace add gry/claude-dont-stop
claude plugin install dont-stop@claude-dont-stop
```

Quicker, but this way you **skip the statusLine wrapper**, which is what provides
free, network-free usage data. Without it everything falls back to
`/api/oauth/usage`, which has its own rate limit: the plugin still works, but with
less fresh data and the occasional `[stale]` read.

If you go this route and still want the wrapper, wire it up by hand. Note the
cache path **includes the version**, so it needs revisiting after each update:

```jsonc
// ~/.claude/settings.json — adjust the version after every `plugin update`
"statusLine": {
  "type": "command",
  "command": "~/.claude/plugins/cache/claude-dont-stop/dont-stop/1.0.0/bin/dont-stop-statusline"
}
```

That is why **`install.sh` is the recommended route**: it points at the cloned
repo, whose path does not change across updates, and it preserves any statusLine
you already had.

### In a devcontainer

```jsonc
{
  "postCreateCommand": "claude plugin marketplace add gry/claude-dont-stop && claude plugin install dont-stop@claude-dont-stop",
  "mounts": [
    "source=claude-config,target=/home/node/.claude,type=volume"
  ]
}
```

The volume is optional but saves you reinstalling and re-authenticating every time
the container is rebuilt.

## Configuration

`~/.claude/dont-stop.json`:

| Key | Default | Meaning |
|---|---|---|
| `enabled` | `true` | master switch |
| `threshold` | `95` | % of the 5h window at which it starts waiting |
| `injectOnPrompt` | `true` | inject the usage line on every prompt |
| `maxSleepSecs` | `21600` (6h) | safety cap: above this it refuses to sleep and warns |
| `weeklyMaxWaitSecs` | `28800` (8h) | how long it will wait for the **weekly** reset |
| `graceSecs` | `60` | margin after the reset before resuming |
| `statuslineDelegate` | — | your previous statusLine, invoked by the wrapper |

Per-session overrides (these win over the file):

```bash
CLAUDE_DONT_STOP=0 claude              # off for this session only
CLAUDE_DONT_STOP_THRESHOLD=85 claude   # more conservative (expensive runs)
```

Mid-session, taking effect immediately (the hooks re-read the config on every fire):

```bash
dont-stop-ctl status        # current usage plus what the gate would do right now
dont-stop-ctl off / on
dont-stop-ctl threshold 85
dont-stop-ctl log           # wait history
```

Or from the chat: `/dont-stop`, `/dont-stop 85`, `/dont-stop off`.

### Choosing a threshold

The default 95% leaves room to finish an ordinary task. Lower it when what comes
next is expensive (agent fan-out, workflows, huge files): at `--gate 85` it cuts in
earlier and will not catch you mid-task.

### Does the injected context cost anything?

About 94 characters (~30 tokens) per prompt, plus ~390 characters once at session
start. Over a 100-turn run that is roughly 3,000 tokens — well under 2% of a 200k
context. It is appended rather than prepended, so it does **not** invalidate the
prompt cache prefix. Set `injectOnPrompt: false` to drop it anyway; the protection
itself is unaffected.

## `claude-usage` on its own

```bash
claude-usage                # 5h 37% | 7d 39% | extra off | 5h reset 13:49 CEST (in 1h29m)
claude-usage --gate [95]    # exit 0 go · 1 5h exhausted · 3 weekly far · 4 weekly near · 2 error
claude-usage --wait-secs    # seconds until the 5h reset
claude-usage --json         # raw endpoint response
claude-usage --cache-only   # never touches the network
```

**The endpoint has its own aggressive rate limit** (measured 2026-07-29): ~7 calls
in 4 minutes return HTTP 429, and the 429 **lasts ~4 minutes** even after you stop
calling. That is why responses are cached (60s TTL) and a 429 serves the previous
copy marked `[stale]`. **Never poll**: sleep exactly as long as `--wait-secs` says.

## If the OAuth token expires mid-run

The token in `~/.claude/.credentials.json` expires, and Claude Code refreshes it on
its own while the session is alive, rewriting the file. `claude-usage` **re-reads
the file on every call**, so it normally picks the new token up transparently.

The important design property: **the waiting does not need the token.** Only the
check does. If the token were expired on waking and the endpoint returned 401:

- the last cached copy is served, marked `[stale]`, and the session resumes anyway
  — it does not hang;
- if resuming then failed on authentication, `StopFailure` receives
  `error: "authentication_failed"`, which is **not** `rate_limit`, so the hook
  no-ops and the session stops rather than looping. You find it stopped in the
  morning, not wedged.

A long `sleep` does not prevent the refresh: that is done by the Claude Code
process, not by the hook.

## Tests

```bash
./test/run-tests.sh
```

35 checks, no network (caches are seeded by hand), so it can be re-run without
burning the endpoint's rate limit. They cover the gate's exit codes, the hook's
no-op paths, real waits, the safety cap, the deadline shared between subagents, the
shape of the hook output, and the statusLine wrapper.

## Known limitation

`StopFailure` + `asyncRewake` revives the session in **interactive** mode. In
headless mode (`claude -p`) the process has already exited by the time the hook
finishes waiting, so it does not resume there. Verified on 2.1.220. Long
interactive runs — the actual use case — work.

## License

MIT
