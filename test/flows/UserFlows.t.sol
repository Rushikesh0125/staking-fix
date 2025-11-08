// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {StakingContract} from "../../src/StakingContract.sol";
import {MockERC20} from "../../src/MockERC20.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

contract UserFlowsTest is Test {
    // Actors
    address internal owner;
    address internal user1;
    address internal user2;

    // Contracts
    MockERC20 internal token;
    StakingContract internal staking;

    // Config
    uint256 internal constant INITIAL_SUPPLY = 1_000_000 ether;
    uint256 internal constant REWARD_RATE = 1e9;
    uint256 internal constant MIN_STAKE = 100 ether;
    uint256 internal constant REWARD_FUND = 200_000 ether;
    uint256 internal constant STAKE_PERIOD = 7 days;

    function setUp() public {
        owner = address(this);
        user1 = address(0xA11CE);
        user2 = address(0xB0B);

        token = new MockERC20(); // mints INITIAL_SUPPLY to owner (address(this))

        // Distribute tokens to users
        {
            bool ok = token.transfer(user1, 500_000 ether);
            assertTrue(ok);
        }
        {
            bool ok = token.transfer(user2, 300_000 ether);
            assertTrue(ok);
        }

        {
            address implementation = address(new StakingContract());
            address proxy = UnsafeUpgrades.deployUUPSProxy(
                implementation,
                abi.encodeCall(
                    StakingContract.initialize, (REWARD_RATE, MIN_STAKE, STAKE_PERIOD, address(token), owner)
                )
            );
            staking = StakingContract(proxy);
        }

        // Pre-fund reward reserve to ensure claims succeed
        token.approve(address(staking), REWARD_FUND);
        staking.fundRewardReserve(REWARD_FUND);
    }

    // Helpers to read fields from the public stakes tuple
    function stakeBalance(address user) internal view returns (uint256) {
        (uint256 b,,) = staking.stakes(user);
        return b;
    }

    function rewardBalanceOf(address user) internal view returns (uint256) {
        (, uint256 r,) = staking.stakes(user);
        return r;
    }

    function lastStakeTimeOf(address user) internal view returns (uint256) {
        (,, uint256 t) = staking.stakes(user);
        return t;
    }

    // ------------------------------------------------------
    // Flows
    // ------------------------------------------------------

    // Stake → wait → unstake → claim
    function testFlow_Stake_Wait_Unstake_Claim() public {
        vm.startPrank(user1);
        token.approve(address(staking), MIN_STAKE);
        staking.stake(MIN_STAKE);
        vm.stopPrank();

        // Wait full staking period so unstake is allowed
        vm.warp(block.timestamp + STAKE_PERIOD);

        uint256 pendingBefore = staking.calculateRewards(user1);

        vm.startPrank(user1);
        staking.unstake(MIN_STAKE); // banks pending into rewardBalance
        assertEq(stakeBalance(user1), 0);
        assertEq(rewardBalanceOf(user1), pendingBefore);
        assertEq(lastStakeTimeOf(user1), 0);

        uint256 before = token.balanceOf(user1);
        staking.claimRewards();
        assertEq(token.balanceOf(user1) - before, pendingBefore);
        assertEq(rewardBalanceOf(user1), 0);
        vm.stopPrank();
    }

    // Stake → claim rewards → continue staking → unstake
    function testFlow_Stake_Claim_Continue_Unstake() public {
        vm.startPrank(user1);
        token.approve(address(staking), MIN_STAKE);
        staking.stake(MIN_STAKE);
        vm.stopPrank();

        // Accrue some rewards then claim while continuing to stake
        vm.warp(block.timestamp + 3 days);
        uint256 expectedClaim = (MIN_STAKE * staking.rewardRate() * 3 days) / 1e18;

        vm.startPrank(user1);
        uint256 balBefore = token.balanceOf(user1);
        staking.claimRewards(); // resets lastStakeTime but keeps principal staked
        assertEq(token.balanceOf(user1) - balBefore, expectedClaim);
        assertEq(rewardBalanceOf(user1), 0);
        assertEq(stakeBalance(user1), MIN_STAKE);
        vm.stopPrank();

        // Must wait an entire staking period from last claim to be able to unstake
        vm.warp(block.timestamp + STAKE_PERIOD);

        vm.startPrank(user1);
        staking.unstake(MIN_STAKE);
        assertEq(stakeBalance(user1), 0);
        assertEq(lastStakeTimeOf(user1), 0);
        vm.stopPrank();
    }

    // Multiple stakes → partial unstake → claim
    function testFlow_MultipleStakes_PartialUnstake_ThenClaim() public {
        vm.startPrank(user1);
        token.approve(address(staking), 3 * MIN_STAKE);
        // First stake
        staking.stake(MIN_STAKE);
        vm.stopPrank();

        // Accrue for t1
        uint256 t1 = 2 days;
        vm.warp(block.timestamp + t1);
        uint256 r = staking.rewardRate();
        uint256 expected1 = (MIN_STAKE * r * t1) / 1e18;

        // Second stake; banks first segment
        vm.startPrank(user1);
        staking.stake(2 * MIN_STAKE);
        assertEq(rewardBalanceOf(user1), expected1);
        vm.stopPrank();

        // Accrue for t2 with larger balance
        uint256 t2 = STAKE_PERIOD; // also ensures unstake allowed
        vm.warp(block.timestamp + t2);
        uint256 expected2 = (3 * MIN_STAKE * r * t2) / 1e18;

        // Partial unstake half of total (1.5 * MIN_STAKE)
        vm.startPrank(user1);
        staking.unstake((3 * MIN_STAKE) / 2);
        // After unstake, all pending (t2) added to rewardBalance, accrual resets
        assertEq(rewardBalanceOf(user1), expected1 + expected2);
        // Claim immediately to realize exactly the banked amount
        uint256 before = token.balanceOf(user1);
        staking.claimRewards();
        assertEq(token.balanceOf(user1) - before, expected1 + expected2);
        assertEq(rewardBalanceOf(user1), 0);
        vm.stopPrank();
    }

    // Multiple users interacting "simultaneously" (interleaved operations)
    function testFlow_MultiUser_Interleaved() public {
        // user1 stakes
        vm.startPrank(user1);
        token.approve(address(staking), 2 * MIN_STAKE);
        staking.stake(MIN_STAKE);
        vm.stopPrank();

        // move time, user2 joins
        vm.warp(block.timestamp + 2 days);
        vm.startPrank(user2);
        token.approve(address(staking), 2 * MIN_STAKE);
        staking.stake(2 * MIN_STAKE);
        vm.stopPrank();

        // more time passes
        vm.warp(block.timestamp + STAKE_PERIOD);

        // user2 claims while user1 unstakes
        vm.startPrank(user2);
        uint256 u2Before = token.balanceOf(user2);
        staking.claimRewards();
        assertGt(token.balanceOf(user2) - u2Before, 0);
        vm.stopPrank();

        vm.startPrank(user1);
        staking.unstake(MIN_STAKE);
        assertEq(stakeBalance(user1), 0);
        vm.stopPrank();

        // Totals remain consistent
        assertEq(staking.totalStaked(), stakeBalance(user2));
    }
}

