# MT5 XAUUSDr Copy Trading Bot

Production-oriented local trade copier for **one MT5 master account** to **one MT5 follower account** on **XAUUSDr**, same broker, hedging mode, same lot, absolute SL/TP, and all trade sources.

## Architecture

```text
MT5 Master Terminal (CopyMaster_XAUUSDr.mq5)
  -> HTTP local relay on 127.0.0.1:8787 (Node.js)
  -> MT5 Follower Terminal (CopyFollower_XAUUSDr.mq5)
```

The master EA sends event-driven full snapshots after `OnTradeTransaction()` and periodic heartbeats. The follower EA polls the relay every 200 ms by default and reconciles the follower account to the latest master snapshot. This state-based design is safer than command-only copy because it self-heals after short disconnects and catches SL/TP changes, pending-order edits, closes, and partial closes.

## What is copied

- Symbol: `XAUUSDr` only.
- Market BUY/SELL positions.
- Same lot size.
- Absolute SL and TP values, including no SL/no TP and later SL/TP changes.
- Full close and partial close.
- Pending orders: buy/sell limit, buy/sell stop, buy/sell stop-limit.
- Pending order modify/delete.
- Manual trades and EA trades from the master account.

## Safety controls

- Relay binds to `127.0.0.1` by default.
- Bearer-token authentication between EAs and relay.
- Symbol lock to `XAUUSDr`.
- Master account id validation.
- Follower comments copied trades as `CP:<masterTicket>` to avoid touching unrelated manual follower trades.
- Max spread guard on follower before applying a snapshot.
- Dry-run mode on follower.
- JSONL audit log and persisted latest state.
- Optional Telegram alerts.

## Windows laptop setup

1. Install Node.js 20+.
2. Generate a token:

   ```powershell
   node scripts/new-token.js
   ```

3. Copy the token into `config/default.json` as `authToken`.
4. Start the relay:

   ```powershell
   npm start
   ```

5. Open two separate MT5 terminals on the laptop:
   - Terminal A logged into the master account.
   - Terminal B logged into the follower account.
6. In both MT5 terminals, allow WebRequest:
   - `Tools` -> `Options` -> `Expert Advisors`.
   - Enable `Allow WebRequest for listed URL`.
   - Add `http://127.0.0.1:8787`.
7. Compile both files in MetaEditor:
   - `mql5/CopyMaster_XAUUSDr.mq5`
   - `mql5/CopyFollower_XAUUSDr.mq5`
8. Attach `CopyMaster_XAUUSDr` to any chart in the master terminal and set:
   - `InpAuthToken` = the same relay token.
   - `InpSymbol` = `XAUUSDr`.
9. Attach `CopyFollower_XAUUSDr` to any chart in the follower terminal and set:
   - `InpAuthToken` = the same relay token.
   - `InpSymbol` = `XAUUSDr`.
   - Start with `InpDryRun = true` for the first test.
10. Test on demo or tiny live volume before normal use.

## Telegram alerts

Edit `config/default.json`:

```json
"telegram": {
  "enabled": true,
  "botToken": "123456:ABC...",
  "chatId": "123456789"
}
```

Restart the relay after changing config.

## Operational checklist

- Keep both MT5 terminals open and logged in.
- Keep AutoTrading enabled in both terminals.
- Keep laptop awake; disable sleep/hibernate while trading.
- Use a stable internet connection.
- Check relay health at `http://127.0.0.1:8787/health`.
- Review `logs/events.jsonl` if a copy action fails.

## Important limitation

No retail MT5 copier can guarantee true zero delay. This implementation is designed for near-real-time local operation, but actual execution depends on MT5 terminal scheduling, broker server latency, spread, margin, slippage, and market status.
