# hermes-apps

Native **macOS** and **iOS** clients for a Hermes host — the OpenBot look and density, pointed at
your own Hermes backend over your tailnet through the TUI-gateway JSON-RPC that Hermes already
speaks.

Design and reasoning: `docs/` in the research bundle (`01-openbot-teardown.md`,
`02-architecture.md`, `03-ux-spec.md`, `04-plan.md`).

## Layout

```
Package.swift                  SwiftPM: HermesKit (protocol/transport), OpenBotUI (design system), HermesRender (markdown)
Apps/HermesMac/                macOS 14+ SwiftUI shell (rail 72 / sidebar 280 / conversation / context 236)
Apps/HermesMobile/             iOS 17+ SwiftUI, native chrome only
Bridge/                        FastAPI bridge: pairing, devices, tokens, /v1/ws proxy (loopback only)
Tests/                         unit tests for packages
project.yml                    XcodeGen spec (the .xcodeproj is generated, never committed)
.github/workflows/ci.yml       macOS runners: swift build+test, macOS app, iOS app, unsigned .ipa, python tests
```

## Build

Everything compiles on GitHub-hosted macOS runners; no local Xcode needed to validate a change.

```bash
gh run list --limit 5
gh run watch
```

Locally (with Xcode 16):

```bash
brew install xcodegen
swift test                       # packages only
xcodegen generate && open HermesApps.xcodeproj
```

## Distribution (no Apple developer certificate)

- **iOS**: CI archives unsigned and packages a `Payload/` into `Hermes-unsigned.ipa` (ad-hoc signed),
  uploaded as the `Hermes-unsigned-ipa` artifact. That is the artifact FlareStore re-signs with your
  own certificate.
- **macOS**: `Hermes-macOS-unsigned.zip` from CI. First launch needs
  `xattr -dr com.apple.quarantine /Applications/Hermes.app` (or right-click → Open).

## Wire protocol

Newline-delimited JSON-RPC 2.0 against the Hermes TUI gateway (`tui_gateway/ws.py` on the host).
The client must, once per connection after `gateway.ready`, call
`client.capabilities {server_requests: true}` — otherwise the gateway refuses every
approval/clarify/sudo request it sends us.

## Security invariants

- The bridge binds `127.0.0.1` only; `tailscale serve` terminates TLS and exposes it to the tailnet.
- Devices hold an Ed25519 key; the server stores only a SHA-256 of the refresh token.
- WS tickets are single-use, 30 s, and scoped to one device.
- Hermes approvals stay enabled. This client can answer them; it can never escalate permission.
