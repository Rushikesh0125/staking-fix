// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, StdInvariant} from "forge-std/Test.sol";
import {StakingContract} from "../../src/StakingContract.sol";
import {MockERC20} from "../../src/MockERC20.sol";

contract SystemHandler is Test {
	StakingContract internal staking;
	MockERC20 internal token;

	address[] internal actors;
	uint256 internal immutable MIN_STAKE;
	uint256 internal immutable STAKE_PERIOD;

	constructor(StakingContract _staking, MockERC20 _token, address[] memory _actors) {
		staking = _staking;
		token = _token;
		actors = _actors;
		MIN_STAKE = _staking.minimumStakeAmount();
		STAKE_PERIOD = _staking.stakingPeriod();

		// Pre-approve staking for each actor
		for (uint256 i = 0; i < actors.length; i++) {
			address a = actors[i];
			vm.startPrank(a);
			token.approve(address(staking), type(uint256).max);
			vm.stopPrank();
		}
	}

	function _actor(uint256 seed) internal view returns (address) {
		uint256 idx = seed % actors.length;
		return actors[idx];
	}

	function stakeSome(uint256 actorSeed, uint256 amountRaw) external {
		address a = _actor(actorSeed);
		uint256 bal = token.balanceOf(a);
		if (bal < MIN_STAKE) return;
		uint256 amt = bound(amountRaw, MIN_STAKE, bal);

		vm.startPrank(a);
		staking.stake(amt);
		vm.stopPrank();
	}

	function unstakeSome(uint256 actorSeed, uint256 pctRaw) external {
		address a = _actor(actorSeed);
		(uint256 bal,,uint256 last) = staking.stakes(a);
		if (bal == 0) return;
		// ensure the staking period has elapsed; otherwise do nothing
		if (block.timestamp < last + STAKE_PERIOD) return;

		// choose an amount between 1% and 100% of balance
		uint256 pct = bound(pctRaw, 1, 100);
		uint256 amt = (bal * pct) / 100;
		if (amt == 0) amt = 1;

		vm.startPrank(a);
		staking.unstake(amt);
		vm.stopPrank();
	}

	function claim(uint256 actorSeed) external {
		address a = _actor(actorSeed);
		(uint256 bal,uint256 banked,) = staking.stakes(a);
		// if nothing accrued or banked, skip
		if (bal == 0 && banked == 0) return;
		// Only claim if there is something to claim to avoid revert on zero
		uint256 pending = staking.calculateRewards(a);
		if (pending == 0 && banked == 0) return;

		vm.startPrank(a);
		staking.claimRewards();
		vm.stopPrank();
	}

	function warpTime(uint64 secondsRaw) external {
		// Warp up to 10 days per call to allow unstake windows
		uint256 dt = uint256(bound(secondsRaw, 1, 10 days));
		vm.warp(block.timestamp + dt);
	}
}

contract SystemInvariants is StdInvariant {
	// System under test
	StakingContract internal staking;
	MockERC20 internal token;
	SystemHandler internal handler;

	// Config
	uint256 internal constant REWARD_RATE = 1e9;
	uint256 internal constant MIN_STAKE = 100 ether;
	uint256 internal constant STAKE_PERIOD = 7 days;

	function setUp() public {
		// Deploy token and staking
		token = new MockERC20();
		staking = new StakingContract(REWARD_RATE, MIN_STAKE, STAKE_PERIOD, address(token));

		// Prepare actors
		address[] memory actors = new address[](8);
		for (uint256 i = 0; i < actors.length; i++) {
			actors[i] = address(uint160(uint256(keccak256(abi.encodePacked("SYS_ACTOR", i)))));
		}

		// Distribute balances and prefund reserve generously to avoid claim reverts
		uint256 perActor = 60_000 ether; // 8 * 60k = 480k
		for (uint256 i = 0; i < actors.length; i++) {
			bool ok = token.transfer(actors[i], perActor);
			require(ok, "transfer to actor failed");
		}
		// Move large chunk to the contract as reserve funding
		uint256 reserve = token.balanceOf(address(this)) - 10_000 ether; // leave a buffer on owner
		token.approve(address(staking), reserve);
		staking.fundRewardReserve(reserve);

		// Handler
		handler = new SystemHandler(staking, token, actors);

		// Target the handler for invariant fuzzing across its public methods
		targetContract(address(handler));
	}

	// Invariant: totalStaked equals sum of all staked balances
	function invariant_totalStakedEqualsSum() public view {
		uint256 sum;
		// mirror actor addresses from setUp
		for (uint256 i = 0; i < 8; i++) {
			address a = address(uint160(uint256(keccak256(abi.encodePacked("SYS_ACTOR", i)))));
			(uint256 bal,,) = staking.stakes(a);
			sum += bal;
		}
		require(staking.totalStaked() == sum, "totalStaked must equal sum of balances");
	}

	// Invariant: rewards calculation consistent (constant rate, no rate changes)
	function invariant_rewardsCalculationConsistent() public view {
		uint256 rate = staking.rewardRate();
		for (uint256 i = 0; i < 8; i++) {
			address a = address(uint160(uint256(keccak256(abi.encodePacked("SYS_ACTOR", i)))));
			(uint256 bal,,uint256 last) = staking.stakes(a);
			if (bal == 0) {
				require(staking.calculateRewards(a) == 0, "no rewards when no stake");
			} else {
				uint256 dt = block.timestamp - last;
				uint256 expected = (bal * rate * dt) / 1e18;
				require(staking.calculateRewards(a) == expected, "calculated rewards mismatch");
			}
		}
	}

	// Invariant: state remains consistent after arbitrary operations
	function invariant_stateConsistency() public view {
		for (uint256 i = 0; i < 8; i++) {
			address a = address(uint160(uint256(keccak256(abi.encodePacked("SYS_ACTOR", i)))));
			(uint256 bal,,uint256 last) = staking.stakes(a);
			// lastStakeTime should never be in the future
			require(last <= block.timestamp, "lastStakeTime cannot be in the future");
		}
		// Contract must hold at least accounted tokens
		uint256 accounted = staking.contractBalance();
		require(token.balanceOf(address(staking)) >= accounted, "contract balance below accounted");
	}
}


