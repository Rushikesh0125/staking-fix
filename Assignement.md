# Blockchain Developer Assignment

## Overview

This assignment tests your Solidity development skills, focusing on security, comprehensive testing, and state management. You will be working with a staking contract that contains several vulnerabilities and bugs that need to be identified and fixed.

## Objectives

- Identify and fix all security vulnerabilities in the provided contract
- Implement comprehensive test coverage including fuzz testing
- Ensure proper state management throughout the contract lifecycle
- Write production-ready, bug-free code
- Demonstrate understanding of security best practices in Solidity

## Prerequisites

- A Solidity development environment and testing framework of your choice
- Basic understanding of Solidity and smart contract security
- Familiarity with testing frameworks and fuzz testing

## Project Setup

**Important:** You must create your own project structure from scratch.

1. **Set up your development environment** using the framework of your choice (Foundry, Hardhat, Truffle, etc.)

2. **Copy the contract code** provided below into your project's contract directory

3. **Create a mock ERC20 token** for testing purposes (you'll need this to test the staking contract)

4. **Create your test files** - You are expected to write all tests from scratch

5. **Set up dependencies** - You may need OpenZeppelin contracts library for SafeERC20 and other security utilities

## The Contract

You are given a `StakingContract` that allows users to:
- Stake tokens and earn rewards over time based on a reward rate
- Unstake tokens after a minimum staking period has elapsed
- Claim accumulated rewards without unstaking
- Owner can update reward parameters (reward rate, minimum stake amount, staking period)

### Contract Behavior

**Staking:**
- Users can stake tokens (minimum amount required)
- If a user is already staking, additional stakes will add to their existing balance
- When adding to an existing stake, pending rewards are automatically added to `rewardBalances`
- New stakers start their staking timer from the current block timestamp

**Unstaking:**
- Users can unstake tokens only after the minimum staking period has passed
- Partial unstaking is allowed
- When unstaking, pending rewards are automatically added to `rewardBalances`
- If fully unstaked, the user's staking status is reset
- If partially unstaked, the staking timer resets to current timestamp

**Rewards:**
- Rewards accumulate continuously based on: `(stakedAmount * rewardRate * timeStaked) / 1e18`
- Rewards can be claimed at any time while staking
- Claiming rewards resets the pending rewards and updates the staking timer
- Rewards are stored in `rewardBalances` until claimed

**Owner Functions:**
- Owner can update reward rate (affects future rewards, not past)
- Owner can update minimum stake amount
- Owner can update staking period (affects future unstaking requirements)
- Owner has an emergency withdraw function (needs implementation)

**Contract Code:**

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title StakingContract
 * @dev A staking contract that allows users to stake tokens and earn rewards.
 * 
 * ASSIGNMENT: Review this contract and identify all security vulnerabilities,
 * bugs, and potential improvements. Fix all issues and ensure the contract
 * is production-ready.
 * 
 * Key areas to focus on:
 * - Reentrancy vulnerabilities
 * - Access control issues
 * - Integer overflow/underflow
 * - State management correctness
 * - Edge cases and boundary conditions
 * - Gas optimization opportunities
 */
contract StakingContract {
    // State variables
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
    
    constructor(uint256 _rewardRate, uint256 _minimumStakeAmount, uint256 _stakingPeriod) {
        owner = msg.sender;
        rewardRate = _rewardRate;
        minimumStakeAmount = _minimumStakeAmount;
        stakingPeriod = _stakingPeriod;
    }
    
    /**
     * @dev Stake tokens in the contract
     * @param amount Amount of tokens to stake
     */
    function stake(uint256 amount) external {
        require(amount >= minimumStakeAmount, "Amount too low");
        require(amount > 0, "Amount must be positive");
        
        // Transfer tokens from user (assuming ERC20 token)
        // NOTE: This is a placeholder - in real implementation, you'd use IERC20.transferFrom
        // For this assignment, assume tokens are already in the contract
        
        if (isStaking[msg.sender]) {
            // User is already staking, add to existing stake
            uint256 pendingRewards = calculateRewards(msg.sender);
            rewardBalances[msg.sender] += pendingRewards;
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
        
        emit Unstaked(msg.sender, amount);
    }
    
    /**
     * @dev Claim accumulated rewards
     */
    function claimRewards() external {
        require(isStaking[msg.sender], "Not staking");
        
        uint256 pendingRewards = calculateRewards(msg.sender);
        uint256 totalRewards = rewardBalances[msg.sender] + pendingRewards;
        
        require(totalRewards > 0, "No rewards to claim");
        
        // Reset reward balance and update stake time
        rewardBalances[msg.sender] = 0;
        lastStakeTime[msg.sender] = block.timestamp;
        
        // Transfer rewards to user
        // NOTE: This is a placeholder - in real implementation, you'd use IERC20.transfer
        
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
        rewardRate = newRate;
        emit RewardRateUpdated(newRate);
    }
    
    /**
     * @dev Update minimum stake amount (owner only)
     * @param newMinimum New minimum stake amount
     */
    function updateMinimumStakeAmount(uint256 newMinimum) external onlyOwner {
        minimumStakeAmount = newMinimum;
    }
    
    /**
     * @dev Update staking period (owner only)
     * @param newPeriod New staking period in seconds
     */
    function updateStakingPeriod(uint256 newPeriod) external onlyOwner {
        stakingPeriod = newPeriod;
    }
    
    /**
     * @dev Emergency withdraw function (owner only)
     * NOTE: This function has potential security issues - identify and fix them
     */
    function emergencyWithdraw() external onlyOwner {
        // Transfer all contract balance to owner
        // NOTE: This is a placeholder
    }
}
```

## Requirements

### 1. Security Audit & Fixes

Identify and fix **all** security vulnerabilities including but not limited to:

- **Reentrancy attacks** - Ensure all external calls follow checks-effects-interactions pattern. Consider using reentrancy guards where appropriate
- **Access control** - Verify all owner-only functions are properly protected. Consider if ownership transfer should be implemented
- **Integer overflow/underflow** - While Solidity 0.8+ has built-in checks, verify edge cases with very large numbers
- **State management** - Ensure state variables are updated correctly and consistently. Verify `totalStaked` always matches sum of individual stakes
- **Edge cases** - Handle zero values, maximum values, and boundary conditions. What happens with very large reward rates? Very long time periods?
- **Front-running** - Consider if any functions are vulnerable to MEV attacks or transaction ordering manipulation
- **Centralization risks** - Document any trust assumptions. What can the owner do? Is it acceptable?
- **Reward calculation accuracy** - Verify rewards are calculated correctly, especially when reward rate changes mid-stake
- **State consistency** - Ensure state remains consistent even if operations fail partway through
- **External call safety** - Handle ERC20 tokens that may not return values or may revert

### 2. ERC20 Integration

The contract currently has placeholder comments for ERC20 token transfers. You must:

- **Add ERC20 token interface** - Import or define the IERC20 interface
- **Add token address** - The contract needs to know which ERC20 token to use (add as constructor parameter or state variable)
- **Implement `stake()`** - Use `transferFrom` to transfer tokens from user to contract
- **Implement `unstake()`** - Use `transfer` to return staked tokens to user
- **Implement `claimRewards()`** - Use `transfer` to send reward tokens to user (assume rewards are paid in the same token, or implement a separate reward token)
- **Handle transfer failures** - Use try-catch or SafeERC20 to handle tokens that don't return boolean values
- **Consider SafeERC20** - OpenZeppelin's SafeERC20 library handles non-standard ERC20 tokens safely
- **Token approval** - Document that users must approve the contract before staking (this is standard ERC20 behavior)

### 3. Comprehensive Testing

Write a complete test suite that includes:

#### Unit Tests
- Test all public/external functions with valid inputs
- Test all edge cases and error conditions:
  - Staking with zero amount
  - Staking below minimum
  - Unstaking before period ends
  - Unstaking more than staked
  - Claiming with no rewards
  - Owner vs non-owner access
- Test access control (owner vs non-owner) for all owner functions
- Test state transitions (staking → unstaking → staking again)
- Test event emissions match state changes
- Test reward calculations with various scenarios
- Test parameter updates and their effects

#### Integration Tests
- Test complete user flows:
  - Stake → wait → unstake → claim
  - Stake → claim rewards → continue staking → unstake
  - Multiple stakes → partial unstake → claim
- Test multiple users interacting simultaneously
- Test owner functions and their effects on active stakers
- Test reward rate changes while users are staking
- Test minimum stake amount changes
- Test staking period changes
- Test concurrent operations (multiple users staking/unstaking at once)

#### Fuzz Tests (Required)
- Fuzz test `stake()` with various amounts
- Fuzz test `unstake()` with various amounts and timing
- Fuzz test `calculateRewards()` with various time periods
- Fuzz test reward calculations with different stake amounts and rates
- Use your chosen framework's fuzzing capabilities

**Minimum fuzz test requirements:**
- At least 3 different fuzz test functions
- Each fuzz test should run at least 1000 iterations
- Test boundary conditions and edge cases

#### Invariant Tests
- Test that `totalStaked` always equals sum of all `stakedBalances`
- Test that rewards calculations are always consistent
- Test that state remains consistent after all operations

### 4. Code Quality

- Follow Solidity style guide and format your code consistently
- Add comprehensive NatSpec documentation
- Use meaningful variable and function names
- Implement proper error handling with descriptive error messages
- Consider gas optimization where appropriate

### 5. Additional Considerations

- **Emergency functions**: Implement `emergencyWithdraw()` securely
- **Upgradeability**: Consider if the contract should be upgradeable (not required, but document your decision)
- **Pausability**: Consider if the contract should be pausable (not required, but document your decision)

## Deliverables

1. **Fixed Contract** (`StakingContract.sol`)
   - All vulnerabilities fixed
   - ERC20 integration implemented
   - Production-ready code

2. **Test Suite**
   - Unit tests
   - Integration tests
   - Fuzz tests (minimum 3 functions, 1000+ iterations each)
   - Invariant tests
   - All tests passing

3. **Documentation**
   - `SECURITY.md` or `AUDIT.md` - Document all vulnerabilities found and how they were fixed. For each vulnerability:
     - Description of the issue
     - Severity (Critical/High/Medium/Low)
     - Impact (what could go wrong)
     - Fix implemented
     - Code references
   - Inline code comments explaining security measures (why reentrancy guards, why checks-effects-interactions, etc.)
   - README with:
     - Project setup instructions
     - How to run tests
     - How to deploy (if applicable)
     - Architecture decisions (why certain design choices were made)

4. **Test Results**
   - Screenshot or output showing all tests passing
   - Fuzz test coverage report (if available)

## Testing

You should be able to run your test suite and demonstrate:
- All tests passing
- Fuzz tests running with appropriate iteration counts
- Test coverage metrics (if available in your chosen framework)
- Clear output showing test results

Include instructions in your README on how to run tests in your chosen framework.

## Evaluation Criteria

Your submission will be evaluated on:

1. **Security (40%)**
   - All vulnerabilities identified and fixed
   - Proper use of security patterns (checks-effects-interactions, etc.)
   - No remaining security issues

2. **Testing (30%)**
   - Test coverage (aim for 90%+)
   - Quality and comprehensiveness of tests
   - Fuzz testing implementation and coverage
   - Edge cases covered

3. **Code Quality (20%)**
   - Code organization and readability
   - Documentation quality
   - Best practices followed
   - Gas optimization considerations

4. **Functionality (10%)**
   - Contract works as intended
   - All functions behave correctly
   - State management is correct

## Submission

1. Create a git repository with your solution
2. Include all source code, tests, and documentation
3. Ensure all tests pass
4. Provide clear commit messages
5. Submit repository link or zip file

## Additional Notes

### ERC20 Token for Testing
You will need to create or use a mock ERC20 token for testing. The token should:
- Implement the standard ERC20 interface
- Allow minting for test purposes
- Handle approvals and transfers correctly

### Production Readiness Checklist
Before submitting, ensure:
- [ ] All security vulnerabilities identified and fixed
- [ ] ERC20 integration fully implemented and tested
- [ ] All tests passing (unit, integration, fuzz, invariant)
- [ ] Test coverage is comprehensive (aim for 90%+)
- [ ] Security audit document is complete
- [ ] README includes setup and run instructions
- [ ] Code follows Solidity best practices
- [ ] No compiler warnings
- [ ] Gas optimization considered (where appropriate)

### What Makes a Good Submission
1. **Security First**: All vulnerabilities fixed, no shortcuts
2. **Comprehensive Testing**: Tests cover happy paths, edge cases, and error conditions
3. **Clear Documentation**: Security issues well-documented, code is commented
4. **Clean Code**: Well-organized, readable, follows best practices
5. **Production Mindset**: Code is ready for deployment (with appropriate disclaimers)

## Questions?

If you have any questions about the assignment, please reach out. Good luck!

