### Improvements in StakingContract vs StakingContractInitial

This document summarizes the key improvements made in `src/StakingContract.sol` compared to `src/initial/StakingContractInitial.sol`.


### Architecture and State Layout
- **Consolidated user state**: Replaced four separate mappings with a single `mapping(address => Stake)` holding `balance`, `rewardBalance`, and `lastStakeTime`. This reduces storage reads/writes and improves clarity.
- **Reward rate history**: Added `RateChange[] rateChanges` and track each update with `changeTime`. Rewards are computed across historical segments instead of retroactively applying the latest rate.
- **Token-decimal aware scaling**: Introduced immutable `REWARD_SCALE` determined from `IERC20Metadata.decimals()` (fallback to 1e18). All reward math uses this scale instead of a hardcoded 1e18.


### Correctness of Reward Accounting
- **Time-segmented accrual**: `calculateRewards` accrues over each period bounded by rate-change timestamps using the correct rate for each segment. A binary search finds the effective starting rate efficiently.
- **No retroactive rate changes**: Updating the reward rate now affects only time after the change. Previously, users could unintentionally earn at the new rate for past time.
- **Claim without active stake**: Users can claim rewards even after fully unstaking if they have a nonzero `rewardBalance` (previously blocked by `isStaking` checks).
- **Preserve rewards on full unstake**: On full unstake, `lastStakeTime` is reset but `rewardBalance` is preserved for later claim.
- **Accurate time management**: `lastStakeTime` is consistently updated on stake, partial-unstake, and claim to ensure precise accrual windows.


### Security and Safety
- **Reentrancy protection**: All external methods that move tokens (`stake`, `unstake`, `claimRewards`, reserve withdrawals, emergency/excess withdrawals) use `nonReentrant`.
- **Safer transfers**: Uses `SafeERC20` for all token transfers.
- **Access control via Ownable**: Inherits `Ownable` instead of manually tracking an `owner` address.
- **Timelocked emergency withdrawal**: `initiateEmergencyWithdraw` schedules `emergencyWithdraw` after a delay. Emergency withdraw is not immediate and cannot touch principal or reserved rewards.
- **No draining of user funds**: Emergency and excess withdrawals only transfer tokens above the accounted amount (`totalStaked + rewardReserve`), preventing principal/reward theft.


### Token Accounting and Funds Separation
- **Dedicated reward reserve**: Introduced `rewardReserve` to segregate reward liquidity from user principal.
  - `fundRewardReserve` (owner) to add liquidity for rewards.
  - `withdrawFromRewardReserve` (owner) to remove reward liquidity (bounded by available reserve).
  - `claimRewards` checks and decrements `rewardReserve` to ensure claims never deplete principal.
- **Excess token withdrawal**: `withdrawExcessTokens` (owner) lets the owner retrieve tokens only if the contract holds more than `totalStaked + rewardReserve`.
- **Visibility**: `contractBalance()` exposes the accounted balance requirement (principal + reserve).


### Validation and Developer Experience
- **Constructor validation**: Enforces nonzero `_rewardRate`, `_minimumStakeAmount`, `_stakingPeriod`, and nonzero `_token` address.
- **Admin update validation**: `updateRewardRate` and `updateMinimumStakeAmount` validate inputs. Events are emitted for observability.
- **Clear revert reasons via custom errors**: Replaced string-based requires with custom errors (e.g., `AmountTooLow`, `InsufficientStakedBalance`, `InsufficientRewardReserve`, `NoExcessTokens`) which are cheaper and more precise.
- **Minimum stake logic**: Minimum is enforced only on the first stake; top-ups are allowed without re-checking the minimum.


### Gas and Performance
- **Storage packing**: Consolidated user state into a struct, reducing SLOAD/SSTORE operations.
- **Custom errors**: Lower gas than string revert reasons.
- **Efficient rate lookup**: Binary search over `rateChanges` to find the starting segment, then a single forward pass.
- **Targeted unchecked blocks**: Safe, localized `unchecked` math where bounds are proven (e.g., reserve decrements), reducing gas.


### Events and Observability
- Added events to improve monitoring and off-chain indexing:
  - `RewardRateUpdated`, `MinimumStakeAmountUpdated`, `StakingPeriodUpdated`
  - `RewardReserveFunded`, `RewardReserveWithdrawn`
  - `ExcessTokensWithdrawn`
  - `EmergencyWithdrawScheduled`, `EmergencyWithdraw`


### Behavioral Changes to Note
- **Rewards are decoupled from active staking**: You can claim accrued rewards after fully unstaking.
- **Admin must fund the reward reserve**: `claimRewards` will revert with `InsufficientRewardReserve` if not enough reserve is available.
- **Emergency withdrawals are timelocked and limited**: Only excess tokens are withdrawable after the delay; user principal and reward reserve remain safe.


### Reward Accrual Formula (conceptual)
Over the interval \([t_0, t_n]\) partitioned by rate-change times, rewards are:
\( \sum_i \text{stakedAmount} \times \text{rate}_i \times (t_{i+1}-t_i) / \text{REWARD\_SCALE} \).


### Summary
`src/StakingContract.sol` strengthens security (reentrancy guard, timelock, access control), fixes reward-accounting correctness across rate changes, separates reward liquidity from principal, improves gas efficiency, and enhances observability and admin ergonomics compared to `src/initial/StakingContractInitial.sol`.

