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

## Test result
```
Ran 57 tests for test/Staking.t.sol:StakingContractTest
[PASS] testFuzz_CalculateRewards_Monotonic(uint128,uint64,uint64) (runs: 1000, μ: 137453, ~: 137316)
[PASS] testFuzz_ClaimRewards(uint128,uint64) (runs: 1000, μ: 156243, ~: 155735)
[PASS] testFuzz_EmergencyWithdraw_NoExcess_Reverts_AndOperationsContinue(uint128,uint128) (runs: 1000, μ: 272136, ~: 272303)
[PASS] testFuzz_MultiActor_TotalStaked(uint128,uint128) (runs: 1000, μ: 203477, ~: 203686)
[PASS] testFuzz_Restake_MultiSegmentAccrual(uint128,uint128,uint64,uint64) (runs: 1000, μ: 172206, ~: 172609)
[PASS] testFuzz_Unstake(uint128,uint128,uint64) (runs: 1000, μ: 176651, ~: 176510)
[PASS] testFuzz_UpdateMinimumStakeAmount_Boundary(uint256) (runs: 1000, μ: 148594, ~: 148475)
[PASS] testFuzz_UpdateRewardRate_Segmented(uint128,uint64,uint64,uint64) (runs: 1001, μ: 230728, ~: 230492)
[PASS] testFuzz_UpdateStakingPeriod_MidStake(uint64,uint64) (runs: 1000, μ: 157020, ~: 156898)
[PASS] test_CalculateRewards_ZeroIfNoStake() (gas: 10699)
[PASS] test_ClaimRewards_DebitsRewardReserve() (gas: 140155)
[PASS] test_Claim_AfterEmergencyWithdraw_NoExcess_StillWorks() (gas: 155515)
[PASS] test_Claim_AfterFullyUnstaked_WithBankedRewards() (gas: 183424)
[PASS] test_Claim_Revert_WhenTransferReturnsFalse_Mocked() (gas: 133618)
[PASS] test_Claim_Revert_WhenZeroRewardsButStaking() (gas: 124237)
[PASS] test_Claim_WhileStaking() (gas: 146794)
[PASS] test_Constructor_SetsParamsAndOwner() (gas: 23348)
[PASS] test_EmergencyWithdraw_AfterDelay_TransfersOnlyExcess_AndResetsSchedule() (gas: 86020)
[PASS] test_EmergencyWithdraw_NoExcess_RevertsNoExcessTokens() (gas: 138997)
[PASS] test_EmergencyWithdraw_Revert_WhenTransferReturnsFalse_Mocked() (gas: 41636)
[PASS] test_FundRewardReserve_IncreasesReserve_AndTransfers() (gas: 82939)
[PASS] test_GetTotalRewards_SumsBankedAndPending() (gas: 162398)
[PASS] test_InitiateEmergencyWithdraw_SetsAvailableAt_AndEmits() (gas: 37383)
[PASS] test_LargeRewardRate_LongTime_CalculateRewards_AtBoundary_DoesNotRevert() (gas: 178253)
[PASS] test_LargeRewardRate_LongTime_CalculateRewards_OverflowReverts() (gas: 178149)
[PASS] test_LargeRewardRate_LongTime_Claim_OverflowReverts() (gas: 182206)
[PASS] test_MultiRateSegments_LongHorizon_ManyChanges_SingleClaim() (gas: 318251)
[PASS] test_MultiRateSegments_ThreeChanges_SingleClaim() (gas: 263192)
[PASS] test_MultiRateSegments_WithRestake_BetweenChanges() (gas: 285037)
[PASS] test_REWARD_SCALE_Fallback_WhenNoDecimals() (gas: 1983533)
[PASS] test_Revert_ClaimRewards_InsufficientReserve() (gas: 161394)
[PASS] test_Revert_Claim_WhenNothingToClaim() (gas: 20305)
[PASS] test_Revert_Constructor_ZeroArgs() (gas: 334143)
[PASS] test_Revert_EmergencyWithdraw_BeforeDelayElapsed() (gas: 41489)
[PASS] test_Revert_EmergencyWithdraw_BeforeSchedule() (gas: 18128)
[PASS] test_Revert_FundRewardReserve_ZeroAmount() (gas: 16638)
[PASS] test_Revert_Stake_AmountTooLow() (gas: 57094)
[PASS] test_Revert_Stake_InsufficientAllowance() (gas: 121712)
[PASS] test_Revert_Unstake_InsufficientBalance() (gas: 120424)
[PASS] test_Revert_Unstake_PeriodNotMet() (gas: 120809)
[PASS] test_Revert_UpdateRewardRate_ZeroRate() (gas: 11235)
[PASS] test_Revert_WithdrawExcessTokens_WhenNone() (gas: 29582)
[PASS] test_Revert_WithdrawExcessTokens_ZeroAmount() (gas: 19183)
[PASS] test_Revert_WithdrawExcessTokens_ZeroTo() (gas: 16976)
[PASS] test_Revert_WithdrawFromRewardReserve_Insufficient() (gas: 24537)
[PASS] test_Revert_WithdrawFromRewardReserve_ZeroToOrAmount() (gas: 28757)
[PASS] test_Stake_AddsPendingRewardsOnRestake() (gas: 156815)
[PASS] test_Stake_Revert_WhenTransferFromReturnsFalse_Mocked() (gas: 119293)
[PASS] test_Stake_SucceedsAndEmits() (gas: 124605)
[PASS] test_Unstake_PartialThenRest() (gas: 171341)
[PASS] test_Unstake_Revert_WhenTransferReturnsFalse_Mocked() (gas: 135448)
[PASS] test_UpdateMinimumStakeAmount() (gas: 29774)
[PASS] test_UpdateRewardRate_OnlyOwnerAndTakesEffect() (gas: 189681)
[PASS] test_UpdateStakingPeriod() (gas: 25674)
[PASS] test_VeryLongPeriod_Claim_Succeeds_WithPrefunding() (gas: 147755)
[PASS] test_WithdrawExcessTokens_OnlyExcess_CapsAmount() (gas: 81671)
[PASS] test_WithdrawFromRewardReserve_DecreasesReserve_AndTransfersTo() (gas: 109559)
Suite result: ok. 57 passed; 0 failed; 0 skipped; finished in 945.91ms (3.05s CPU time)
```
## Coverage results

![Test Coverage Output](https://github.com/Rushikesh0125/staking-fix/blob/master/Coverage.png?raw=true)
