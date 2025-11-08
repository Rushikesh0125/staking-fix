// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {StakingContract} from "../src/StakingContract.sol";
import {MockERC20} from "../src/MockERC20.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

// Minimal token with no decimals() implementation to trigger the constructor catch branch
contract NoDecimalsToken {
    // intentionally empty; no IERC20Metadata.decimals()
}

contract StakingContractTest is Test {
    // Actors
    address internal owner;
    address internal user1;
    address internal user2;

    // Contracts
    MockERC20 internal token;
    StakingContract internal staking;

    // Config
    uint256 internal constant INITIAL_SUPPLY = 1_000_000 ether; // from MockERC20 constructor (1e24)
    uint256 internal constant REWARD_RATE = 1e9; // scaled by 1e18; small so rewards fit pool
    uint256 internal constant MIN_STAKE = 100 ether;
    uint256 internal constant REWARD_FUND = 100_000 ether;
    uint256 internal constant STAKE_PERIOD = 7 days;

    function setUp() public {
        owner = address(this);
        user1 = address(1);
        user2 = address(2);

        token = new MockERC20(); // mints initial supply to address(this)

        // Distribute tokens to users
        {
            bool ok = token.transfer(user1, 500_000 ether);
            assertTrue(ok);
        }
        {
            bool ok = token.transfer(user2, 400_000 ether);
            assertTrue(ok);
        }

        staking = new StakingContract(REWARD_RATE, MIN_STAKE, STAKE_PERIOD, address(token));

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
        (,uint256 r,) = staking.stakes(user);
        return r;
    }

    function lastStakeTimeOf(address user) internal view returns (uint256) {
        (,,uint256 t) = staking.stakes(user);
        return t;
    }

    // ------------------------------------------------------
    // Constructor
    // ------------------------------------------------------
    function test_Constructor_SetsParamsAndOwner() public view {
        assertEq(staking.rewardRate(), REWARD_RATE);
        assertEq(staking.minimumStakeAmount(), MIN_STAKE);
        assertEq(staking.stakingPeriod(), STAKE_PERIOD);
        assertEq(address(staking.STAKING_TOKEN()), address(token));
        assertEq(staking.owner(), owner);
    }

    function test_Revert_Constructor_ZeroArgs() public {
        vm.expectRevert(StakingContract.InvalidRewardRate.selector);
        new StakingContract(0, MIN_STAKE, STAKE_PERIOD, address(token));

        vm.expectRevert(StakingContract.AmountMustBePositive.selector);
        new StakingContract(REWARD_RATE, 0, STAKE_PERIOD, address(token));

        vm.expectRevert(StakingContract.InvalidPeriod.selector);
        new StakingContract(REWARD_RATE, MIN_STAKE, 0, address(token));

        vm.expectRevert(StakingContract.ZeroAddress.selector);
        new StakingContract(REWARD_RATE, MIN_STAKE, STAKE_PERIOD, address(0));
    }

    function test_REWARD_SCALE_Fallback_WhenNoDecimals() public {
        address tokenAddr = address(new NoDecimalsToken());
        StakingContract s = new StakingContract(1, 1, 1, tokenAddr);
        assertEq(s.REWARD_SCALE(), 1e18);
    }

    // ------------------------------------------------------
    // Stake
    // ------------------------------------------------------
    function test_Revert_Stake_AmountTooLow() public {
        vm.startPrank(user1);

        token.approve(address(staking), MIN_STAKE - 1); // passing minimum stake amount - 1
        vm.expectRevert(StakingContract.AmountTooLow.selector);

        staking.stake(MIN_STAKE - 1);
        vm.stopPrank();
    }

    function test_Stake_SucceedsAndEmits() public {
        vm.startPrank(user1);
        token.approve(address(staking), MIN_STAKE);

        vm.expectEmit(true, true, false, true, address(staking));
        emit StakingContract.Staked(user1, MIN_STAKE);
        staking.stake(MIN_STAKE);
        
        // state change assertions to ensure stake is successful
        assertEq(stakeBalance(user1), MIN_STAKE);
        assertEq(staking.totalStaked(), MIN_STAKE);
        assertEq(token.balanceOf(address(staking)), REWARD_FUND + MIN_STAKE);
        assertGt(lastStakeTimeOf(user1), 0);
        vm.stopPrank();
    }

    function test_Stake_AddsPendingRewardsOnRestake() public {
        // First stake
        vm.startPrank(user1);
        token.approve(address(staking), 2 * MIN_STAKE);
        staking.stake(MIN_STAKE);

        // accrue rewards
        vm.warp(block.timestamp + 10);

        uint256 pending = (MIN_STAKE * REWARD_RATE * 10) / 1e18;

        // restake should bank pending rewards into rewardBalances
        staking.stake(MIN_STAKE);

        assertEq(stakeBalance(user1), 2 * MIN_STAKE);
        assertEq(rewardBalanceOf(user1), pending); // checking if pending rewards are recorded in rewardBalances
        vm.stopPrank();
    }

    // ------------------------------------------------------
    // Unstake
    // ------------------------------------------------------
    function test_Revert_Unstake_InsufficientBalance() public {
        vm.startPrank(user1);

        token.approve(address(staking), MIN_STAKE);
        staking.stake(MIN_STAKE);

        vm.warp(block.timestamp + STAKE_PERIOD);

        vm.expectRevert(abi.encodeWithSelector(
            StakingContract.InsufficientStakedBalance.selector,
            MIN_STAKE + 1,
            MIN_STAKE
        ));

        staking.unstake(MIN_STAKE + 1);
        vm.stopPrank();
    }

    function test_Revert_Unstake_PeriodNotMet() public {
        vm.startPrank(user1);

        token.approve(address(staking), MIN_STAKE);
        staking.stake(MIN_STAKE);
        vm.expectRevert(StakingContract.StakingPeriodNotMet.selector); 

        staking.unstake(MIN_STAKE);
        vm.stopPrank();
    }

    function test_Unstake_PartialThenRest() public {
        vm.startPrank(user1);

        token.approve(address(staking), MIN_STAKE);
        staking.stake(MIN_STAKE);

        // accrue for half the period, then wait full period
        vm.warp(block.timestamp + STAKE_PERIOD);

        uint256 pendingBefore = staking.calculateRewards(user1);

        // partial unstake
        uint256 half = MIN_STAKE / 2;
        vm.expectEmit(true, true, false, true, address(staking));
        emit StakingContract.Unstaked(user1, half);
        staking.unstake(half);

        // pending rewards added to rewardBalances
        assertEq(rewardBalanceOf(user1), pendingBefore);
        assertEq(stakeBalance(user1), half);

        // accrue again then fully unstake
        vm.warp(block.timestamp + STAKE_PERIOD);
        uint256 pendingSecond = staking.calculateRewards(user1);
        staking.unstake(half);

        assertEq(stakeBalance(user1), 0);
        assertEq(lastStakeTimeOf(user1), 0);
        assertEq(staking.totalStaked(), 0);


        uint256 user1Received = token.balanceOf(user1);
      
        assertEq(user1Received, 500_000 ether - MIN_STAKE + MIN_STAKE);
        assertEq(rewardBalanceOf(user1), pendingBefore + pendingSecond);
        vm.stopPrank();
    }

    // ------------------------------------------------------
    // Claim Rewards
    // ------------------------------------------------------
    function test_Revert_Claim_WhenNothingToClaim() public {
        vm.expectRevert(StakingContract.NoRewardsToClaim.selector);
        staking.claimRewards();
    }

    function test_Claim_WhileStaking() public {
        vm.startPrank(user1);

        token.approve(address(staking), MIN_STAKE);
        staking.stake(MIN_STAKE);

        vm.warp(block.timestamp + 13);
        uint256 expected = (MIN_STAKE * REWARD_RATE * 13) / 1e18;

        uint256 user1BalBefore = token.balanceOf(user1);

        vm.expectEmit(true, true, false, true, address(staking));
        emit StakingContract.RewardsClaimed(user1, expected);
        staking.claimRewards();

        assertEq(token.balanceOf(user1) - user1BalBefore, expected);
        assertEq(rewardBalanceOf(user1), 0);
        assertEq(staking.calculateRewards(user1), 0); // lastStakeTime reset

        vm.stopPrank();
    }

    function test_Claim_AfterFullyUnstaked_WithBankedRewards() public {
        vm.startPrank(user1);

        token.approve(address(staking), MIN_STAKE);
        staking.stake(MIN_STAKE);
        vm.warp(block.timestamp + STAKE_PERIOD);

        uint256 pending = staking.calculateRewards(user1);
        staking.unstake(MIN_STAKE); // banks pending into rewardBalances and transfers principal

        assertEq(stakeBalance(user1), 0);
        assertEq(rewardBalanceOf(user1), pending);

        uint256 before = token.balanceOf(user1);
        staking.claimRewards();

        assertEq(token.balanceOf(user1) - before, pending);
        assertEq(rewardBalanceOf(user1), 0);
        vm.stopPrank();
    }

    // ------------------------------------------------------
    // Views
    // ------------------------------------------------------
    function test_CalculateRewards_ZeroIfNoStake() public view {
        assertEq(staking.calculateRewards(user1), 0);
    }

    function test_GetTotalRewards_SumsBankedAndPending() public {
        vm.startPrank(user1);

        token.approve(address(staking), 2 * MIN_STAKE);
        staking.stake(MIN_STAKE);

        vm.warp(block.timestamp + 5);
        uint256 pending1 = staking.calculateRewards(user1);
        staking.stake(MIN_STAKE);

        vm.warp(block.timestamp + 7);
        uint256 total = staking.getTotalRewards(user1);
        uint256 expected = pending1 + staking.calculateRewards(user1);

        assertEq(total, expected);
        vm.stopPrank();
    }

    // ------------------------------------------------------
    // Owner Admin
    // ------------------------------------------------------
    function test_UpdateRewardRate_OnlyOwnerAndTakesEffect() public {
        // non-owner
        vm.prank(user1);

        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", user1));
        staking.updateRewardRate(2e18);

        // owner updates
        vm.expectEmit(false, false, false, true, address(staking));
        emit StakingContract.RewardRateUpdated(2e18);
        staking.updateRewardRate(2e18);
        assertEq(staking.rewardRate(), 2e18);

        // effect on rewards
        vm.startPrank(user2);

        token.approve(address(staking), MIN_STAKE);
        staking.stake(MIN_STAKE);

        vm.warp(block.timestamp + 3);

        assertEq(staking.calculateRewards(user2), (MIN_STAKE * 2e18 * 3) / 1e18);
        vm.stopPrank();
    }

    function test_Revert_UpdateRewardRate_ZeroRate() public {
        // Owner attempting to set zero rate should revert with InvalidRewardRate
        vm.expectRevert(StakingContract.InvalidRewardRate.selector);
        staking.updateRewardRate(0);
    }

    function test_UpdateMinimumStakeAmount() public {
        // non-owner
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", user1));
        staking.updateMinimumStakeAmount(1 ether);

        vm.expectRevert(StakingContract.AmountMustBePositive.selector);
        staking.updateMinimumStakeAmount(0);

        staking.updateMinimumStakeAmount(200 ether);
        assertEq(staking.minimumStakeAmount(), 200 ether);
    }

    function test_UpdateStakingPeriod() public {
        // non-owner
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", user1));
        staking.updateStakingPeriod(1 days);

        staking.updateStakingPeriod(10 days);
        assertEq(staking.stakingPeriod(), 10 days);
    }

    function test_EmergencyWithdraw_NoExcess_RevertsNoExcessTokens() public {
        // Seed staking contract with tokens: user1 stakes
        vm.startPrank(user1);

        token.approve(address(staking), MIN_STAKE);
        staking.stake(MIN_STAKE);

        vm.stopPrank();

        uint256 contractBal = token.balanceOf(address(staking));
        assertEq(contractBal, REWARD_FUND + MIN_STAKE);

        // non-owner revert
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", user1));
        staking.emergencyWithdraw();

        // owner schedules; with no excess, calling should revert
        staking.initiateEmergencyWithdraw();
        vm.warp(block.timestamp + 1 days);
        vm.expectRevert(StakingContract.NoExcessTokens.selector);
        staking.emergencyWithdraw();
    }

    // ------------------------------------------------------
    // Large reward rates and very long time periods
    // ------------------------------------------------------
    function test_LargeRewardRate_LongTime_CalculateRewards_AtBoundary_DoesNotRevert() public {
        // user1 stakes minimum
        vm.startPrank(user1);

        token.approve(address(staking), MIN_STAKE);
        staking.stake(MIN_STAKE);

        vm.stopPrank();

        // Use a very long period 
        uint256 T = 50 * 365 days;
        // Bounding the reward rate such that staked * rate * T fits in uint256
        uint256 denom = MIN_STAKE * T;
        uint256 maxSafeRate = type(uint256).max / denom;
        if (maxSafeRate == 0) {
            maxSafeRate = 1;
        }
        staking.updateRewardRate(maxSafeRate);

        vm.warp(block.timestamp + T);

        // Should not revert at the exact boundary
        uint256 r = staking.calculateRewards(user1);
        assertGt(r, 0);
    }

    function test_LargeRewardRate_LongTime_CalculateRewards_OverflowReverts() public {
        // user1 stakes minimum
        vm.startPrank(user1);

        token.approve(address(staking), MIN_STAKE);
        staking.stake(MIN_STAKE);
         
        vm.stopPrank();

        uint256 T = 50 * 365 days;
        uint256 denom = MIN_STAKE * T;
        uint256 maxSafeRate = type(uint256).max / denom;
        uint256 overflowRate = maxSafeRate + 1;
        staking.updateRewardRate(overflowRate);

        vm.warp(block.timestamp + T);

        // View should revert due to checked overflow during multiplication
        vm.expectRevert();
        staking.calculateRewards(user1);
    }

    function test_LargeRewardRate_LongTime_Claim_OverflowReverts() public {
        // user1 stakes minimum
        vm.startPrank(user1);

        token.approve(address(staking), MIN_STAKE);
        staking.stake(MIN_STAKE);

        vm.stopPrank();

        uint256 T = 50 * 365 days;
        uint256 denom = MIN_STAKE * T;
        uint256 maxSafeRate = type(uint256).max / denom;
        uint256 overflowRate = maxSafeRate + 1;
        staking.updateRewardRate(overflowRate);

        vm.warp(block.timestamp + T);

        vm.startPrank(user1);

        vm.expectRevert();
        staking.claimRewards();

        vm.stopPrank();
    }

    function test_VeryLongPeriod_Claim_Succeeds_WithPrefunding() public {
        // Use current (moderate) reward rate over a long period, and funding the contract
        uint256 T = 10 * 365 days;

        vm.startPrank(user1);

        token.approve(address(staking), MIN_STAKE);
        staking.stake(MIN_STAKE);

        vm.stopPrank();

        vm.warp(block.timestamp + T);

        // Compute expected safely; these values are well within uint256
        uint256 expected = (MIN_STAKE * staking.rewardRate() * T) / 1e18;

        // Ensure contract has enough liquidity to pay rewards (funding from user1's large balance)
        vm.startPrank(user1);
        {
            bool sent = token.transfer(address(staking), expected);
            assertTrue(sent);
        }
        vm.stopPrank();

        vm.startPrank(user1);

        uint256 before = token.balanceOf(user1);
        staking.claimRewards();

        assertEq(token.balanceOf(user1) - before, expected);
        vm.stopPrank();
    }

    // ------------------------------------------------------
    // Multiple rate changes during a long single stake
    // ------------------------------------------------------
    function test_MultiRateSegments_ThreeChanges_SingleClaim() public {
        // user1 stakes once
        vm.startPrank(user1);

        token.approve(address(staking), MIN_STAKE);
        staking.stake(MIN_STAKE);

        vm.stopPrank();

        // Segment 1 at initial rate
        uint256 r1 = staking.rewardRate(); // initial REWARD_RATE
        uint256 t1 = 10 days;
        vm.warp(block.timestamp + t1);

        // Change to rate 2 and accrue Segment 2
        uint256 r2New = 2e9; // modest new rate
        staking.updateRewardRate(r2New);
        uint256 r2 = staking.rewardRate();
        uint256 t2 = 15 days;
        vm.warp(block.timestamp + t2);

        // Change to rate 3 and accrue Segment 3
        uint256 r3New = 3e9;
        staking.updateRewardRate(r3New);
        uint256 r3 = staking.rewardRate();
        uint256 t3 = 20 days;
        vm.warp(block.timestamp + t3);

        // Expected = sum over segments with the rate active in each interval
        uint256 expected1 = (MIN_STAKE * r1 * t1) / 1e18;
        uint256 expected2 = (MIN_STAKE * r2 * t2) / 1e18;
        uint256 expected3 = (MIN_STAKE * r3 * t3) / 1e18;
        uint256 expectedTotal = expected1 + expected2 + expected3;

        vm.startPrank(user1);

        uint256 before = token.balanceOf(user1);
        staking.claimRewards();
        uint256 paid = token.balanceOf(user1) - before;

        assertEq(paid, expectedTotal);
        assertEq(rewardBalanceOf(user1), 0);
        assertEq(staking.calculateRewards(user1), 0);
        vm.stopPrank();
    }

    function test_MultiRateSegments_LongHorizon_ManyChanges_SingleClaim() public {
        // user1 stakes once
        vm.startPrank(user1);

        token.approve(address(staking), MIN_STAKE);
        staking.stake(MIN_STAKE);

        vm.stopPrank();

        // Segment 1
        uint256 r1 = staking.rewardRate();
        uint256 t1 = 30 days;
        vm.warp(block.timestamp + t1);

        // Change 1 -> r2
        uint256 r2New = 2e9;
        staking.updateRewardRate(r2New);
        uint256 r2 = staking.rewardRate();
        uint256 t2 = 45 days;
        vm.warp(block.timestamp + t2);

        // Change 2 -> r3
        uint256 r3New = 5e9;
        staking.updateRewardRate(r3New);
        uint256 r3 = staking.rewardRate();
        uint256 t3 = 60 days;
        vm.warp(block.timestamp + t3);

        // Change 3 -> r4
        uint256 r4New = 4e9;
        staking.updateRewardRate(r4New);
        uint256 r4 = staking.rewardRate();
        uint256 t4 = 75 days;
        vm.warp(block.timestamp + t4);

        uint256 expected = 0;
        expected += (MIN_STAKE * r1 * t1) / 1e18;
        expected += (MIN_STAKE * r2 * t2) / 1e18;
        expected += (MIN_STAKE * r3 * t3) / 1e18;
        expected += (MIN_STAKE * r4 * t4) / 1e18;

        // funding the contract if needed
        if (token.balanceOf(address(staking)) < expected + MIN_STAKE) {
            vm.startPrank(user1);
            {
                bool sent = token.transfer(address(staking), expected);
                assertTrue(sent);
            }
            vm.stopPrank();
        }

        vm.startPrank(user1);

        uint256 balBefore = token.balanceOf(user1);
        staking.claimRewards();
        uint256 got = token.balanceOf(user1) - balBefore;

        assertEq(got, expected);
        assertEq(rewardBalanceOf(user1), 0);
        assertEq(staking.calculateRewards(user1), 0);
        vm.stopPrank();
    }

    function test_MultiRateSegments_WithRestake_BetweenChanges() public {
        // user1 stakes initially
        vm.startPrank(user1);
        token.approve(address(staking), 3 * MIN_STAKE);
        staking.stake(MIN_STAKE);
        vm.stopPrank();

        // Segment 1 at initial rate r1
        uint256 r1 = staking.rewardRate();
        uint256 t1 = 5 days;
        vm.warp(block.timestamp + t1);

        // Owner updates to r2
        uint256 r2New = 2e9;
        staking.updateRewardRate(r2New);
        uint256 r2 = staking.rewardRate();

        // Segment 2 at r2 with original balance
        uint256 t2 = 7 days;
        vm.warp(block.timestamp + t2);

        // user1 restakes additional amount; pending S1+S2 banked
        vm.startPrank(user1);
        staking.stake(2 * MIN_STAKE);
        vm.stopPrank();

        // Segment 3 continues at r2 but with increased balance
        uint256 t3 = 3 days;
        vm.warp(block.timestamp + t3);

        // Owner updates to r3
        uint256 r3New = 3e9;
        staking.updateRewardRate(r3New);
        uint256 r3 = staking.rewardRate();

        // Segment 4 at r3 with increased balance
        uint256 t4 = 4 days;
        vm.warp(block.timestamp + t4);

        // Expected piecewise rewards
        uint256 expected12 = (MIN_STAKE * r1 * t1) / 1e18
            + (MIN_STAKE * r2 * t2) / 1e18;
        uint256 postRestakeBal = 3 * MIN_STAKE;
        uint256 expected34 = (postRestakeBal * r2 * t3) / 1e18
            + (postRestakeBal * r3 * t4) / 1e18;
        uint256 expected = expected12 + expected34;

        // Ensure sufficient liquidity
        uint256 needed = expected + staking.totalStaked();
        if (token.balanceOf(address(staking)) < needed) {
            vm.startPrank(user1);

            {
                uint256 delta = needed - token.balanceOf(address(staking));
                bool sent = token.transfer(address(staking), delta);
                assertTrue(sent);
            }

            vm.stopPrank();
        }

        // Single claim pays all segments
        vm.startPrank(user1);

        uint256 before = token.balanceOf(user1);
        staking.claimRewards();

        uint256 paid = token.balanceOf(user1) - before;

        assertEq(paid, expected);
        assertEq(rewardBalanceOf(user1), 0);
        assertEq(staking.calculateRewards(user1), 0);

        vm.stopPrank();
    }

    // ------------------------------------------------------
    // Fuzz Tests
    // ------------------------------------------------------
    function testFuzz_Unstake(uint128 stakeAmountRaw, uint128 unstakeAmountRaw, uint64 warpSecondsRaw) public {
        // bound inputs
        uint256 user1Bal = token.balanceOf(user1);
        uint256 stakeAmount = bound(uint256(stakeAmountRaw), MIN_STAKE, user1Bal);
        uint256 unstakeAmount = bound(uint256(unstakeAmountRaw), 1, stakeAmount);
        uint256 warpSeconds = bound(uint256(warpSecondsRaw), STAKE_PERIOD, STAKE_PERIOD + 30 days);

        // fund user1 sufficiently
        vm.startPrank(user1);
        token.approve(address(staking), stakeAmount);

        staking.stake(stakeAmount);
        vm.warp(block.timestamp + warpSeconds);

        uint256 pendingBefore = staking.calculateRewards(user1);
        staking.unstake(unstakeAmount);

        // invariants
        assertEq(staking.totalStaked(), stakeAmount - unstakeAmount);
        assertEq(stakeBalance(user1), stakeAmount - unstakeAmount);
        assertEq(rewardBalanceOf(user1), pendingBefore);

        // lastStakeTime updated if still staking
        if (stakeAmount - unstakeAmount > 0) {
            assertEq(lastStakeTimeOf(user1), block.timestamp);
        } else {
            assertEq(lastStakeTimeOf(user1), 0);
        }
        vm.stopPrank();
    }

    function testFuzz_ClaimRewards(uint128 stakeAmountRaw, uint64 warpSecondsRaw) public {
        uint256 stakeAmount = bound(uint256(stakeAmountRaw), MIN_STAKE, token.balanceOf(user1));
        uint256 warpSeconds = uint256(bound(warpSecondsRaw, 1, 30 days));

        vm.startPrank(user1);
        token.approve(address(staking), stakeAmount);
        staking.stake(stakeAmount);

        vm.warp(block.timestamp + warpSeconds);

        uint256 expected = (stakeAmount * staking.rewardRate() * warpSeconds) / 1e18;
        uint256 before = token.balanceOf(user1);
        staking.claimRewards();

        // exact equality given pure integer math
        assertEq(token.balanceOf(user1) - before, expected);
        assertEq(rewardBalanceOf(user1), 0);
        // accrual restarts after claim
        assertEq(staking.calculateRewards(user1), 0);
        vm.stopPrank();
    }
    
    function testFuzz_Restake_MultiSegmentAccrual(
        uint128 a1Raw,
        uint128 a2Raw,
        uint64 t1Raw,
        uint64 t2Raw
    ) public {
        uint256 user1Bal = token.balanceOf(user1);
        // ensure room for two stakes
        uint256 a1 = bound(uint256(a1Raw), MIN_STAKE, user1Bal - MIN_STAKE);
        uint256 a2 = bound(uint256(a2Raw), MIN_STAKE, user1Bal - a1);
        uint256 t1 = uint256(bound(t1Raw, 1, 30 days));
        uint256 t2 = uint256(bound(t2Raw, 1, 30 days));

        vm.startPrank(user1);
        token.approve(address(staking), a1 + a2);
        staking.stake(a1);

        vm.warp(block.timestamp + t1);
        uint256 rate = staking.rewardRate();
        uint256 expected1 = (a1 * rate * t1) / 1e18;

        // restake banks first segment
        staking.stake(a2);
        assertEq(rewardBalanceOf(user1), expected1);

        vm.warp(block.timestamp + t2);
        uint256 expected2 = ((a1 + a2) * rate * t2) / 1e18;

        uint256 before = token.balanceOf(user1);
        staking.claimRewards();

        uint256 paid = token.balanceOf(user1) - before;
        assertEq(paid, expected1 + expected2);

        vm.stopPrank();
    }

    function testFuzz_MultiActor_TotalStaked(uint128 auser1Raw, uint128 auser2Raw) public {
        uint256 auser1 = bound(uint256(auser1Raw), MIN_STAKE, token.balanceOf(user1));
        uint256 auser2 = bound(uint256(auser2Raw), MIN_STAKE, token.balanceOf(user2));

        vm.startPrank(user1);

        token.approve(address(staking), auser1);
        staking.stake(auser1);

        vm.stopPrank();

        vm.startPrank(user2);

        token.approve(address(staking), auser2);
        staking.stake(auser2);

        vm.stopPrank();

        assertEq(staking.totalStaked(), auser1 + auser2);
        assertEq(stakeBalance(user1) + stakeBalance(user2), staking.totalStaked());
    }

    function testFuzz_UpdateRewardRate_Segmented(
        uint128 amountRaw,
        uint64 t1Raw,
        uint64 t2Raw,
        uint64 newRateRaw
    ) public {
        uint256 amount = bound(uint256(amountRaw), MIN_STAKE, token.balanceOf(user1));
        // keep times and new rate modest to avoid exhausting the reward pool
        uint256 t1 = uint256(bound(t1Raw, 1, 3 days));
        uint256 t2 = uint256(bound(t2Raw, 1, 3 days));
        uint256 newRate = uint256(bound(newRateRaw, 1, 1e12));

        vm.startPrank(user1);

        token.approve(address(staking), amount);
        staking.stake(amount);

        vm.warp(block.timestamp + t1);

        uint256 before1 = token.balanceOf(user1);
        uint256 expected1 = (amount * staking.rewardRate() * t1) / 1e18;
   
        {
            uint256 reserve = staking.rewardReserve();
            if (reserve < expected1) {
                uint256 diff = expected1 - reserve;
                vm.startPrank(user2);
                {
                    bool moved = token.transfer(owner, diff);
                    assertTrue(moved);
                }
                vm.stopPrank();

                token.approve(address(staking), diff);
                staking.fundRewardReserve(diff);
            }
        }
        // ensure msg.sender is user1 after owner/user2 actions
        vm.startPrank(user1);

        staking.claimRewards();
        assertEq(token.balanceOf(user1) - before1, expected1);

        vm.stopPrank();

        // owner updates reward rate
        staking.updateRewardRate(newRate);

        vm.startPrank(user1);
        vm.warp(block.timestamp + t2);

        uint256 before2 = token.balanceOf(user1);
        uint256 expected2 = (amount * newRate * t2) / 1e18;
        // ensure reserve can cover the second claim
        {
            uint256 reserve2 = staking.rewardReserve();
            if (reserve2 < expected2) {
                uint256 diff2 = expected2 - reserve2;

                vm.startPrank(user2);

                {
                    bool moved2 = token.transfer(owner, diff2);
                    assertTrue(moved2);
                }

                vm.stopPrank();

                token.approve(address(staking), diff2);
                staking.fundRewardReserve(diff2);
            }
        }
        // ensure msg.sender is user1 after owner/user2 actions
        vm.startPrank(user1);

        staking.claimRewards();
        assertEq(token.balanceOf(user1) - before2, expected2);

        vm.stopPrank();
    }

    function testFuzz_UpdateMinimumStakeAmount_Boundary(uint256 newMinRaw) public {
        uint256 user2Bal = token.balanceOf(user2);
        uint256 newMin = bound(newMinRaw, 1, user2Bal);

        // owner sets new minimum
        staking.updateMinimumStakeAmount(newMin);

        // below boundary should revert
        if (newMin > 1) {
            vm.startPrank(user2);

            token.approve(address(staking), newMin - 1);
            vm.expectRevert(StakingContract.AmountTooLow.selector);
            staking.stake(newMin - 1);

            vm.stopPrank();
        }

        // at boundary should succeed
        vm.startPrank(user2);

        token.approve(address(staking), newMin);
        staking.stake(newMin);
        assertEq(stakeBalance(user2), newMin);

        vm.stopPrank();
    }

    function testFuzz_UpdateStakingPeriod_MidStake(uint64 elapsedRaw, uint64 extraRaw) public {
        // user1 stakes
        vm.startPrank(user1);

        token.approve(address(staking), MIN_STAKE);
        staking.stake(MIN_STAKE);

        vm.stopPrank();

        uint256 elapsed = uint256(bound(elapsedRaw, 1 hours, 3 days));
        vm.warp(block.timestamp + elapsed);

        // Increase period beyond elapsed
        uint256 extra = uint256(bound(extraRaw, 1, 10 days));
        uint256 newPeriod = elapsed + extra;
        staking.updateStakingPeriod(newPeriod);

        vm.startPrank(user1);
        vm.expectRevert();
        staking.unstake(MIN_STAKE);

        // After enough time, unstake should pass
        vm.warp(block.timestamp + extra);
        staking.unstake(MIN_STAKE);

        assertEq(stakeBalance(user1), 0);
        vm.stopPrank();
    }

    function testFuzz_EmergencyWithdraw_NoExcess_Reverts_AndOperationsContinue(uint128 a1Raw, uint128 a2Raw) public {
        uint256 a1 = bound(uint256(a1Raw), MIN_STAKE, token.balanceOf(user1));
        uint256 a2 = bound(uint256(a2Raw), MIN_STAKE, token.balanceOf(user2));

        vm.startPrank(user1);

        token.approve(address(staking), a1);
        staking.stake(a1);

        vm.stopPrank();

        vm.startPrank(user2);

        token.approve(address(staking), a2);
        staking.stake(a2);

        vm.stopPrank();

        staking.initiateEmergencyWithdraw();
        vm.warp(block.timestamp + 1 days);

        vm.expectRevert(StakingContract.NoExcessTokens.selector);
        staking.emergencyWithdraw();

        // After no-op, operations should still work
        vm.startPrank(user1);

        vm.warp(block.timestamp + STAKE_PERIOD);
        staking.unstake(a1);
        vm.stopPrank();

        vm.warp(block.timestamp + 1 days);
        // ensure reserve can pay; top up if needed using owner funded by user1
        uint256 pending = staking.calculateRewards(user2);
        uint256 available = token.balanceOf(address(staking)) - staking.totalStaked();
        if (pending > available) {
            uint256 diff = pending - available;
            vm.startPrank(user1);

            {
                bool moved = token.transfer(owner, diff);
                assertTrue(moved);
            }

            vm.stopPrank();

            token.approve(address(staking), diff);
            staking.fundRewardReserve(diff);
        }
        vm.startPrank(user2);

        staking.claimRewards();

        vm.stopPrank();
    }

    function testFuzz_CalculateRewards_Monotonic(
        uint128 amountRaw,
        uint64 t1Raw,
        uint64 t2Raw
    ) public {
        uint256 amount = bound(uint256(amountRaw), MIN_STAKE, token.balanceOf(user1));
        uint256 t1 = uint256(bound(t1Raw, 1, 7 days));
        uint256 t2 = uint256(bound(t2Raw, t1, t1 + 7 days));

        vm.startPrank(user1);
        token.approve(address(staking), amount);
        staking.stake(amount);

        vm.warp(block.timestamp + t1);

        uint256 r1 = staking.calculateRewards(user1);

        vm.warp(block.timestamp + (t2 - t1));

        uint256 r2 = staking.calculateRewards(user1);

        assertGe(r2, r1);
        vm.stopPrank();
    }

    function test_Claim_Revert_WhenZeroRewardsButStaking() public {
        vm.startPrank(user1);
        token.approve(address(staking), MIN_STAKE);
        staking.stake(MIN_STAKE);

        // no time advance, pendingRewards == 0, rewardBalances == 0
        vm.expectRevert(StakingContract.NoRewardsToClaim.selector);
        staking.claimRewards();

        vm.stopPrank();
    }

    // Additional negative cases using MockERC20
    function test_Revert_Stake_InsufficientAllowance() public {
        vm.startPrank(user1);
        token.approve(address(staking), MIN_STAKE - 1);

        vm.expectRevert();
        staking.stake(MIN_STAKE);

        vm.stopPrank();
    }

    function test_Claim_AfterEmergencyWithdraw_NoExcess_StillWorks() public {
        vm.startPrank(user1);

        token.approve(address(staking), MIN_STAKE);
        staking.stake(MIN_STAKE);

        vm.warp(block.timestamp + 2 days);

        vm.stopPrank();

        // Owner schedules emergency withdraw and waits for timelock
        staking.initiateEmergencyWithdraw();
        vm.warp(block.timestamp + 1 days);

        // No excess -> call reverts
        vm.expectRevert(StakingContract.NoExcessTokens.selector);
        staking.emergencyWithdraw();

        vm.startPrank(user1);

        uint256 before = token.balanceOf(user1);
        staking.claimRewards();

        assertGt(token.balanceOf(user1) - before, 0);
        vm.stopPrank();
    }

    function test_Stake_Revert_WhenTransferFromReturnsFalse_Mocked() public {
        // Make any transferFrom call return false
        vm.mockCall(
            address(token),
            abi.encodeWithSelector(IERC20.transferFrom.selector),
            abi.encode(false)
        );

        vm.startPrank(user1);
        token.approve(address(staking), MIN_STAKE);

        vm.expectRevert();
        staking.stake(MIN_STAKE);

        vm.stopPrank();
    }

    function test_Unstake_Revert_WhenTransferReturnsFalse_Mocked() public {
        vm.startPrank(user1);
        token.approve(address(staking), MIN_STAKE);
        staking.stake(MIN_STAKE);
        vm.stopPrank();

        vm.warp(block.timestamp + STAKE_PERIOD);

        // Make any transfer call return false
        vm.mockCall(
            address(token),
            abi.encodeWithSelector(IERC20.transfer.selector),
            abi.encode(false)
        );

        vm.startPrank(user1);

        vm.expectRevert();
        staking.unstake(MIN_STAKE);

        vm.stopPrank();
    }

    function test_Claim_Revert_WhenTransferReturnsFalse_Mocked() public {
        // Stake
        vm.startPrank(user1);

        token.approve(address(staking), MIN_STAKE);
        staking.stake(MIN_STAKE);
        vm.warp(block.timestamp + 1 days);

        vm.stopPrank();

        // Force transfer false
        vm.mockCall(
            address(token),
            abi.encodeWithSelector(IERC20.transfer.selector),
            abi.encode(false)
        );

        vm.startPrank(user1);

        vm.expectRevert();
        staking.claimRewards();

        vm.stopPrank();
    }

    function test_EmergencyWithdraw_Revert_WhenTransferReturnsFalse_Mocked() public {
        // Ensure staking contract has balance (setUp already transferred REWARD_FUND)
        assertGt(token.balanceOf(address(staking)), 0);

        // Schedule and wait for timelock to ensure we test the transfer path
        staking.initiateEmergencyWithdraw();
        vm.warp(block.timestamp + 1 days);

        // Force transfer false for owner payout
        vm.mockCall(
            address(token),
            abi.encodeWithSelector(IERC20.transfer.selector),
            abi.encode(false)
        );

        vm.expectRevert();
        staking.emergencyWithdraw();
    }

    // ------------------------------------------------------
    // Timelock tests for emergencyWithdraw
    // ------------------------------------------------------
    function test_Revert_EmergencyWithdraw_BeforeSchedule() public {
        vm.expectRevert(StakingContract.StakingPeriodNotMet.selector);
        staking.emergencyWithdraw();
    }

    function test_InitiateEmergencyWithdraw_SetsAvailableAt_AndEmits() public {
        uint256 expected = block.timestamp + 1 days;

        vm.expectEmit(false, false, false, true, address(staking));
        emit StakingContract.EmergencyWithdrawScheduled(expected);

        staking.initiateEmergencyWithdraw();
        assertEq(staking.emergencyWithdrawAvailableAt(), expected);
    }

    function test_Revert_EmergencyWithdraw_BeforeDelayElapsed() public {
        staking.initiateEmergencyWithdraw();
        // Advance less than delay
        vm.warp(block.timestamp + 1 days - 1);
        
        vm.expectRevert(StakingContract.StakingPeriodNotMet.selector);
        staking.emergencyWithdraw();
    }

    function test_EmergencyWithdraw_AfterDelay_TransfersOnlyExcess_AndResetsSchedule() public {
        uint256 dust = 123 ether;

        vm.startPrank(user1);

        bool success = token.transfer(address(staking), dust);
        assertEq(success, true);

        vm.stopPrank();
        uint256 accountedBefore = staking.contractBalance();
        uint256 balanceBefore = token.balanceOf(address(staking));
        assertEq(balanceBefore, accountedBefore + dust);

        staking.initiateEmergencyWithdraw();
        vm.warp(block.timestamp + 1 days);

        uint256 ownerBefore = token.balanceOf(owner);
        staking.emergencyWithdraw();

        assertEq(staking.emergencyWithdrawAvailableAt(), 0);
        assertEq(token.balanceOf(address(staking)), balanceBefore - dust);
        assertEq(token.balanceOf(owner), ownerBefore + dust);
        // accounted balances unchanged
        assertEq(staking.contractBalance(), accountedBefore);
    }

    function test_FundRewardReserve_IncreasesReserve_AndTransfers() public {
        uint256 addAmount = 10_000 ether;

        vm.startPrank(user1);

        {
            bool moved = token.transfer(owner, addAmount);
            assertTrue(moved);
        }

        vm.stopPrank();

        token.approve(address(staking), addAmount);

        uint256 beforeReserve = staking.rewardReserve();
        uint256 beforeBal = token.balanceOf(address(staking));

        vm.expectEmit(false, false, false, true, address(staking));
        emit StakingContract.RewardReserveFunded(addAmount);
        staking.fundRewardReserve(addAmount);

        assertEq(staking.rewardReserve(), beforeReserve + addAmount);
        assertEq(token.balanceOf(address(staking)), beforeBal + addAmount);
    }

    function test_Revert_FundRewardReserve_ZeroAmount() public {
        vm.expectRevert(StakingContract.AmountMustBePositive.selector);
        staking.fundRewardReserve(0);
    }

    function test_WithdrawFromRewardReserve_DecreasesReserve_AndTransfersTo() public {
        address to = address(0xD1CE);
        uint256 addAmount = 1_000 ether;
        // Move tokens from user1 to owner so owner can fund reserve
        vm.startPrank(user1);

        bool success = token.transfer(owner, addAmount);
        assertTrue(success);

        vm.stopPrank();

        token.approve(address(staking), addAmount);
        staking.fundRewardReserve(addAmount);

        uint256 beforeReserve = staking.rewardReserve();
        uint256 toBefore = token.balanceOf(to);

        vm.expectEmit(true, true, false, true, address(staking));
        emit StakingContract.RewardReserveWithdrawn(to, addAmount);
        staking.withdrawFromRewardReserve(addAmount, to);

        assertEq(staking.rewardReserve(), beforeReserve - addAmount);
        assertEq(token.balanceOf(to) - toBefore, addAmount);
    }

    function test_Revert_WithdrawFromRewardReserve_Insufficient() public {
        uint256 insuff = staking.rewardReserve() + 1;

        vm.expectRevert(abi.encodeWithSelector(
            StakingContract.InsufficientRewardReserve.selector,
            insuff, staking.rewardReserve()
        ));

        staking.withdrawFromRewardReserve(insuff, owner);
    }

    function test_Revert_WithdrawFromRewardReserve_ZeroToOrAmount() public {
        vm.expectRevert(StakingContract.AmountMustBePositive.selector);
        staking.withdrawFromRewardReserve(0, owner);

        vm.expectRevert(StakingContract.ZeroAddress.selector);
        staking.withdrawFromRewardReserve(1, address(0));
    }

    function test_ClaimRewards_DebitsRewardReserve() public {
        // user1 stakes and accrues
        vm.startPrank(user1);

        token.approve(address(staking), MIN_STAKE);
        staking.stake(MIN_STAKE);

        vm.warp(block.timestamp + 10 days);
        vm.stopPrank();

        uint256 expected = staking.calculateRewards(user1);
        uint256 reserveBefore = staking.rewardReserve();

        vm.startPrank(user1);
        staking.claimRewards();
        vm.stopPrank();

        assertEq(staking.rewardReserve(), reserveBefore - expected);
    }

    function test_Revert_ClaimRewards_InsufficientReserve() public {
        // Drain the reward reserve so that any claim must revert
        uint256 reserve = staking.rewardReserve();
        if (reserve > 0) {
            staking.withdrawFromRewardReserve(reserve, owner);
        }


        vm.startPrank(user1);

        token.approve(address(staking), MIN_STAKE);
        staking.stake(MIN_STAKE);

        vm.warp(block.timestamp + 3 days);

        vm.expectRevert();
        staking.claimRewards();

        vm.stopPrank();
    }

    function test_WithdrawExcessTokens_OnlyExcess_CapsAmount() public {
        // add dust as excess
        uint256 dust = 777 ether;

        vm.startPrank(user1);

        bool success = token.transfer(address(staking), dust);
        assertEq(success, true);

        vm.stopPrank();

        uint256 accounted = staking.contractBalance();
        uint256 balance = token.balanceOf(address(staking));

        assertEq(balance - accounted, dust);

        // withdraw more than available; should cap to actual excess
        uint256 ownerBefore = token.balanceOf(owner);

        vm.expectEmit(true, true, false, true, address(staking));
        emit StakingContract.ExcessTokensWithdrawn(owner, dust);
        staking.withdrawExcessTokens(dust * 10, owner);

        assertEq(token.balanceOf(owner) - ownerBefore, dust);
        assertEq(token.balanceOf(address(staking)), balance - dust);
    }

    function test_Revert_WithdrawExcessTokens_WhenNone() public {
        vm.expectRevert(StakingContract.NoExcessTokens.selector);
        staking.withdrawExcessTokens(1, owner);
    }

    function test_Revert_WithdrawExcessTokens_ZeroAmount() public {
        vm.expectRevert(StakingContract.AmountMustBePositive.selector);
        staking.withdrawExcessTokens(0, owner);
    }

    function test_Revert_WithdrawExcessTokens_ZeroTo() public {
        vm.expectRevert(StakingContract.ZeroAddress.selector);
        staking.withdrawExcessTokens(1, address(0));
    }
}

