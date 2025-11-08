// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title StakingContractInitial
 * @notice This is initial staking contract provided in assignment.
 * @notice This does not includes improvements only placeholders are implemented.
 */
contract StakingContractInitial {
    using SafeERC20 for IERC20;

    IERC20 public immutable STAKING_TOKEN;

    // State variables
    /// audit - inefficient use of storage all of these mappings can be packed into one mapping of address => struct
    mapping(address => uint256) public stakedBalances;
    mapping(address => uint256) public rewardBalances;
    mapping(address => uint256) public lastStakeTime;
    mapping(address => bool) public isStaking;

    uint256 public totalStaked;
    uint256 public rewardRate; // rewards per second per token
    uint256 public minimumStakeAmount;
    uint256 public stakingPeriod; // minimum staking period in seconds
    address public owner;

    // Events
    event Staked(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount);
    event RewardsClaimed(address indexed user, uint256 amount);
    event RewardRateUpdated(uint256 newRate);

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    constructor(uint256 _rewardRate, uint256 _minimumStakeAmount, uint256 _stakingPeriod, address _token) {
        // audit - no data validation checks for the parameters
        owner = msg.sender;
        rewardRate = _rewardRate;
        minimumStakeAmount = _minimumStakeAmount;
        stakingPeriod = _stakingPeriod;
        STAKING_TOKEN = IERC20(_token);
    }

    /**
     * @dev Stake tokens in the contract
     * @param amount Amount of tokens to stake
     */
    function stake(uint256 amount) external {
        // audit - redundant checks, amount being greater than or equal to minimum stake amount is enough
        // audit - require statements with string reasons are expensive, consider using custom errors instead
        require(amount >= minimumStakeAmount, "Amount too low");
        require(amount > 0, "Amount must be positive");

        // audit - adding transferFrom call here would introduce a reentrancy vulnerability
        // Transfer tokens from user (assuming ERC20 token)
        // NOTE: This is a placeholder - in real implementation, you'd use IERC20.transferFrom
        // For this assignment, assume tokens are already in the contract
        STAKING_TOKEN.safeTransferFrom(msg.sender, address(this), amount);

        if (isStaking[msg.sender]) {
            // User is already staking, add to existing stake
            uint256 pendingRewards = calculateRewards(msg.sender);
            rewardBalances[msg.sender] += pendingRewards;

            // audit - No lastStaketime reset in case of restaking, update should happen in both cases
        } else {
            // New staker
            isStaking[msg.sender] = true;
            lastStakeTime[msg.sender] = block.timestamp;
        }

        stakedBalances[msg.sender] += amount;
        totalStaked += amount;

        emit Staked(msg.sender, amount);
    }

    /**
     * @dev Unstake tokens from the contract
     * @param amount Amount of tokens to unstake
     */
    function unstake(uint256 amount) external {
        // audit - redundant checks, staking amount >= amount already covers the check for is user staking
        require(isStaking[msg.sender], "Not staking");
        require(stakedBalances[msg.sender] >= amount, "Insufficient staked balance");
        require(block.timestamp >= lastStakeTime[msg.sender] + stakingPeriod, "Staking period not met");

        // Calculate and add pending rewards
        uint256 pendingRewards = calculateRewards(msg.sender);
        rewardBalances[msg.sender] += pendingRewards;

        // Update balances
        stakedBalances[msg.sender] -= amount;
        totalStaked -= amount;

        // Reset if fully unstaked
        if (stakedBalances[msg.sender] == 0) {
            isStaking[msg.sender] = false;
            lastStakeTime[msg.sender] = 0;
        } else {
            lastStakeTime[msg.sender] = block.timestamp;
        }

        // Transfer tokens back to user
        // NOTE: This is a placeholder - in real implementation, you'd use IERC20.transfer
        STAKING_TOKEN.safeTransfer(msg.sender, amount);
        emit Unstaked(msg.sender, amount);
    }

    /**
     * @dev Claim accumulated rewards
     */
    function claimRewards() external {
        // audit - This check blocks user from claiming unclaimed reward balances
        // it could be - require(isStaking[msg.sender] || rewardBalances[msg.sender] > 0, "Not staking");
        require(isStaking[msg.sender], "Not staking");

        uint256 pendingRewards = calculateRewards(msg.sender);
        uint256 totalRewards = rewardBalances[msg.sender] + pendingRewards;

        require(totalRewards > 0, "No rewards to claim");

        // Reset reward balance and update stake time
        rewardBalances[msg.sender] = 0;
        lastStakeTime[msg.sender] = block.timestamp;

        // Transfer rewards to user
        // NOTE: This is a placeholder - in real implementation, you'd use IERC20.transfer
        STAKING_TOKEN.safeTransfer(msg.sender, totalRewards);
        emit RewardsClaimed(msg.sender, totalRewards);
    }

    /**
     * @dev Calculate pending rewards for a user
     * @param user Address of the user
     * @return Amount of pending rewards
     */
    function calculateRewards(address user) public view returns (uint256) {
        if (!isStaking[user] || stakedBalances[user] == 0) {
            return 0;
        }

        uint256 timeStaked = block.timestamp - lastStakeTime[user];
        return (stakedBalances[user] * rewardRate * timeStaked) / 1e18;
    }

    /**
     * @dev Get total rewards for a user (pending + claimed)
     * @param user Address of the user
     * @return Total rewards
     */
    function getTotalRewards(address user) external view returns (uint256) {
        return rewardBalances[user] + calculateRewards(user);
    }

    /**
     * @dev Update reward rate (owner only)
     * @param newRate New reward rate
     */
    function updateRewardRate(uint256 newRate) external onlyOwner {
        // audit - no data validation checks for the new rate
        rewardRate = newRate;
        // audit - This would make users claim rewards at the new rate, which is not the intended behavior
        // consider adding a snapshot history of reward rates and their changes to calculate rewards accurately
        emit RewardRateUpdated(newRate);
    }

    /**
     * @dev Update minimum stake amount (owner only)
     * @param newMinimum New minimum stake amount
     */
    function updateMinimumStakeAmount(uint256 newMinimum) external onlyOwner {
        // audit - no data validation checks for the new minimum stake amount
        minimumStakeAmount = newMinimum;
    }

    /**
     * @dev Update staking period (owner only)
     * @param newPeriod New staking period in seconds
     */
    function updateStakingPeriod(uint256 newPeriod) external onlyOwner {
        // audit - no data validation checks for the new staking period
        stakingPeriod = newPeriod;
    }

    /**
     * @dev Emergency withdraw function (owner only)
     * NOTE: This function has potential security issues - identify and fix them
     */
    function emergencyWithdraw() external onlyOwner {
        // Transfer all contract balance to owner
        // audit - This function is not secure, owner can drain the contract of tokens
        // consider adding a timelock or a mechanism to prevent this
        STAKING_TOKEN.safeTransfer(owner, STAKING_TOKEN.balanceOf(address(this)));
    }
}
