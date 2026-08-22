# Contributing to OpenFund Protocol

Thanks for your interest in improving OpenFund Protocol. This guide covers how to
set up the project, run the tests, and structure a pull request.

## Prerequisites

- [Foundry](https://book.getfoundry.sh/) (forge, cast, anvil)
- Git

Install Foundry:

```bash
curl -L https://foundry.paradigm.xyz | bash
foundryup
```

## Getting started

Clone the repository with submodules (dependencies live in `lib/`):

```bash
git clone --recurse-submodules https://github.com/OpenFund-Protocol/openfund-contracts
cd openfund-contracts
```

If you already cloned without submodules:

```bash
git submodule update --init --recursive
```

Build the contracts:

```bash
forge build
```

## Running tests

```bash
# Run the full suite
forge test

# More detailed traces on failure
forge test -vvv

# Run a single contract's tests
forge test --match-contract FundingStreamTest

# Gas snapshots
forge snapshot
```

## Project layout

```
contracts/   Solidity sources
  ContributorRegistry.sol   Identity and role management
    FundingStream.sol         Linear vesting / recurring payments
      SplitManager.sol          Revenue splitting with pull-based claims
        MilestoneVault.sol        Escrow with validator-gated milestone releases
        test/        Foundry tests (mirrors contracts/)
        script/      Deployment scripts
        lib/         Dependencies (forge-std, openzeppelin-contracts)
        ```

        ## Coding standards

        - Solidity `^0.8.24`.
        - Formatting is enforced with `forge fmt` (config in `foundry.toml`: 100-column lines, 4-space indent, double quotes). Run `forge fmt` before committing.
        - Follow the existing NatSpec style: `@notice` / `@dev` / `@param` / `@return` on public and external functions.
        - Favor custom errors over `require` strings, and follow checks-effects-interactions for any external calls or transfers.

        ## Submitting a pull request

        1. Fork the repo and create a topic branch (e.g. `feat/...`, `fix/...`, `docs/...`).
        2. Make your change and add or update tests under `test/`.
        3. Make sure `forge build`, `forge test`, and `forge fmt --check` all pass.
        4. Open a PR against `main` with a clear description. Link the issue it addresses with `Closes #<issue>`.
        5. Keep PRs focused - one logical change per PR is easier to review.

        By contributing, you agree that your contributions are licensed under the MIT License, the same license that covers this repository.
        
