// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract StakingContract is Ownable, ReentrancyGuard {

    /// Using SafeERC20 for IERC20 operations.
    using SafeERC20 for IERC20;

    /// Stake struct to store user stake information.
    struct Stake {
        uint256 balance;
        uint256 rewardBalance;
        uint256 lastStakeTime;
    }

    /// RateChange struct to store reward rate changes.
    struct RateChange {
        uint256 newRate;
        uint256 changeTime;
    }

    // State variables
    IERC20 public immutable STAKING_TOKEN;

    /// Mapping to store user stakes.
    mapping(address => Stake) public stakes;

    /// Array to store reward rate changes.
    RateChange[] public rateChanges;
    
    uint256 public totalStaked; /// Total staked tokens in the contract.
    uint256 public rewardRate; /// Rewards per second per token.
    uint256 public minimumStakeAmount; /// Minimum stake amount.
    uint256 public stakingPeriod; /// Minimum staking period in seconds.
	uint256 public rewardReserve; /// Tokens set aside to pay rewards, separate from principal.
	uint256 public immutable REWARD_SCALE; /// Scaling factor for reward rate, typically 10**tokenDecimals.
    
    /// Emergency withdraw timelock
    uint256 public constant EMERGENCY_WITHDRAW_DELAY = 1 days; /// Emergency withdraw timelock in seconds.
    uint256 public emergencyWithdrawAvailableAt; /// 0 means not scheduled.
    
    // Events
    event Staked(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount);
    event RewardsClaimed(address indexed user, uint256 amount);
    event RewardRateUpdated(uint256 newRate);
    event EmergencyWithdrawScheduled(uint256 availableAt);
    event MinimumStakeAmountUpdated(uint256 newMinimum);
    event StakingPeriodUpdated(uint256 newPeriod);
    event EmergencyWithdraw(address indexed user, uint256 amount);
    event RewardReserveFunded(uint256 amount);
    event RewardReserveWithdrawn(address indexed to, uint256 amount);
    event ExcessTokensWithdrawn(address indexed to, uint256 amount);

    // Custom errors
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

    /**
     * @dev Constructor to initialize the contract.
     * @param _rewardRate Rewards per second per token.
     * @param _minimumStakeAmount Minimum stake amount.
     * @param _stakingPeriod Minimum staking period in seconds.
     * @param _token Address of the staking token.
     */
    constructor(uint256 _rewardRate, uint256 _minimumStakeAmount, uint256 _stakingPeriod, address _token) Ownable(msg.sender){
        if(_minimumStakeAmount == 0) revert AmountMustBePositive();
        if(_stakingPeriod == 0) revert InvalidPeriod();
        if(_rewardRate == 0) revert InvalidRewardRate();
        if(_token == address(0)) revert ZeroAddress();
        
        rewardRate = _rewardRate;
        minimumStakeAmount = _minimumStakeAmount;
        stakingPeriod = _stakingPeriod;
        STAKING_TOKEN = IERC20(_token);
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
        rateChanges.push(RateChange({
            newRate: rewardRate,
            changeTime: block.timestamp
        }));
    }
    
    /**
     * @notice function to Stake tokens in the contract
     * @param amount Amount of tokens to stake
     */
    function stake(uint256 amount) external nonReentrant {
        // no zero check required as minimumStakeAmount is always > 0
        // check if amount is greater than minimum stake amount
        // For existing staking user, avoid minimum stake check as its additional on top of existing balance check
        // it would make sense in case of new staker, and if there are calculation limitation
        Stake memory userStake = stakes[msg.sender];
        if (userStake.balance == 0 && amount < minimumStakeAmount) revert AmountTooLow();

        if (userStake.balance > 0) {
            // User is already staking, add to existing stake
            uint256 pendingRewards = calculateRewards(msg.sender);
            userStake.rewardBalance += pendingRewards;
        }

        /// Update user stake and total staked records
        userStake.lastStakeTime = block.timestamp;
        userStake.balance += amount;
        totalStaked += amount;

        /// Update user stake balances
        stakes[msg.sender] = userStake;

        /// Transfer tokens to contract
        STAKING_TOKEN.safeTransferFrom(msg.sender, address(this), amount);            
        emit Staked(msg.sender, amount);
    }
    
    /**
     * @notice function to Unstake tokens from the contract
     * @param amount Amount of tokens to unstake
     */
    function unstake(uint256 amount) external nonReentrant {
        Stake memory userStake = stakes[msg.sender];
        /// Check if user has sufficient staked balance
        if (userStake.balance < amount) revert InsufficientStakedBalance(amount, userStake.balance);
        /// Check if user has met the staking period
        if (block.timestamp < userStake.lastStakeTime + stakingPeriod) revert StakingPeriodNotMet();
        
        /// Calculate and add pending rewards
        uint256 pendingRewards = calculateRewards(msg.sender);
        userStake.rewardBalance += pendingRewards;
        
        /// Update user stake balances
        userStake.balance -= amount;
        totalStaked -= amount;
        
        /// Reset time if fully unstaked but preserve rewardBalance for later claim
        if (userStake.balance == 0) {
            userStake.lastStakeTime = 0;
        } else {
            userStake.lastStakeTime = block.timestamp;
        }
        
        /// Update user stake balances
        stakes[msg.sender] = userStake;

        /// Transfer tokens to user
        STAKING_TOKEN.safeTransfer(msg.sender, amount);            
        
        /// Emit unstaked event
        emit Unstaked(msg.sender, amount);
    }
    
    /**
     * @notice function to Claim accumulated rewards
     */
    function claimRewards() external nonReentrant {
        Stake memory userStake = stakes[msg.sender];
        /// Check if user has no rewards to claim
        if (userStake.balance == 0 && userStake.rewardBalance == 0) revert NoRewardsToClaim();
        
        /// Calculate and add pending rewards
        uint256 pendingRewards = calculateRewards(msg.sender);
        /// Calculate total rewards
        uint256 totalRewards = userStake.rewardBalance + pendingRewards;
        
        /// Check if user has no rewards to claim
        if (totalRewards == 0) revert NoRewardsToClaim();
        
        /// Reset reward balance and update stake time
        userStake.rewardBalance = 0;
        userStake.lastStakeTime = block.timestamp;

        /// Update user stake record
        stakes[msg.sender] = userStake;

        /// Ensure sufficient reward reserve and account before transferring
        uint256 availableReserve = rewardReserve;
        if (availableReserve < totalRewards) revert InsufficientRewardReserve(totalRewards, availableReserve);
        unchecked { 
            rewardReserve = availableReserve - totalRewards; 
        }

        /// Transfer tokens to user
        STAKING_TOKEN.safeTransfer(msg.sender, totalRewards);            

        /// Emit rewards claimed event
        emit RewardsClaimed(msg.sender, totalRewards);
    }
    
    /**
     * @notice function to Calculate pending rewards for a user
     * @param user Address of the user
     * @return Amount of pending rewards
     */
    function calculateRewards(address user) public view returns (uint256) {
        /// Check if user has no staked balance
        uint256 stakedAmount = stakes[user].balance;
        if (stakedAmount == 0) {
            return 0;
        }

        /// Get user stake start time and end time
        uint256 startTime = stakes[user].lastStakeTime;
        uint256 endTime = block.timestamp;
        /// Get number of reward rate changes
        uint256 length = rateChanges.length;

        // Binary search to find the effective rate at the start when the user started staking
        uint256 currentRate;
        uint256 startIdx;
        
        // if no rate change is done, use the first rate as the current rate
        if (length == 1) {
            currentRate = rateChanges[0].newRate;
            startIdx = 1;
        } else {
            // Binary search for the correct starting rate
            /// Initialize left and right pointers
            uint256 left = 0;
            uint256 right = length - 1;
            
            while (left < right) {
                /// Calculate middle index
                uint256 mid = left + (right - left + 1) / 2;
                /// Check if change time at mid index is before or after start time
                if (rateChanges[mid].changeTime <= startTime) {
                    /// Update left pointer, if change time passed before stake start time
                    left = mid;
                } else {
                    /// Update right pointer, if change time passed after stake start time
                    right = mid - 1;
                }
            }
            
            currentRate = rateChanges[left].newRate;
            startIdx = left + 1;
        }

        uint256 accrued;
        uint256 cursor = startTime;
        
        // Process only relevant rate changes (those after startTime and before endTime)
        for (uint256 i = startIdx; i < length; ++i) {
            uint256 changeTime = rateChanges[i].changeTime;
            
            /// Accrue from cursor to this change time
            uint256 segmentDuration;
            unchecked { segmentDuration = changeTime - cursor; }
            accrued += (stakedAmount * currentRate * segmentDuration) / REWARD_SCALE;
            
            cursor = changeTime;
            currentRate = rateChanges[i].newRate;
        }

        // Accrue final segment from cursor to endTime
        {
            uint256 segmentDuration;
            unchecked { segmentDuration = endTime - cursor; }
            accrued += (stakedAmount * currentRate * segmentDuration) / REWARD_SCALE;
        }

        return accrued;
    }

    
    /**
     * @notice function to Get total rewards for a user (pending + claimed)
     * @param user Address of the user
     * @return Total rewards
     */
    function getTotalRewards(address user) external view returns (uint256) {
        return stakes[user].rewardBalance + calculateRewards(user);
    }
    
    /**
     * @notice function to Update reward rate
     * @dev Only owner can update reward rate
     * @param newRate New reward rate
     */
    function updateRewardRate(uint256 newRate) external onlyOwner {
        if(newRate == 0) revert InvalidRewardRate();
        rewardRate = newRate;
        rateChanges.push(RateChange({
            newRate: newRate,
            changeTime: block.timestamp
        }));
        emit RewardRateUpdated(newRate);
    }
    
    /**
     * @notice function to Update minimum stake amount
     * @dev Only owner can update minimum stake amount
     * @param newMinimum New minimum stake amount
     */
    function updateMinimumStakeAmount(uint256 newMinimum) external onlyOwner {
        if(newMinimum == 0) revert AmountMustBePositive();
        minimumStakeAmount = newMinimum;
        emit MinimumStakeAmountUpdated(newMinimum);
    }
    
    /**
     * @notice function to Update staking period
     * @dev Only owner can update staking period
     * @param newPeriod New staking period in seconds
     */
    function updateStakingPeriod(uint256 newPeriod) external onlyOwner {
        stakingPeriod = newPeriod;
        emit StakingPeriodUpdated(newPeriod);
    }
    
    /**
     * @notice function to Fund the reward reserve by transferring tokens into the contract.
     * @dev Only owner can fund the reward reserve
     * The owner must have approved this contract to spend the tokens.
     * @param amount Amount of tokens to fund the reward reserve
     */
    function fundRewardReserve(uint256 amount) external onlyOwner nonReentrant {
        if (amount == 0) revert AmountMustBePositive();

        rewardReserve += amount;
        STAKING_TOKEN.safeTransferFrom(msg.sender, address(this), amount);

        emit RewardReserveFunded(amount);
    }

    /**
     * @notice function to Withdraw tokens from the reward reserve (reduces capacity to pay future rewards).
     * @dev Only owner can withdraw tokens from the reward reserve
     * @param amount Amount of tokens to withdraw from the reward reserve
     * @param to Address to withdraw tokens to
     */
    function withdrawFromRewardReserve(uint256 amount, address to) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert AmountMustBePositive();

        uint256 availableReserve = rewardReserve;
        if (amount > availableReserve) revert InsufficientRewardReserve(amount, availableReserve);

        unchecked { 
            rewardReserve = availableReserve - amount; 
        }

        STAKING_TOKEN.safeTransfer(to, amount);
        emit RewardReserveWithdrawn(to, amount);
    }

    /**
     * @notice function to Withdraw tokens that are not accounted as user principal or reward reserve.
     * @dev Only owner can withdraw tokens that are not accounted as user principal or reward reserve.
     * @param amount Amount of tokens to withdraw
     * @param to Address to withdraw tokens to
     */
    function withdrawExcessTokens(uint256 amount, address to) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert AmountMustBePositive();

        uint256 balance = STAKING_TOKEN.balanceOf(address(this));
        uint256 accounted = totalStaked + rewardReserve;

        if (balance <= accounted) revert NoExcessTokens();
        uint256 excess = balance - accounted;

        if (amount > excess) amount = excess;

        STAKING_TOKEN.safeTransfer(to, amount);
        emit ExcessTokensWithdrawn(to, amount);
    }

    /**
     * @notice function to Get the current accounted balance requirement (principal + reserve).
     * @return Current accounted balance requirement (principal + reserve)
     */
    function contractBalance() external view returns (uint256) {
        return totalStaked + rewardReserve;
    }
		
    /**
     * @notice function to Schedule emergency withdraw; callable by owner. Sets a delay before funds can be withdrawn.
     * @dev Only owner can schedule emergency withdraw
     */
    function initiateEmergencyWithdraw() external onlyOwner {
        emergencyWithdrawAvailableAt = block.timestamp + EMERGENCY_WITHDRAW_DELAY;
        emit EmergencyWithdrawScheduled(emergencyWithdrawAvailableAt);
    }
    
    /**
     * @notice function to Emergency withdraw
     * @dev Only owner can emergency withdraw
     */
    function emergencyWithdraw() external onlyOwner nonReentrant {
        // Enforce timelock: must be scheduled and delay elapsed
        uint256 availableAt = emergencyWithdrawAvailableAt;
        if (availableAt == 0 || block.timestamp < availableAt) revert StakingPeriodNotMet();

        // Reset schedule to avoid repeated usage without a fresh schedule
        emergencyWithdrawAvailableAt = 0;

        // Withdraw only excess tokens; do not touch user principal or reward reserve
        uint256 balance = STAKING_TOKEN.balanceOf(address(this));
        uint256 accounted = totalStaked + rewardReserve;
        if (balance <= accounted) revert NoExcessTokens();

        uint256 amount = balance - accounted;
        STAKING_TOKEN.safeTransfer(owner(), amount);
        emit EmergencyWithdraw(owner(), amount);
    }
}