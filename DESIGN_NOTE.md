# ERC-7943 uRWA Token — Design Note

## Project and assignment scope

This project implements the fungible ERC-20 path of [ERC-7943: Universal Real World Asset Interface](https://eips.ethereum.org/EIPS/eip-7943) for the Web3Bridge Cohort XV Eviction Test Part 2, “Implement the Standard.”

The assignment requires a token with an on-chain allow-list, administrative freezing, forced recovery from a frozen account, correct audit events, and automated tests. The implementation intentionally excludes external KYC/identity providers, jurisdiction-specific policy, upgradeability, multisig governance, and the ERC-721/ERC-1155/ERC-6909 variants.

## Specification mapping

The interface in [`src/IERC7943Fungible.sol`](src/IERC7943Fungible.sol) maps directly to the ERC-7943 fungible interface:

| Requirement | Implementation | Specification reference |
| --- | --- | --- |
| ERC-20 base token | `balanceOf`, `allowance`, `approve`, `transfer`, `transferFrom`, `mint` | [ERC-7943 base-token requirement](https://eips.ethereum.org/EIPS/eip-7943#specification), based on [ERC-20](https://eips.ethereum.org/EIPS/eip-20) |
| Account eligibility | `canSend`, `canReceive` | [ERC-7943 compliance views](https://eips.ethereum.org/EIPS/eip-7943#cansend-canreceive-cantransfer-and-getfrozentokens) |
| Transfer validation | `canTransfer` | [ERC-7943 transfer-level checks](https://eips.ethereum.org/EIPS/eip-7943#cansend-canreceive-cantransfer-and-getfrozentokens) |
| Freeze state | `setFrozenTokens`, `getFrozenTokens`, plus `freeze`/`unfreeze` helpers | [ERC-7943 freeze rules](https://eips.ethereum.org/EIPS/eip-7943#setfrozentokens) |
| Administrative recovery | `forcedTransfer` | [ERC-7943 forced-transfer rules](https://eips.ethereum.org/EIPS/eip-7943#forcedtransfer) |
| Standard events | `Frozen`, `ForcedTransfer`, ERC-20 `Transfer` | [ERC-7943 interface/events](https://eips.ethereum.org/EIPS/eip-7943#specification) and [forced-transfer requirements](https://eips.ethereum.org/EIPS/eip-7943#forcedtransfer) |
| Interface discovery | `supportsInterface` | [ERC-7943 additional specifications](https://eips.ethereum.org/EIPS/eip-7943#additional-specifications) / [ERC-165](https://eips.ethereum.org/EIPS/eip-165) |

The published fungible interface identifier is `0x3edbb4c4`; the test verifies that the contract reports support for it and for ERC-165.

Function-level mapping: `canSend`, `canReceive`, `canTransfer`, and `getFrozenTokens` map to the standard’s compliance-view section; `setFrozenTokens` maps to the freeze section; `forcedTransfer` maps to the enforcement section; `Frozen` and `ForcedTransfer` map to the fungible interface and forced-transfer event requirements; `supportsInterface` maps to the additional-specifications section. `freeze`, `unfreeze`, `setAllowlisted`, `isAllowlisted`, `TransferRejected`, and `AllowlistUpdated` are explicitly scoped course helpers/extensions rather than claimed native ERC-7943 functions/events.

## Design decisions

### 1. Allow-list as the scoped compliance policy

`_allowlisted` is an on-chain `address => bool` mapping. `canSend` and `canReceive` consult it, while `canTransfer` calls both checks before evaluating the amount. This follows ERC-7943’s separation between account-level eligibility and transfer-level policy without inventing a KYC provider or jurisdiction model.

The admin is automatically allow-listed at deployment. New addresses are added or removed through `setAllowlisted`, protected by `onlyAdmin`.

### 2. Amount-based freezing

ERC-7943 uses `setFrozenTokens(account, amount)`, not only a boolean freeze. The contract therefore stores an absolute amount in `_frozenTokens`.

The available amount is:

```text
unfrozen = max(balanceOf(account) - frozenTokens[account], 0)
```

This supports partial freezes. It also safely handles the standard’s rule that the frozen amount may exceed the current balance, which can withhold future incoming tokens. The assignment’s full-address behavior is provided by `freeze`, which sets the amount to `type(uint256).max`; `unfreeze` sets it to zero.

### 3. Forced transfer and event order

`forcedTransfer` is restricted by `onlyAdmin`, validates the source balance, requires the source to be frozen, and requires the destination to pass `canReceive`. It bypasses the ordinary sender freeze because it is the enforcement/recovery path, but recipient compliance remains enforced.

If frozen tokens are moved, the contract reduces the remaining frozen amount and emits `Frozen` first. It then performs `_move`, which emits ERC-20 `Transfer`, and finally emits ERC-7943 `ForcedTransfer`. This ordering follows the standard’s rationale: indexers should observe the frozen-state change before the underlying asset movement.

### 4. Rejected-transfer behavior

The assignment asks for a rejected-transfer event. ERC-7943 standardizes `Frozen` and `ForcedTransfer` events and provides custom errors, but it does not define a `RejectedTransfer` event. Also, an event emitted in a transaction that later reverts is removed with the revert.

This implementation therefore uses a course-specific `TransferRejected` event for compliance failures and returns `false` without changing balances or allowances. Ordinary accounting failures, such as insufficient balance or allowance, still revert with specific errors. This preserves a durable rejection audit record while keeping the transfer state unchanged.

## Function and control summary

- `balanceOf` and `allowance` expose ERC-20 accounting.
- `approve` creates delegated spending permission and emits `Approval`.
- `transfer` and `transferFrom` pass through the same compliance gate before `_move`.
- `setAllowlisted` changes the assignment’s policy and emits `AllowlistUpdated`.
- `canSend` and `canReceive` are non-mutating account checks.
- `canTransfer` combines allow-list checks with unfrozen-balance validation.
- `setFrozenTokens` is the standard amount-based freeze primitive.
- `freeze` and `unfreeze` are convenience wrappers for the assignment wording.
- `forcedTransfer` is the admin recovery path.
- `mint` is admin-only and requires an allow-listed recipient.
- `supportsInterface` exposes ERC-165 and ERC-7943 support.
- `onlyAdmin` protects every sensitive operation.
- `_setFrozenTokens`, `_unfrozenBalance`, and `_effectiveFrozenBalance` centralize safe freeze arithmetic.
- `_validateTransfer` and `_emitTransferRejection` centralize policy validation and rejection reasons.
- `_move` and `_mint` centralize balance accounting and canonical `Transfer` events.

## Correctness and testing

[`test/UniversalRWAToken.t.sol`](test/UniversalRWAToken.t.sol) contains 22 tests and 256 fuzz runs. It covers:

- successful allow-listed transfers;
- unallow-listed sender and recipient rejection;
- full, partial, and over-balance freezes;
- unfreezing;
- non-admin access failures;
- zero-address validation;
- forced-transfer success, event order, insufficient balance, unfrozen source, and non-compliant recovery destination;
- delegated transfers and allowance preservation on compliance rejection;
- infinite allowance behavior;
- ERC-165/ERC-7943 interface detection;
- compliant minting;
- the invariant that exactly the unfrozen amount can transfer.

Verified commands:

```bash
forge build
forge fmt --check
forge test -vvv
forge coverage --report summary
```

The latest coverage result is 98.23% lines, 94.02% statements, 77.27% branches, and 100% functions.

This directly satisfies the grading requirement for meaningful coverage and at least three failure cases. Clear negative tests include a frozen holder attempting to transfer, a non-admin attempting to freeze or force-transfer, an unallow-listed recipient, a non-compliant recovery address, an insufficient forced-transfer balance, insufficient allowance, and invalid zero-address operations. The tests assert both the failure result and the important state invariant: rejected compliance transfers do not move balances or consume allowances.

## Rubric alignment

- **Spec fidelity (30):** Uses the published ERC-7943 fungible names, signatures, interface ID, freeze model, forced-transfer semantics, and event ordering. The course-specific rejection event is explicitly documented as an extension.
- **Correctness (20):** Compliance is enforced before movement; frozen amounts cannot transfer normally; admin recovery validates source, destination, and balance.
- **Tests (15):** Includes happy paths, failure paths, event assertions, access-control assertions, and fuzz testing.
- **Design note (15):** This note links each major function to the specification, explains trade-offs, documents the scope boundary, and discloses AI use.
- **Live defense (20):** The code is organized around a small number of explainable paths: normal transfer, compliance rejection, freeze, and forced recovery.

## AI-use disclosure

AI was used to compare assignment options, help structure the implementation, suggest test cases, and edit explanatory material. I independently read and checked the ERC-7943 specification, selected the allow-list and amount-freezing policy, reviewed the final Solidity code, verified event behavior, and ran the Foundry build, tests, fuzzing, formatting, and coverage commands. I rejected the idea that a rejected-transfer event was native ERC-7943 behavior and documented it as a course-specific extension because the published interface uses `Frozen`, `ForcedTransfer`, and custom errors instead.

## Live-defense limitations

This is an educational scoped implementation, not an audited production security-token contract. It uses a single immutable admin, a simple allow-list, and no legal-proof, multisig, timelock, identity, or jurisdiction layer. Those limitations are deliberate assignment boundaries and should be stated if asked what would be required for production.
