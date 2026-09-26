# Real-proof fixtures for the fork tests

`test/CryptoWill.fork.t.sol` replays real World ID simulator proofs against the World Chain Sepolia
WorldIDRouter. Put one JSON per identity here (they are gitignored) and point the env vars at them:

```json
{
  "app_id": "app_...",
  "signal_address": "0x...",
  "merkle_root": "0x...",
  "nullifier_hash": "0x...",
  "signal_hash": "0x...",
  "proof": "0x...",
  "block": 0
}
```

- `owner.json` — action `cryptowill-alive-check`, `signal_address` = owner wallet address.
- `heir.json` — action `cryptowill-heir-claim`, `signal_address` = payout address. Must be a
  different simulator identity from the owner.
- `merkle_root` / `nullifier_hash` / `signal_hash` / `proof` are copied as-is from the IDKit
  result; `proof` is the ABI-encoded `uint256[8]` hex string.
- `block`: `0` forks at latest. Roots expire after 7 days (`rootHistoryExpiry = 604800`), so a
  fixture only works at latest for a week; after that, set `block` to a World Chain Sepolia block
  from right after the proof was generated.

The test first asserts `signal_hash == hashToField(abi.encodePacked(signal_address))`. If that fails,
the frontend is encoding the signal differently from the contract (e.g. hashing the address as a
UTF-8 string instead of 20 raw bytes) — fix that before sending any real transaction.

```bash
OWNER_PROOF_FIXTURE=test/fixtures/owner.json HEIR_PROOF_FIXTURE=test/fixtures/heir.json \
  forge test --match-contract CryptoWillForkTest -vvv
```
