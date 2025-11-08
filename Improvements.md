### Improvements in StakingContract vs StakingContractInitial

This document summarizes the key improvements made in `src/StakingContract.sol` compared to `src/initial/StakingContractInitial.sol`.


### Architecture and State Layout
- **Consolidated user state**: Replaced four separate mappings with a single `mapping(address => Stake)` holding `balance`, `rewardBalance`, and `lastStakeTime`. This reduces storage reads/writes and improves clarity.

- New
```15:20:src/StakingContract.sol
struct Stake {
    uint256 balance;
    uint256 rewardBalance;
    uint256 lastStakeTime;
}
```

- New
```31:33:src/StakingContract.sol
mapping(address => Stake) public stakes;
```
- Previous
```19:24:src/initial/StakingContractInitial.sol
mapping(address => uint256) public stakedBalances;
mapping(address => uint256) public rewardBalances;
mapping(address => uint256) public lastStakeTime;
mapping(address => bool) public isStaking;
```
- **Reward rate history**: Added `RateChange[] rateChanges` and track each update with `changeTime`. Rewards are computed across historical segments instead of retroactively applying the latest rate.

- New
```22:26:src/StakingContract.sol
struct RateChange {
    uint256 newRate;
    uint256 changeTime;
}
```

- New
```34:36:src/StakingContract.sol
RateChange[] public rateChanges;
```

- New
```99:104:src/StakingContract.sol
REWARD_SCALE = scale;
rateChanges.push(RateChange({
    newRate: rewardRate,
    changeTime: block.timestamp
}));
```

- New
```300:307:src/StakingContract.sol
function updateRewardRate(uint256 newRate) external onlyOwner {
    if(newRate == 0) revert InvalidRewardRate();
    rewardRate = newRate;
    rateChanges.push(RateChange({ newRate: newRate, changeTime: block.timestamp }));
    emit RewardRateUpdated(newRate);
}
```

- Previous
```167:173:src/initial/StakingContractInitial.sol
function updateRewardRate(uint256 newRate) external onlyOwner {
    rewardRate = newRate;
    emit RewardRateUpdated(newRate);
}
```
- **Token-decimal aware scaling**: Introduced immutable `REWARD_SCALE` determined from `IERC20Metadata.decimals()` (fallback to 1e18). All reward math uses this scale instead of a hardcoded 1e18.

```41:43:src/StakingContract.sol
uint256 public rewardReserve; /// Tokens set aside to pay rewards, separate from principal.
uint256 public immutable REWARD_SCALE; /// Scaling factor for reward rate, typically 10**tokenDecimals.
```

```90:99:src/StakingContract.sol
// Determine reward scaling factor from token decimals; default to 18 if decimals() is unavailable
uint256 scale;
unchecked {
    try IERC20Metadata(_token).decimals() returns (uint8 dec) {
        scale = 10 ** uint256(dec);
    } catch {
        scale = 1e18;
    }
}
REWARD_SCALE = scale;
```

```145:152:src/initial/StakingContractInitial.sol
function calculateRewards(address user) public view returns (uint256) {
    if (!isStaking[user] || stakedBalances[user] == 0) {
        return 0;
    }
    uint256 timeStaked = block.timestamp - lastStakeTime[user];
    return (stakedBalances[user] * rewardRate * timeStaked) / 1e18;
}
```


### Correctness of Reward Accounting
- **Time-segmented accrual**: `calculateRewards` accrues over each period bounded by rate-change timestamps using the correct rate for each segment. A binary search finds the effective starting rate efficiently.

```228:280:src/StakingContract.sol
// Binary search to find the effective rate at the start when the user started staking
uint256 currentRate;
uint256 startIdx;
// ...
while (left < right) {
    uint256 mid = left + (right - left + 1) / 2;
    if (rateChanges[mid].changeTime <= startTime) {
        left = mid;
    } else {
        right = mid - 1;
    }
}
currentRate = rateChanges[left].newRate;
startIdx = left + 1;
// ...
for (uint256 i = startIdx; i < length; ++i) {
    uint256 changeTime = rateChanges[i].changeTime;
    uint256 segmentDuration;
    unchecked { segmentDuration = changeTime - cursor; }
    accrued += (stakedAmount * currentRate * segmentDuration) / REWARD_SCALE;
    cursor = changeTime;
    currentRate = rateChanges[i].newRate;
}
// Final segment
uint256 segmentDuration;
unchecked { segmentDuration = endTime - cursor; }
accrued += (stakedAmount * currentRate * segmentDuration) / REWARD_SCALE;
```
- **No retroactive rate changes**: Updating the reward rate now affects only time after the change. Previously, users could unintentionally earn at the new rate for past time.

```300:307:src/StakingContract.sol
function updateRewardRate(uint256 newRate) external onlyOwner {
    if(newRate == 0) revert InvalidRewardRate();
    rewardRate = newRate;
    rateChanges.push(RateChange({ newRate: newRate, changeTime: block.timestamp }));
    emit RewardRateUpdated(newRate);
}
```

```167:172:src/initial/StakingContractInitial.sol
function updateRewardRate(uint256 newRate) external onlyOwner {
    rewardRate = newRate;
    // users would now claim at the new rate for past time
    emit RewardRateUpdated(newRate);
}
```
- **Claim without active stake**: Users can claim rewards even after fully unstaking if they have a nonzero `rewardBalance` (previously blocked by `isStaking` checks).

```176:188:src/StakingContract.sol
function claimRewards() external nonReentrant {
    Stake memory userStake = stakes[msg.sender];
    if (userStake.balance == 0 && userStake.rewardBalance == 0) revert NoRewardsToClaim();
    uint256 pendingRewards = calculateRewards(msg.sender);
    uint256 totalRewards = userStake.rewardBalance + pendingRewards;
    if (totalRewards == 0) revert NoRewardsToClaim();
    // ...
}
```

Previous
```120:128:src/initial/StakingContractInitial.sol
function claimRewards() external {
    require(isStaking[msg.sender], "Not staking");
    uint256 pendingRewards = calculateRewards(msg.sender);
    uint256 totalRewards = rewardBalances[msg.sender] + pendingRewards;
    require(totalRewards > 0, "No rewards to claim");
    // ...
}
```
- **Preserve rewards on full unstake**: On full unstake, `lastStakeTime` is reset but `rewardBalance` is preserved for later claim.

```148:161:src/StakingContract.sol
uint256 pendingRewards = calculateRewards(msg.sender);
userStake.rewardBalance += pendingRewards;
// ...
userStake.balance -= amount;
// Reset time if fully unstaked but preserve rewardBalance for later claim
if (userStake.balance == 0) {
    userStake.lastStakeTime = 0;
} else {
    userStake.lastStakeTime = block.timestamp;
}
```

```103:109:src/initial/StakingContractInitial.sol
if (stakedBalances[msg.sender] == 0) {
    isStaking[msg.sender] = false;
    lastStakeTime[msg.sender] = 0;
} else {
    lastStakeTime[msg.sender] = block.timestamp;
}
```
- **Accurate time management**: `lastStakeTime` is consistently updated on stake, partial-unstake, and claim to ensure precise accrual windows.

```115:127:src/StakingContract.sol
Stake memory userStake = stakes[msg.sender];
if (userStake.balance == 0 && amount < minimumStakeAmount) revert AmountTooLow();
if (userStake.balance > 0) {
    uint256 pendingRewards = calculateRewards(msg.sender);
    userStake.rewardBalance += pendingRewards;
}
userStake.lastStakeTime = block.timestamp;
userStake.balance += amount;
```

```72:77:src/initial/StakingContractInitial.sol
} else {
    // New staker
    isStaking[msg.sender] = true;
    lastStakeTime[msg.sender] = block.timestamp;
}
```


### Security and Safety
- **Reentrancy protection**: All external methods that move tokens (`stake`, `unstake`, `claimRewards`, reserve withdrawals, emergency/excess withdrawals) use `nonReentrant`.

```110:134:src/StakingContract.sol
function stake(uint256 amount) external nonReentrant {
    // ...
    STAKING_TOKEN.safeTransferFrom(msg.sender, address(this), amount);
}
```

```141:171:src/StakingContract.sol
function unstake(uint256 amount) external nonReentrant {
    // ...
    STAKING_TOKEN.safeTransfer(msg.sender, amount);
}
```

```176:208:src/StakingContract.sol
function claimRewards() external nonReentrant {
    // ...
    STAKING_TOKEN.safeTransfer(msg.sender, totalRewards);
}
```
- **Safer transfers**: Uses `SafeERC20` for all token transfers.
- **Access control via Ownable**: Inherits `Ownable` instead of manually tracking an `owner` address.

```10:14:src/StakingContract.sol
contract StakingContract is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    // ...
}
```

```29:40:src/initial/StakingContractInitial.sol
address public owner;
// ...
modifier onlyOwner() {
    require(msg.sender == owner, "Not owner");
    _;
}
```
- **Timelocked emergency withdrawal**: `initiateEmergencyWithdraw` schedules `emergencyWithdraw` after a delay. Emergency withdraw is not immediate and cannot touch principal or reserved rewards.

- New
```45:47:src/StakingContract.sol
uint256 public constant EMERGENCY_WITHDRAW_DELAY = 1 days;
uint256 public emergencyWithdrawAvailableAt;
```

- New
```401:426:src/StakingContract.sol
function initiateEmergencyWithdraw() external onlyOwner {
    emergencyWithdrawAvailableAt = block.timestamp + EMERGENCY_WITHDRAW_DELAY;
    emit EmergencyWithdrawScheduled(emergencyWithdrawAvailableAt);
}
function emergencyWithdraw() external onlyOwner nonReentrant {
    uint256 availableAt = emergencyWithdrawAvailableAt;
    if (availableAt == 0 || block.timestamp < availableAt) revert StakingPeriodNotMet();
    emergencyWithdrawAvailableAt = 0;
    uint256 balance = STAKING_TOKEN.balanceOf(address(this));
    uint256 accounted = totalStaked + rewardReserve;
    if (balance <= accounted) revert NoExcessTokens();
    uint256 amount = balance - accounted;
    STAKING_TOKEN.safeTransfer(owner(), amount);
    emit EmergencyWithdraw(owner(), amount);
}
```

- Previous
```197:202:src/initial/StakingContractInitial.sol
function emergencyWithdraw() external onlyOwner {
    // Transfer all contract balance to owner
    STAKING_TOKEN.safeTransfer(owner, STAKING_TOKEN.balanceOf(address(this)));
}
```
- **No draining of user funds**: Emergency and excess withdrawals only transfer tokens above the accounted amount (`totalStaked + rewardReserve`), preventing principal/reward theft.

```373:387:src/StakingContract.sol
function withdrawExcessTokens(uint256 amount, address to) external onlyOwner nonReentrant {
    uint256 balance = STAKING_TOKEN.balanceOf(address(this));
    uint256 accounted = totalStaked + rewardReserve;
    if (balance <= accounted) revert NoExcessTokens();
    uint256 excess = balance - accounted;
    if (amount > excess) amount = excess;
    STAKING_TOKEN.safeTransfer(to, amount);
    emit ExcessTokensWithdrawn(to, amount);
}
```


### Token Accounting and Funds Separation
- **Dedicated reward reserve**: Introduced `rewardReserve` to segregate reward liquidity from user principal.
  - `fundRewardReserve` (owner) to add liquidity for rewards.
  - `withdrawFromRewardReserve` (owner) to remove reward liquidity (bounded by available reserve).
  - `claimRewards` checks and decrements `rewardReserve` to ensure claims never deplete principal.

```41:41:src/StakingContract.sol
uint256 public rewardReserve; /// Tokens set aside to pay rewards, separate from principal.
```

```337:345:src/StakingContract.sol
function fundRewardReserve(uint256 amount) external onlyOwner nonReentrant {
    if (amount == 0) revert AmountMustBePositive();
    rewardReserve += amount;
    STAKING_TOKEN.safeTransferFrom(msg.sender, address(this), amount);
    emit RewardReserveFunded(amount);
}
```

```352:365:src/StakingContract.sol
function withdrawFromRewardReserve(uint256 amount, address to) external onlyOwner nonReentrant {
    uint256 availableReserve = rewardReserve;
    if (amount > availableReserve) revert InsufficientRewardReserve(amount, availableReserve);
    unchecked { rewardReserve = availableReserve - amount; }
    STAKING_TOKEN.safeTransfer(to, amount);
    emit RewardReserveWithdrawn(to, amount);
}
```

```196:205:src/StakingContract.sol
uint256 availableReserve = rewardReserve;
if (availableReserve < totalRewards) revert InsufficientRewardReserve(totalRewards, availableReserve);
unchecked { rewardReserve = availableReserve - totalRewards; }
STAKING_TOKEN.safeTransfer(msg.sender, totalRewards);
```
- **Excess token withdrawal**: `withdrawExcessTokens` (owner) lets the owner retrieve tokens only if the contract holds more than `totalStaked + rewardReserve`.
- **Visibility**: `contractBalance()` exposes the accounted balance requirement (principal + reserve).

```393:395:src/StakingContract.sol
function contractBalance() external view returns (uint256) {
    return totalStaked + rewardReserve;
}
```


### Validation and Developer Experience
- **Constructor validation**: Enforces nonzero `_rewardRate`, `_minimumStakeAmount`, `_stakingPeriod`, and nonzero `_token` address.

```80:89:src/StakingContract.sol
constructor(uint256 _rewardRate, uint256 _minimumStakeAmount, uint256 _stakingPeriod, address _token) Ownable(msg.sender){
    if(_minimumStakeAmount == 0) revert AmountMustBePositive();
    if(_stakingPeriod == 0) revert InvalidPeriod();
    if(_rewardRate == 0) revert InvalidRewardRate();
    if(_token == address(0)) revert ZeroAddress();
    rewardRate = _rewardRate;
    minimumStakeAmount = _minimumStakeAmount;
    stakingPeriod = _stakingPeriod;
    STAKING_TOKEN = IERC20(_token);
}
```

```42:49:src/initial/StakingContractInitial.sol
constructor(uint256 _rewardRate, uint256 _minimumStakeAmount, uint256 _stakingPeriod, address _token) {
    owner = msg.sender;
    rewardRate = _rewardRate;
    minimumStakeAmount = _minimumStakeAmount;
    stakingPeriod = _stakingPeriod;
    STAKING_TOKEN = IERC20(_token);
}
```
- **Admin update validation**: `updateRewardRate` and `updateMinimumStakeAmount` validate inputs. Events are emitted for observability.

```300:319:src/StakingContract.sol
function updateRewardRate(uint256 newRate) external onlyOwner {
    if(newRate == 0) revert InvalidRewardRate();
    rewardRate = newRate;
    rateChanges.push(RateChange({ newRate: newRate, changeTime: block.timestamp }));
    emit RewardRateUpdated(newRate);
}
function updateMinimumStakeAmount(uint256 newMinimum) external onlyOwner {
    if(newMinimum == 0) revert AmountMustBePositive();
    minimumStakeAmount = newMinimum;
    emit MinimumStakeAmountUpdated(newMinimum);
}
```

```167:183:src/initial/StakingContractInitial.sol
function updateRewardRate(uint256 newRate) external onlyOwner {
    rewardRate = newRate;
    emit RewardRateUpdated(newRate);
}
function updateMinimumStakeAmount(uint256 newMinimum) external onlyOwner {
    minimumStakeAmount = newMinimum;
}
```
- **Clear revert reasons via custom errors**: Replaced string-based requires with custom errors (e.g., `AmountTooLow`, `InsufficientStakedBalance`, `InsufficientRewardReserve`, `NoExcessTokens`) which are cheaper and more precise.

```61:72:src/StakingContract.sol
error AmountTooLow();
error AmountMustBePositive();
error InvalidPeriod();
error InvalidRewardRate();
error ZeroAddress();
error NoRewardsToClaim();
error InsufficientStakedBalance(uint256 requested, uint256 available);
error StakingPeriodNotMet();
error InsufficientRewardReserve(uint256 requested, uint256 available);
error NoExcessTokens();
```

```56:59:src/initial/StakingContractInitial.sol
require(amount >= minimumStakeAmount, "Amount too low");
require(amount > 0, "Amount must be positive");
```
- **Minimum stake logic**: Minimum is enforced only on the first stake; top-ups are allowed without re-checking the minimum.

```115:118:src/StakingContract.sol
Stake memory userStake = stakes[msg.sender];
if (userStake.balance == 0 && amount < minimumStakeAmount) revert AmountTooLow();
```

```58:59:src/initial/StakingContractInitial.sol
require(amount >= minimumStakeAmount, "Amount too low");
require(amount > 0, "Amount must be positive");
```


### Gas and Performance
- **Storage packing**: Consolidated user state into a struct, reducing SLOAD/SSTORE operations.
- **Custom errors**: Lower gas than string revert reasons.
- **Efficient rate lookup**: Binary search over `rateChanges` to find the starting segment, then a single forward pass.

```237:257:src/StakingContract.sol
uint256 left = 0;
uint256 right = length - 1;
while (left < right) {
    uint256 mid = left + (right - left + 1) / 2;
    if (rateChanges[mid].changeTime <= startTime) {
        left = mid;
    } else {
        right = mid - 1;
    }
}
currentRate = rateChanges[left].newRate;
startIdx = left + 1;
```
- **Targeted unchecked blocks**: Safe, localized `unchecked` math where bounds are proven (e.g., reserve decrements), reducing gas.

```199:201:src/StakingContract.sol
unchecked { 
    rewardReserve = availableReserve - totalRewards; 
}
```

```359:361:src/StakingContract.sol
unchecked { 
    rewardReserve = availableReserve - amount; 
}
```


### Events and Observability
- Added events to improve monitoring and off-chain indexing:
  - `RewardRateUpdated`, `MinimumStakeAmountUpdated`, `StakingPeriodUpdated`
  - `RewardReserveFunded`, `RewardReserveWithdrawn`
  - `ExcessTokensWithdrawn`
  - `EmergencyWithdrawScheduled`, `EmergencyWithdraw`

```52:59:src/StakingContract.sol
event RewardRateUpdated(uint256 newRate);
event EmergencyWithdrawScheduled(uint256 availableAt);
event MinimumStakeAmountUpdated(uint256 newMinimum);
event StakingPeriodUpdated(uint256 newPeriod);
event EmergencyWithdraw(address indexed user, uint256 amount);
event RewardReserveFunded(uint256 amount);
event RewardReserveWithdrawn(address indexed to, uint256 amount);
event ExcessTokensWithdrawn(address indexed to, uint256 amount);
```

```31:36:src/initial/StakingContractInitial.sol
event Staked(address indexed user, uint256 amount);
event Unstaked(address indexed user, uint256 amount);
event RewardsClaimed(address indexed user, uint256 amount);
event RewardRateUpdated(uint256 newRate);
```


### Behavioral Changes to Note
- **Rewards are decoupled from active staking**: You can claim accrued rewards after fully unstaking.
- **Admin must fund the reward reserve**: `claimRewards` will revert with `InsufficientRewardReserve` if not enough reserve is available.
- **Emergency withdrawals are timelocked and limited**: Only excess tokens are withdrawable after the delay; user principal and reward reserve remain safe.


### Reward Accrual Formula (conceptual)
Over the interval \([t_0, t_n]\) partitioned by rate-change times, rewards are:
\( \sum_i \text{stakedAmount} \times \text{rate}_i \times (t_{i+1}-t_i) / \text{REWARD\_SCALE} \).


### Summary
`src/StakingContract.sol` strengthens security (reentrancy guard, timelock, access control), fixes reward-accounting correctness across rate changes, separates reward liquidity from principal, improves gas efficiency, and enhances observability and admin ergonomics compared to `src/initial/StakingContractInitial.sol`.

