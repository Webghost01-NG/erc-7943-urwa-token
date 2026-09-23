# Web3Bridge Cohort XV — Eviction Test Part 2

## ERC-7943 uRWA Token

This repository contains a scoped implementation of the fungible ERC-20 path of [ERC-7943: Universal Real World Asset Interface](https://eips.ethereum.org/EIPS/eip-7943).

It was built for the Web3Bridge Cohort XV eviction test, “Implement the Standard.” The assignment asks for a tokenized real-world-asset pattern with compliance checks, account freezing, administrative recovery, automated tests, and a short explanation of the design.

## What problem does this solve?

Ordinary ERC-20 tokens mainly decide whether a transfer has sufficient balance and allowance. Regulated assets can require another layer of rules: only approved wallets may participate, an issuer may freeze assets, and an authorized issuer may recover assets under an enforcement or court-order scenario.

ERC-7943 standardizes the interface for those controls without forcing a particular KYC provider, jurisdiction, or access-control system. This project chooses a deliberately simple on-chain allow-list and one administrator to keep the implementation within the assignment scope.

## Scope

Included:

- A minimal ERC-20 implementation: balances, allowances, approvals, transfers, and minting.
- ERC-7943 fungible functions: `canSend`, `canReceive`, `canTransfer`, `getFrozenTokens`, `setFrozenTokens`, and `forcedTransfer`.
- ERC-165 interface detection for the ERC-7943 fungible interface.
- Admin-managed on-chain allow-list compliance.
- Amount-based freezing, including full-address `freeze` and `unfreeze` helpers required by the course wording.
- Admin-only forced transfer from a frozen account to an allow-listed recovery address.
- Foundry tests, event tests, failure-case tests, and fuzz testing.

Intentionally excluded:

- External KYC, AML, identity, or sanctions integrations.
- Multi-jurisdiction policies.
- Multiple administrators, multisig, timelocks, and upgradeability.
- Deployment scripts or a live deployment.
- ERC-721, ERC-1155, and ERC-6909 variants.

## Design choices

### Compliance is separate from accounting

`_balances` and `_allowances` provide normal ERC-20 accounting. `_allowlisted` and `_frozenTokens` provide compliance policy. This separation matters because a wallet can have enough tokens while still being ineligible to transfer them.

`canSend` and `canReceive` check whether an account is allow-listed. `canTransfer` checks both participants and confirms the amount does not exceed the sender’s unfrozen balance.

### Freezing is amount-based

ERC-7943 defines `setFrozenTokens(account, amount)`, so this project stores an absolute frozen amount rather than a simple boolean. That supports partial freezes: an account with 100 tokens and 70 frozen may transfer 30.

The unfrozen amount is calculated safely as `max(balance - frozen, 0)`. This matters because ERC-7943 permits freezing more than the current balance in order to withhold future incoming tokens. The `freeze` helper sets the frozen amount to `type(uint256).max`; `unfreeze` sets it to zero.

### Forced transfer is an enforcement path

`forcedTransfer` is restricted to the administrator. It requires a frozen source, enough source balance, and an allow-listed recovery address. It bypasses ordinary sender transfer restrictions because it represents an enforcement action, but it does not bypass recipient compliance.

When frozen assets are recovered, the contract updates the frozen amount and emits `Frozen` before emitting the ERC-20 `Transfer`, then emits ERC-7943 `ForcedTransfer`. This preserves an accurate event-based audit trail.

### Rejected transfers retain an audit event

The course asks for a rejected-transfer event. A Solidity event emitted immediately before a revert is reverted too, so it cannot remain on-chain for audit. For compliance failures, this implementation leaves balances and allowances unchanged, returns `false`, and emits the course-specific `TransferRejected` event with a reason:

- sender is not allow-listed;
- recipient is not allow-listed; or
- requested amount exceeds the unfrozen balance.

This is a course-scoped extension. The ERC-7943 interface itself standardizes `Frozen`, `ForcedTransfer`, and relevant custom errors.

## Project layout

```text
src/
  IERC7943Fungible.sol       ERC-165 and ERC-7943 fungible interfaces
  UniversalRWAToken.sol      Scoped ERC-20 / ERC-7943 implementation
test/
  UniversalRWAToken.t.sol    Foundry unit, event, failure, and fuzz tests
```

## Run the tests

Foundry is required.

```bash
forge build
forge fmt --check
forge test -vvv
forge coverage --report summary
```

The suite contains 22 tests, including 256 fuzz runs. It covers successful transfers; sender and recipient allow-list failures; full and partial freezes; excessive freeze amounts; non-admin failures; forced-transfer success and failure paths; event order; allowance behavior; interface support; and the invariant that exactly the unfrozen amount can transfer.

Measured with `forge coverage --report summary`:

| Metric | Coverage |
| --- | ---: |
| Lines | 98.23% |
| Statements | 94.02% |
| Branches | 77.27% |
| Functions | 100.00% |

## AI use disclosure

AI was used to help compare the assignment options, structure the implementation, and review the test strategy. The ERC-7943 specification was independently checked, the scope and policy decisions were selected for this project, and behavior was verified locally with Foundry tests and coverage.

## Important note

This is an educational, scoped implementation for the Web3Bridge eviction test. It is not audited and is not suitable for production deployment without substantially stronger governance, identity/compliance controls, security review, and legal review.
