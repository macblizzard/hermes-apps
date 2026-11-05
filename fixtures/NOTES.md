# Recorded gateway fixtures (M0)

Captured on 5 Nov 2026 from a real `tui_gateway` process
(`python -m tui_gateway.entry`, Hermes Agent **v0.22.6**, `/usr/local/lib/hermes-agent`) over stdio,
in a throwaway `HERMES_HOME`. These are observed bytes, not documentation — where they disagree with
the docs, **the fixtures win**, and this file records the disagreement.

Recorder: `Tools/record_fixtures.py` (same script shape; drives the gateway and appends every frame).

## 1. The event envelope (important)

The docs describe events as `message.delta`, `tool.start`, … — but on the wire every event arrives
as a notification whose **method is `event`**, with the real name inside `params.type`:

```json
{"jsonrpc":"2.0","method":"event","params":{"type":"gateway.ready","payload":{…}}}
```

Consequences for `HermesKit`:

- `JSONRPCCodec` must keep decoding the notification method (`event`) — it does.
- The event model must unwrap **two** levels: `params.type` (name) and `params.payload` (body).
- A client that switches on `method == "message.delta"` will never fire. This is exactly the bug
  fixtures exist to prevent.

## 2. `client.capabilities` is mandatory, and its answer is a contract

Request:

```json
{"jsonrpc":"2.0","id":2,"method":"client.capabilities","params":{"server_requests":true}}
```

Response (observed, full list):

```json
{"result":{"server_requests":["approval","clarify","display.install.sudo","preview.act",
"preview.read","secret","setup_beat","sudo","terminal.read","theme.apply","theme.pick","tour",
"vault.code","vault.save_login","vault.unlock_prompt","window.read"],
"declines_not_shown":true,"canonical_clarify_batch":true}}
```

So the six methods we must implement in v1 are a subset: `approval`, `clarify`, `sudo`, `secret`,
`vault.code`, `terminal.read`. The rest can be answered `-32601` and the agent fails fast.

## 3. The unknown-method answer

```json
{"jsonrpc":"2.0","id":4,"error":{"code":-32601,"message":"unknown method: no.such.method — not available on this Hermes backend"}}
```

Codes confirmed: **-32601** unknown method, **-32700** parse error (from `entry.py`),
**-32000** handler crash, and Hermes' own **4009 session busy / 4004 / 4018 / 4029 / 4033** family for
rewind safety.

## 4. `session.list` can be slow or silent — timeouts are mandatory

`session.list {limit:5}` produced **no response frame at all** within the 60 s probe window on a cold,
unconfigured profile, while `ping`, `client.capabilities`, `gateway.capabilities` and the error case
all answered immediately. Two lessons:

1. Every call needs a **timeout** (recommend 30 s default, 120 s for `session.list` on first attach),
   surfacing a retry affordance instead of a spinner forever.
2. Never treat "no reply" as "empty list" — an empty list is an explicit `result`, absence is not.

## 5. Startup ordering

`gateway.ready` is written **before** any request is read. A client that sends frames before receiving
`gateway.ready` is fine (the loop is already reading), but `client.capabilities` must be sent once
per connection *after* ready, before any prompt that could raise an approval.
