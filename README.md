## Assignment Overview

This repository contains the completed solution for the Assignment. It implements a secure, production-minded `StakingContract` with ERC20 integration, comprehensive testing (unit, fuzz, and invariant), and documentation aligned with the assignment requirements in `Assignement.md`.

### Objectives covered (from `Assignement.md`)
- Identify and fix vulnerabilities; apply access control and reentrancy protections
- Implement ERC20-based staking and rewards with safe transfer handling
- Maintain state correctness; `totalStaked` matches the sum of per-user balances
- Provide comprehensive tests: unit, fuzz (1000+ runs), and invariants
- Document design and security considerations

### Repository layout
- `src/StakingContract.sol`: Final secured staking contract
- `src/MockERC20.sol`: Mock token used by tests
- `test/Staking.t.sol`: Unit and integration tests for staking flows and edge cases
- `test/invariant/TotalStakedInvariant.t.sol`: Invariant test ensuring accounting correctness
- `foundry.toml`: Config with `[fuzz].runs = 1000` and `[invariant].runs = 1000`
- `Assignement.md`: Original assignment brief and evaluation criteria
- `audit.md`: security findings and fixes summary

### Design & security notes (tailored to the assignment)
- Uses checks-effects-interactions and `nonReentrant` on external state-mutating functions
- All token interactions use OpenZeppelin `SafeERC20`
- Input validation via custom errors
- Rewards accrue accurately across reward-rate changes via `rateChanges` history
- Owner may update parameters; centralization/trust assumptions are documented in `audit.md`
- `emergencyWithdraw` transfers the contract's token balance to the owner

### Testing strategy alignment
- Unit tests cover happy paths, reverts, edge cases, access control, and event emissions
- Fuzz configuration set to 1000 runs & tests fuzz critical functions
- Invariant test enforces `totalStaked == sum(user balances)` for randomized actions
- Coverage reporting enabled with `forge coverage` and `lcov` HTML for better readability

### Assumptions
- Rewards are paid from the same ERC20 token as staked and require prefunding the contract
- Users must `approve` the staking contract before calling `stake`
- Partial unstaking is supported; timers reset according to current stake status

## Project Setup

### Prerequisites
- Install Foundry (forge, cast, anvil):

```bash
curl -L https://foundry.paradigm.xyz | bash
foundryup
```

### Install Dependencies (if any)
- If the project uses git submodules or external libs, run:

```bash
forge install
```

## Build / Run

```bash
forge build
```

## Test

- Run all tests:

```bash
forge test
```

- With more logging/trace:

```bash
forge test -vvv
```

- Only invariant tests (if present under `test/invariant`):

```bash
forge test --match-path test/invariant/*
```

## Coverage

- Quick coverage summary:

```bash
forge coverage
```

- Generate lcov report (creates `lcov.info` in the project root):

```bash
forge coverage --report lcov
```

- (Optional) Create HTML report from lcov:

```bash
sudo apt install lcov

genhtml lcov.info -o coverage-html/

open coverage-html/index.html in browser
```

## Useful Extras

- Format Solidity files:

```bash
forge fmt
```

- Snapshot gas costs:

```bash
forge snapshot
```


