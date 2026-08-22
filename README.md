# OpenFund Protocol — Smart Contracts

On-chain funding infrastructure for open-source projects. OpenFund enables continuous funding streams, contributor revenue splits, and milestone-based payouts — all non-custodial, permissionless, and auditable on-chain.

---

## Architecture

```
contracts/
├── ContributorRegistry.sol   — Identity and role management
├── FundingStream.sol         — Linear vesting / recurring payments
├── SplitManager.sol          — Revenue splitting with pull-based claims
└── MilestoneVault.sol        — Escrow with validator-gated milestone releases

test/
├── ContributorRegistry.t.sol
├── FundingStream.t.sol
├── MilestoneVault.t.sol
├── SplitManager.t.sol
└── mocks/
    └── ERC20Mock.sol

script/
├── Deploy.s.sol              — Full protocol deployment
└── CreateStream.s.sol        — Example stream creation
```

### Contract Summaries

#### `ContributorRegistry`
Central identity store for protocol participants. Registrars assign contributors to projects with a role (`CONTRIBUTOR`, `MAINTAINER`, `ADMIN`) and a weight in basis points. Other contracts reference this registry to validate identities without duplicating contributor data.

Key functions: `register`, `update`, `deactivate`, `reactivate`

#### `FundingStream`
Linear vesting of ETH or ERC-20 tokens from a sender to a recipient over a fixed time window. Supports:
- ETH and ERC-20 streams (separate create functions)
- Top-up (anyone can add more funds to an active stream)
- Partial withdrawals at any point during the stream
- Sender cancellation with proportional fund recovery
- Protocol-level stream pausing via `STREAM_MANAGER_ROLE`

Vesting formula: `vestedAmount = totalDeposited * elapsed / duration`

#### `SplitManager`
Defines per-project revenue splits as basis-point arrays (must sum to 10,000). Operates as a pull-payment system:
1. An admin defines a split (e.g. `[alice: 5000, bob: 3000, treasury: 2000]`)
2. Anyone calls `distributeETH` or `distributeERC20` to credit payees internally
3. Each payee calls `claim` or `claimMultiple` to withdraw their balance

Integer-division dust is credited to the first payee. Supports multiple independent tokens per project.

#### `MilestoneVault`
Escrow contract that locks funds until a validator approves deliverables:
1. Funder creates a vault and deposits ETH or ERC-20
2. Funder adds milestones (ordered, each with an amount and off-chain URI)
3. Recipient submits milestones in sequence for review
4. Validator approves (releases funds) or rejects (resets to Pending for rework)
5. Funder can cancel at any point unless a milestone is under review; unreleased funds return to funder

---

## Roles

| Role | Contract | Capabilities |
|---|---|---|
| `DEFAULT_ADMIN_ROLE` | All | Grant/revoke roles, pause/unpause |
| `REGISTRAR_ROLE` | ContributorRegistry | Register/update contributors |
| `SPLIT_ADMIN_ROLE` | SplitManager | Define/update splits |
| `STREAM_MANAGER_ROLE` | FundingStream | Pause/resume streams |
| `VAULT_ADMIN_ROLE` | MilestoneVault | Cancel vaults (override) |
| Vault `funder` | MilestoneVault | Add milestones, cancel, update validator |
| Vault `validator` | MilestoneVault | Approve/reject milestones |
| Stream `sender` | FundingStream | Cancel streams |
| Stream `recipient` | FundingStream | Withdraw vested funds |

---

## Getting Started

### Prerequisites

```bash
curl -L https://foundry.paradigm.xyz | bash
foundryup
```

### Install dependencies

```bash
forge install
```

### Build

```bash
forge build
```

### Test

```bash
# Run all tests
forge test

# Verbose output
forge test -vvv

# Run a specific contract's tests
forge test --match-contract FundingStreamTest

# Gas snapshots
forge snapshot
```

### Deploy (local)

```bash
# Start local node
anvil

# Deploy all contracts (uses msg.sender as admin)
forge script script/Deploy.s.sol --rpc-url http://localhost:8545 --broadcast
```

### Deploy (testnet)

```bash
# Set environment variables
export ADMIN_ADDRESS=0x...
export SEPOLIA_RPC_URL=https://...
export PRIVATE_KEY=0x...
export ETHERSCAN_API_KEY=...

forge script script/Deploy.s.sol \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast \
  --verify \
  --etherscan-api-key $ETHERSCAN_API_KEY
```

---

## Example Flows

### Create a 30-day ETH funding stream

```solidity
// 1 ETH vests linearly to recipient over 30 days
fundingStream.createETHStream{value: 1 ether}(
    recipient,
    uint48(block.timestamp + 1 hours), // start
    uint48(block.timestamp + 31 days)  // end
);
```

### Define a project split and distribute revenue

```solidity
SplitManager.PayeeShare[] memory payees = new SplitManager.PayeeShare[](3);
payees[0] = SplitManager.PayeeShare({payee: dev,        bps: 5000}); // 50%
payees[1] = SplitManager.PayeeShare({payee: maintainer, bps: 3000}); // 30%
payees[2] = SplitManager.PayeeShare({payee: treasury,   bps: 2000}); // 20%

splitManager.defineSplit(PROJECT_ID, payees);

// Later, distribute incoming revenue
splitManager.distributeETH{value: 1 ether}(PROJECT_ID);

// Each payee claims their share
splitManager.claim(address(0)); // ETH
```

### Create a milestone-gated vault

```solidity
// Funder creates vault with 3 ETH
uint256 vaultId = milestoneVault.createETHVault{value: 3 ether}(recipient, validator);

// Three milestones of 1 ETH each
milestoneVault.addMilestone(vaultId, 1 ether, "ipfs://spec-phase-1");
milestoneVault.addMilestone(vaultId, 1 ether, "ipfs://spec-phase-2");
milestoneVault.addMilestone(vaultId, 1 ether, "ipfs://spec-phase-3");

// Recipient submits work for each phase; validator approves
milestoneVault.submitMilestone(vaultId, 0);   // recipient
milestoneVault.approveMilestone(vaultId, 0);  // validator -- releases 1 ETH
```

---

## Security Considerations

- **Reentrancy**: All ETH/token transfers use `ReentrancyGuard` or follow checks-effects-interactions.
- **Access control**: OpenZeppelin `AccessControl` -- no single owner, roles are independently granular.
- **Integer overflow**: Solidity 0.8.x built-in overflow checks + `unchecked` only in provably safe loops.
- **Safe transfers**: ERC-20 transfers use OpenZeppelin `SafeERC20` to handle non-standard tokens.
- **Pausability**: All state-changing paths respect `Pausable` for emergency circuit breaking.
- **Fee-on-transfer tokens**: Not supported. Amounts credited assume 1:1 transfer fidelity.
- **Rebasing tokens**: Not supported. Use wrapped equivalents.
- **`block.timestamp`**: Used for stream vesting. Validator manipulation window is bounded by the Ethereum slot time (12s) -- acceptable for streams measured in days/months.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for how to set up the project, run the tests, and open a pull request.

---

## License

MIT
