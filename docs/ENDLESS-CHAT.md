# Endless chat + bot-first IA

Decisions that the code must follow. Measured facts, not preferences.

## 1. Main screen is the bot list

After pairing, the app opens on **all bots** (`profiles.list`, 15 on this host) — no drawer, no
hidden switcher. Each row: avatar initial, bot name, last message preview, latency-neutral.

Tapping a bot opens that bot's conversation. Leaving the conversation returns to the list.

## 2. One endless conversation per bot

There is **no session list** in the UI. Hermes' canonical bot conversation is titled exactly
`Bot Chat` (`tools/bot_mode_probe.py::BOT_CHAT_TITLE`, the value the Desktop's
`createCanonicalChat` uses). The client asks `session.list {profile, title: "Bot Chat",
include_hidden: true}` and treats an exact-title row as the row to open. The title is a discovery
hint, **not a distributed lock and not a sync guarantee**.

Resolution order, each step verified against the host:

1. **Exact canonical title.** If a row exists, it is opened as-is; the client never rewrites its
   title.
2. **This device's saved id.** Only when no canonical row exists: resume
   `hermes.endlessSession.<botID>` if the host still has it. This keeps pre-canonical and
   device-local history reachable instead of silently replacing it with a fresh `Bot Chat`.
   The recovered row is **not retitled**: it may carry a title the user chose, so opening it must
   not run an automatic canonical migration. The saved id remains the local pointer. A
   timeout/transport failure keeps the pointer; only a host "session not found" (4001/4007) is
   treated as stale.
3. **A fresh canonical row.** If there is neither an exact-title row nor a resumable local id,
   create one (`session.create {profile, title: "Bot Chat"}`). The row is cached/attached only
   after the host accepts the title write. If that write fails, the row is not claimed, no
   existing history is replaced, and the failure is reported as a blocker.

The client does **not** adopt the host's `session.most_recent {profile}` row: that can be an
unrelated TUI or messaging thread, and titling it would overwrite a title the user chose.

There is **no automatic reset or canonical migration**. Starting a new conversation would require
either retitling an existing chat or archiving it, and neither is safe without an atomic claim.
The client therefore leaves the existing thread, its title and its local pointer untouched and
reports that nothing was changed. The conversation stays reachable; old history is never archived
by this client.

### Explicit limitations (not sync guarantees)

- **The canonical creation is not atomic.** Hermes provides no "find or create by unique title"
  operation and does not enforce uniqueness of `Bot Chat`. Two devices that open a bot before
  either has titled a row can each create their own canonical row. The client does not delete or
  merge duplicates and does **not** claim race-safe convergence.
- **The cross-device race remains unresolved.** This batch does not fix two devices creating or
  choosing different rows at the same time. It is a known blocker, not a solved guarantee.
- **Same-client concurrency is coalesced.** Two opens for one bot in this client wait on the same
  resolution task, so they cannot both create a row. That is a local convenience, not a
  cross-device guarantee.
- **A title is not a distributed lock.** Another writer on the same profile can rename or delete
  rows. The client resolves again on open; it does not assume the cached id survives. When a
  title cannot be confirmed the app reports the blocker instead of presenting the thread as
  shared.

## 3. Auto-compaction

`message.complete` carries real usage:
`usage.context_used`, `usage.context_max`, `usage.context_percent`.

After every completed turn, if `context_used >= threshold` and no compression is in flight:

1. call `session.compress` (params `{"session_id": <runtime id>}`),
2. re-`session.resume` to refresh the transcript,
3. surface a one-line notice ("conversation compacted"), never a blocking spinner.

Threshold: `UserDefaults` key `hermes.autoCompactTokens`, **default 200_000**. `0` disables
compaction. The conversation header always shows `context_used / context_max` so the user can see
it approaching the limit.

## 4. Settings holds settings, not a device dump

Sections, in order:

| Section | Contents |
|---|---|
| Connection | host, state (`direct`/`reconnecting`), latency, *Disconnect*, *Re-pair* |
| Chat | auto-compact threshold (numeric field + "off"), show reasoning toggle, show tool output toggle |
| Devices | one row per device, `this phone` badge, revoke — its own sub-screen |
| About | app version + build (from `Bundle`), protocol version |

Device management moved off the top level: 20+ rows of device toggles buried the actual settings.

## 5. Bugs this batch must also fix

These are wire-verified; the payload shapes below are from the live gateway.

| Bug | Cause | Correct source |
|---|---|---|
| model chip shows `anthropic/claude-fable…` | reads `providers[0].models[0]` | `model.options` → `model` + `provider` (`deepseek-v4.1-flash` / `opencode-go`) |
| tool rows labelled `tool` | card built from transcript projection | `tool.start` payload `name` |
| tool rows say `No output.` | reads a key that is not sent | `tool.complete`: `result_text` → `result` → `summary` |
| reply never renders until a session switch | deltas applied to a session the view is not watching | attribute to the attached session; `message.complete` must clear streaming |
| stuck on `Thinking…` | streaming flag never cleared when no turn is in flight | clear on complete, and after a resume whose `inflight` is nil/not streaming |
| reasoning invisible | `thinking.delta` dropped | `thinking.delta` payload `{"text"}` → separate reasoning stream |

`message.delta` / `thinking.delta` / `message.complete` carry **no** `session_id`; `tool.start` /
`tool.complete` are `{tool_id, name, args?, result_text?, result?, summary?, duration_s?}`.
