# BACK_TO_USSR

Menu-bar VPN app for Intel macOS 11+.

## Features
- Menu icon near system clock (`★ USSR`)
- Multiple subscription URLs (unlimited, one per line)
- Refresh from all URLs, merge and deduplicate nodes
- Server picker by country/name
- Connect/Disconnect
- Auto-dial with fallback (`flow` on -> off)
- Auto-reconnect monitor every 30s
- Optional anthem on successful connect

## Build
```bash
/Users/danilagulin/Documents/VETKA_Project/vetka_live_03/tools/back_to_ussr_app/build_back_to_ussr_app.command
```

Output:
- `/Users/danilagulin/Documents/VETKA_Project/vetka_live_03/tools/back_to_ussr_app/dist/BACK_TO_USSR.app`
- `/Users/danilagulin/Documents/VETKA_Project/vetka_live_03/tools/back_to_ussr_app/dist/BACK_TO_USSR.app.zip`

## Use
1. Launch app.
2. `Manage Subscription URLs` -> paste URLs (one per line).
3. `Refresh Servers`.
4. `Connect`.
5. Confirm admin password prompt for system SOCKS switch.

## Notes
- App requires bundled `sing-box` binary.
- If browser still bypasses proxy, re-run `Connect` and confirm password prompt was accepted.
