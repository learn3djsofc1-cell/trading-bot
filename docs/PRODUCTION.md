# Production Runbook for Windows Laptop

## Recommended MT5 layout

Use two separate MT5 installations/data folders:

- `MT5-Master` logged into account A.
- `MT5-Follower` logged into account B.

Do not attach the follower EA to the master terminal or the master EA to the follower terminal.

## First live rollout

1. Start the Node relay.
2. Attach follower EA with `InpDryRun = true`.
3. Attach master EA.
4. Open, modify, partially close, and close a tiny XAUUSDr test trade on master.
5. Confirm follower journal prints the expected dry-run actions.
6. Set `InpDryRun = false` on follower.
7. Repeat with 0.01 lot.

## Laptop hardening

- Disable Windows sleep/hibernate while trading.
- Keep the laptop connected to power.
- Use wired internet where possible.
- Keep Windows time synchronized.
- Do not let Windows Update reboot during trading hours.
- Add the repo directory to antivirus exclusions if file locking delays logs/state writes.

## Failure handling

- If the relay is stopped, master/follower EAs keep running but cannot communicate.
- When the relay returns, the master heartbeat republishes the current state.
- The follower reconciles to the latest snapshot and closes/deletes copied follower trades that no longer exist on master.
- The follower only touches positions/orders whose comment starts with `CP:`.

## Health check

Open this URL locally:

```text
http://127.0.0.1:8787/health
```

Healthy output should show:

- `ok: true`
- `symbol: "XAUUSDr"`
- `hasSnapshot: true`
- `stale: false`

## Logs

- Relay state: `data/state.json`
- Audit log: `logs/events.jsonl`
- MT5 runtime details: Expert and Journal tabs in each terminal.
