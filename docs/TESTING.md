# Testing

## Local test sequence
```bash
cd /Users/danilagulin/Documents/VETKA_Project/vetka_live_03/tools/back_to_ussr_app
./scripts/run_tests.sh
```

What it validates:
1. Parser and base64 decoder unit tests.
2. Real subscription fetch/decode from Liberty URLs.
3. Built app binary architecture check.

## Manual smoke test on target Mac
1. Open `BACK_TO_USSR.app`.
2. `Manage Subscription URLs` -> paste links.
3. `Refresh Servers` -> status must show `Loaded N servers`.
4. Click `Connect` and approve admin prompt.
5. Check `Current IP` in app menu changed.
6. Run in terminal:
```bash
curl --socks5-hostname 127.0.0.1:12334 https://api.ipify.org --max-time 12
```

## If refresh fails
- Ensure URL starts with `https://`
- Recheck URL on source side
- Verify network can resolve target host
