## Assignment Overview

This repository contains the completed solution for the Assignment. It implements a secure, production-minded `StakingContract` with ERC20 integration, comprehensive testing (unit, fuzz, and invariant), features like upgradability, & pausability and documentation aligned with the assignment requirements in `Assignement.md`.

### Objectives covered (from `Assignement.md`)
- Identify and fix vulnerabilities; apply access control and reentrancy protections
- Implement ERC20-based staking and rewards with safe transfer handling
- Maintain state correctness; `totalStaked` matches the sum of per-user balances
- Provide comprehensive tests: unit, fuzz (1000+ runs), and invariants
- Document design and security considerations

### Repository layout
- `src/StakingContract.sol`: Final secured staking contract
- `src/MockERC20.sol`: Mock token used by tests
- `test` : test files including invarient, unit, flows, and mocks.
- `foundry.toml`: Config with `[fuzz].runs = 1000` and `[invariant].runs = 1000`
- `Assignement.md`: Original assignment brief and evaluation criteria
- `audit.md`: security findings and fixes summary

### Design & security notes (tailored to the assignment)
- Uses checks-effects-interactions on state-mutating functions
- All token interactions use OpenZeppelin `SafeERC20`
- Input validation via custom errors
- Rewards accrue accurately across reward-rate changes via `rateChanges` history

### Upgradability and Pausability
- Upgradability: The contract is implemented with OpenZeppelin `UUPSUpgradeable` and gates `_authorizeUpgrade` behind `onlyOwner`. The initializer accepts `initialOwner`, enabling deployment where the owner is a governance timelock [This is a optimistic assumption and makes the system complete]. A storage gap is reserved for safe future upgrades.
- Pausability: The contract inherits `PausableUpgradeable`. Core user flows (`stake`, `unstake`, `claimRewards`) are `whenNotPaused`. Admin can `pause`/`unpause`. While paused:
  - Users can perform `emergencyUnstake` of principal only if `emergencyWithdrawalsEnabled` is toggled by the owner. This allows controlled exits without reward accrual or period checks.
  - Admin-only emergency sweep requires a timelock: `initiateEmergencyWithdraw` schedules, and after the delay, `emergencyWithdraw` can sweep the contract balance.

#### Why Pausable
- Defense-in-depth for external/token risks: pause if the ERC20 misbehaves (e.g., depeg, transfer anomalies) or if upstream integrations are compromised.
- Accounting or configuration anomalies: pause to prevent further state changes while investigating, without blocking user exits (via emergency unstake).
- Governance upgrades/migrations: use pause during upgrade windows to limit surface area and enable orderly transitions.
- Liquidity management: if the reward reserve is depleted/misconfigured, pausing prevents inconsistent reward claims until corrected.

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

- Run specific test files/suites:

```bash
# Only unit tests in Staking.t.sol
forge test --match-path test/Staking.t.sol

# Only invariant tests (all files under test/invariant)
forge test --match-path "test/invariant/*.t.sol"

# Only flow tests (single file)
forge test --match-path test/flows/UserFlows.t.sol

# Only flow tests (entire folder, if more files are added)
forge test --match-path "test/flows/*.t.sol"
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

### Future scope: Timelock-controlled upgrades and fine-grained access control
- Set an OpenZeppelin `TimelockController` as the `initialOwner` so upgrade authority and admin actions are time-delayed and transparent. With UUPS, the timelock (as owner) becomes the sole upgrader via `_authorizeUpgrade`.
- Introduce `AccessControlUpgradeable` to split duties:
  - `UPGRADER_ROLE`: allowed to initiate upgrades (typically the timelock only).
  - `PAUSER_ROLE`: can pause/unpause rapidly (guardian operations), with the timelock as admin of the role.
  - `RESERVE_MANAGER_ROLE`: can fund/withdraw reward reserve under policy constraints.
  - `PARAMS_ROLE`: can update parameters like reward rate, minimum stake, staking period.
- Governance pattern: Governor → Timelock → Proxy Admin/Owner. Proposals schedule queued operations (upgrades, parameter updates) executed after delay. Pauser/guardian can be a small multisig under timelock administration for quick incident response.
- Operational guides: define proposer/executor roles on the timelock, set minimum delays, and publish an upgrade/migration runbook.

## Test result

### Unit tests
```
Ran 61 tests for test/Staking.t.sol:StakingContractTest
[PASS] testFuzz_CalculateRewards_Monotonic(uint128,uint64,uint64) (runs: 1000, μ: 147468, ~: 147224)
[PASS] testFuzz_ClaimRewards(uint128,uint64) (runs: 1000, μ: 166810, ~: 166312)
[PASS] testFuzz_EmergencyWithdraw_Attempt_Reverts_AndOperationsContinue(uint128,uint128) (runs: 1001, μ: 249712, ~: 249884)
[PASS] testFuzz_MultiActor_TotalStaked(uint128,uint128) (runs: 1000, μ: 212101, ~: 212324)
[PASS] testFuzz_Restake_MultiSegmentAccrual(uint128,uint128,uint64,uint64) (runs: 1000, μ: 182557, ~: 182886)
[PASS] testFuzz_Unstake(uint128,uint128,uint64) (runs: 1000, μ: 188027, ~: 187897)
[PASS] testFuzz_UpdateMinimumStakeAmount_Boundary(uint256) (runs: 1000, μ: 153949, ~: 153706)
[PASS] testFuzz_UpdateRewardRate_Segmented(uint128,uint64,uint64,uint64) (runs: 1001, μ: 242008, ~: 241771)
[PASS] testFuzz_UpdateStakingPeriod_MidStake(uint64,uint64) (runs: 1000, μ: 158460, ~: 158297)
[PASS] test_CalculateRewards_ZeroIfNoStake() (gas: 15761)
[PASS] test_ClaimRewards_DebitsRewardReserve() (gas: 150678)
[PASS] test_Claim_AfterEmergencyWithdraw_Attempt_StillWorks() (gas: 155121)
[PASS] test_Claim_AfterFullyUnstaked_WithBankedRewards() (gas: 185713)
[PASS] test_Claim_Revert_WhenTransferReturnsFalse_Mocked() (gas: 140058)
[PASS] test_Claim_Revert_WhenZeroRewardsButStaking() (gas: 130562)
[PASS] test_Claim_WhileStaking() (gas: 156856)
[PASS] test_Constructor_SetsParamsAndOwner() (gas: 32518)
[PASS] test_EmergencyUnstake_RequiresEnabled_Then_Works() (gas: 193784)
[PASS] test_EmergencyWithdraw_AfterDelay_TransfersAll_AndResetsSchedule() (gas: 116985)
[PASS] test_EmergencyWithdraw_RequiresPaused_And_Owner() (gas: 197736)
[PASS] test_EmergencyWithdraw_Revert_WhenTransferReturnsFalse_Mocked() (gas: 82167)
[PASS] test_FundRewardReserve_IncreasesReserve_AndTransfers() (gas: 84913)
[PASS] test_GetTotalRewards_SumsBankedAndPending() (gas: 173220)
[PASS] test_InitiateEmergencyWithdraw_SetsAvailableAt_AndEmits() (gas: 68492)
[PASS] test_LargeRewardRate_LongTime_CalculateRewards_AtBoundary_DoesNotRevert() (gas: 188133)
[PASS] test_LargeRewardRate_LongTime_CalculateRewards_OverflowReverts() (gas: 188011)
[PASS] test_LargeRewardRate_LongTime_Claim_OverflowReverts() (gas: 189079)
[PASS] test_MultiRateSegments_LongHorizon_ManyChanges_SingleClaim() (gas: 332375)
[PASS] test_MultiRateSegments_ThreeChanges_SingleClaim() (gas: 276200)
[PASS] test_MultiRateSegments_WithRestake_BetweenChanges() (gas: 298702)
[PASS] test_Pause_Blocks_Stake_Unstake_Claim() (gas: 153254)
[PASS] test_REWARD_SCALE_Fallback_WhenNoDecimals() (gas: 3266553)
[PASS] test_Revert_ClaimRewards_InsufficientReserve() (gas: 168138)
[PASS] test_Revert_Claim_WhenNothingToClaim() (gas: 22312)
[PASS] test_Revert_Constructor_ZeroArgs() (gas: 3230649)
[PASS] test_Revert_EmergencyWithdraw_BeforeDelayElapsed() (gas: 67596)
[PASS] test_Revert_EmergencyWithdraw_BeforeSchedule() (gas: 43460)
[PASS] test_Revert_FundRewardReserve_ZeroAmount() (gas: 16371)
[PASS] test_Revert_InitiateEmergencyWithdraw_WhileTimelockPending() (gas: 66796)
[PASS] test_Revert_Stake_AmountTooLow() (gas: 59061)
[PASS] test_Revert_Stake_InsufficientAllowance() (gas: 125847)
[PASS] test_Revert_Unstake_InsufficientBalance() (gas: 124548)
[PASS] test_Revert_Unstake_PeriodNotMet() (gas: 124927)
[PASS] test_Revert_UpdateRewardRate_ZeroRate() (gas: 16284)
[PASS] test_Revert_WithdrawExcessTokens_WhenNone() (gas: 31474)
[PASS] test_Revert_WithdrawExcessTokens_ZeroAmount() (gas: 18853)
[PASS] test_Revert_WithdrawExcessTokens_ZeroTo() (gas: 16645)
[PASS] test_Revert_WithdrawFromRewardReserve_Insufficient() (gas: 25111)
[PASS] test_Revert_WithdrawFromRewardReserve_ZeroToOrAmount() (gas: 28407)
[PASS] test_Stake_AddsPendingRewardsOnRestake() (gas: 166765)
[PASS] test_Stake_Revert_WhenTransferFromReturnsFalse_Mocked() (gas: 123419)
[PASS] test_Stake_SucceedsAndEmits() (gas: 132622)
[PASS] test_Unstake_PartialThenRest() (gas: 175248)
[PASS] test_Unstake_Revert_WhenTransferReturnsFalse_Mocked() (gas: 158252)
[PASS] test_UpdateMinimumStakeAmount() (gas: 45326)
[PASS] test_UpdateRewardRate_OnlyOwnerAndTakesEffect() (gas: 205150)
[PASS] test_UpdateStakingPeriod() (gas: 36196)
[PASS] test_UpgradeProxy_To_V2_And_Call_Version() (gas: 2925377)
[PASS] test_VeryLongPeriod_Claim_Succeeds_WithPrefunding() (gas: 157301)
[PASS] test_WithdrawExcessTokens_OnlyExcess_CapsAmount() (gas: 86784)
[PASS] test_WithdrawFromRewardReserve_DecreasesReserve_AndTransfersTo() (gas: 109336)
Suite result: ok. 61 passed; 0 failed; 0 skipped; finished in 209.00ms (1.41s CPU time)
```

### Flows
```
Ran 4 tests for test/flows/UserFlows.t.sol:UserFlowsTest
[PASS] testFlow_MultiUser_Interleaved() (gas: 239320)
[PASS] testFlow_MultipleStakes_PartialUnstake_ThenClaim() (gas: 191704)
[PASS] testFlow_Stake_Claim_Continue_Unstake() (gas: 171500)
[PASS] testFlow_Stake_Wait_Unstake_Claim() (gas: 189063)
Suite result: ok. 4 passed; 0 failed; 0 skipped; finished in 1.34ms (1.29ms CPU time)
```

### Invarient
```
[PASS] invariant_rewardsCalculationConsistent() (runs: 1000, calls: 500000, reverts: 0)

╭---------------+-------------+--------+---------+----------╮
| Contract      | Selector    | Calls  | Reverts | Discards |
+===========================================================+
| SystemHandler | claim       | 124997 | 0       | 0        |
|---------------+-------------+--------+---------+----------|
| SystemHandler | stakeSome   | 125531 | 0       | 0        |
|---------------+-------------+--------+---------+----------|
| SystemHandler | unstakeSome | 124643 | 0       | 0        |
|---------------+-------------+--------+---------+----------|
| SystemHandler | warpTime    | 124829 | 0       | 0        |
╰---------------+-------------+--------+---------+----------╯

[PASS] invariant_stateConsistency() (runs: 1000, calls: 500000, reverts: 0)

╭---------------+-------------+--------+---------+----------╮
| Contract      | Selector    | Calls  | Reverts | Discards |
+===========================================================+
| SystemHandler | claim       | 124997 | 0       | 0        |
|---------------+-------------+--------+---------+----------|
| SystemHandler | stakeSome   | 125531 | 0       | 0        |
|---------------+-------------+--------+---------+----------|
| SystemHandler | unstakeSome | 124643 | 0       | 0        |
|---------------+-------------+--------+---------+----------|
| SystemHandler | warpTime    | 124829 | 0       | 0        |
╰---------------+-------------+--------+---------+----------╯

[PASS] invariant_totalStakedEqualsSum() (runs: 1000, calls: 500000, reverts: 0)

╭---------------+-------------+--------+---------+----------╮
| Contract      | Selector    | Calls  | Reverts | Discards |
+===========================================================+
| SystemHandler | claim       | 124997 | 0       | 0        |
|---------------+-------------+--------+---------+----------|
| SystemHandler | stakeSome   | 125531 | 0       | 0        |
|---------------+-------------+--------+---------+----------|
| SystemHandler | unstakeSome | 124643 | 0       | 0        |
|---------------+-------------+--------+---------+----------|
| SystemHandler | warpTime    | 124829 | 0       | 0        |
╰---------------+-------------+--------+---------+----------╯

Suite result: ok. 3 passed; 0 failed; 0 skipped; finished in 305.74s (705.44s CPU time)
```
## Relevant Coverage results - [excluding initial contract]

```
╭-------------------------------------------+------------------+------------------+----------------+----------------╮
| File                                      | % Lines          | % Statements     | % Branches     | % Funcs        |
+===================================================================================================================+
| script/Staking.s.sol                      | 0.00% (0/7)      | 0.00% (0/6)      | 100.00% (0/0)  | 0.00% (0/2)    |
|-------------------------------------------+------------------+------------------+----------------+----------------|
| src/MockERC20.sol                         | 100.00% (2/2)    | 100.00% (1/1)    | 100.00% (0/0)  | 100.00% (1/1)  |
|-------------------------------------------+------------------+------------------+----------------+----------------|
| src/StakingContract.sol                   | 98.16% (160/163) | 97.92% (188/192) | 91.67% (33/36) | 95.00% (19/20) |
|-------------------------------------------+------------------+------------------+----------------+----------------|
| test/invariant/SystemInvariants.t.sol     | 100.00% (45/45)  | 98.41% (62/63)   | 83.33% (5/6)   | 100.00% (6/6)  |
|-------------------------------------------+------------------+------------------+----------------+----------------|
| test/invariant/TotalStakedInvariant.t.sol | 100.00% (22/22)  | 100.00% (25/25)  | 100.00% (1/1)  | 100.00% (3/3)  |
|-------------------------------------------+------------------+------------------+----------------+----------------|
| test/mocks/StakingContractV2.sol          | 100.00% (2/2)    | 100.00% (1/1)    | 100.00% (0/0)  | 100.00% (1/1)  |
╰-------------------------------------------+------------------+------------------+----------------+----------------╯
```
