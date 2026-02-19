# Architecture

## Components
- `src/main.swift`: AppKit menu-bar app + orchestration
- `build_back_to_ussr_app.command`: deterministic Intel app build + resource bundling
- `scripts/live_subscription_check.py`: live endpoint sanity checks
- `scripts/run_tests.sh`: local test entrypoint
- `tests/run_unit_tests.py`: parser/decode unit tests

## Runtime Flow
1. User sets one or more subscription URLs.
2. App fetches each URL and decodes payload:
   - direct `vless://` lines
   - base64 payload
   - urlsafe base64 payload
3. App parses VLESS nodes and stores merged deduplicated pool.
4. On `Connect`, app attempts servers in priority order:
   - selected server
   - last successful server
   - all others
5. For each node, app tries:
   - `flow` as provided
   - fallback with `flow` disabled
6. App verifies proxy reachability through local SOCKS + external IP check.
7. On success, app enables system SOCKS and updates status.
8. Monitor loop periodically validates connection and triggers reconnect if needed.

## Audio Notification Flow
- Notification tracks bundled inside app resources (`*.mp3`)
- Random track chosen on successful connect
- Same track cannot repeat twice in a row
- Cooldown timestamp prevents too-frequent playback
- `Mute Anthem` hard-disables playback

## State Storage
Stored in user Application Support:
- subscription URLs
- parsed nodes
- selected/last successful server
- auto-reconnect flag
- audio mute + last-play metadata

## Compatibility Target
- Build target: `x86_64-apple-macos11.0`
- Intended hardware: Intel MacBook class devices
- Tested scenario: macOS Big Sur 11.7.x
