// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, StdInvariant} from "forge-std/Test.sol";
import {StakingContract} from "../../src/StakingContract.sol";
import {MockERC20} from "../../src/MockERC20.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

contract TotalStakedHandler is Test {
    StakingContract internal staking;
    MockERC20 internal token;

    address[] internal actors;
    uint256 internal immutable MIN_STAKE;

    constructor(StakingContract _staking, MockERC20 _token, address[] memory _actors) {
        staking = _staking;
        token = _token;
        actors = _actors;
        MIN_STAKE = staking.minimumStakeAmount();

        // Pre-approve staking for each actor (balances are funded in the test setUp)
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

    // Randomized staking action; Foundry will fuzz the inputs.
    function stakeRandom(uint256 actorSeed, uint256 amountRaw) external {
        address a = _actor(actorSeed);

        uint256 bal = token.balanceOf(a);
        if (bal < MIN_STAKE) {
            return; // nothing to do for this actor
        }

        uint256 amt = bound(amountRaw, MIN_STAKE, bal);

        vm.startPrank(a);
        staking.stake(amt);
        vm.stopPrank();
    }
}

contract TotalStakedInvariant is StdInvariant {
    // System under test
    StakingContract internal staking;
    MockERC20 internal token;
    TotalStakedHandler internal handler;

    // Config
    uint256 internal constant REWARD_RATE = 1e9;
    uint256 internal constant MIN_STAKE = 100 ether;
    uint256 internal constant STAKE_PERIOD = 7 days;

    function setUp() public {
        // Deploy token and staking
        token = new MockERC20();
        {
            address implementation = address(new StakingContract());
            address proxy = UnsafeUpgrades.deployUUPSProxy(
                implementation,
                abi.encodeCall(
                    StakingContract.initialize, (REWARD_RATE, MIN_STAKE, STAKE_PERIOD, address(token), address(this))
                )
            );
            staking = StakingContract(proxy);
        }

        // Prepare a set of actors
        address[] memory actors = new address[](10);
        for (uint256 i = 0; i < actors.length; i++) {
            actors[i] = address(uint160(uint256(keccak256(abi.encodePacked("ACTOR", i)))));
        }

        // Distribute balances to actors and prefund staking for rewards
        uint256 perActor = 50_000 ether; // 10 * 50k = 500k
        for (uint256 i = 0; i < actors.length; i++) {
            bool ok = token.transfer(actors[i], perActor);
            require(ok, "transfer to actor failed");
        }
        {
            bool ok2 = token.transfer(address(staking), 500_000 ether); // remaining 500k
            require(ok2, "prefund transfer failed");
        }

        // Create handler responsible for randomized actions
        handler = new TotalStakedHandler(staking, token, actors);

        // Target the handler for invariant fuzzing
        targetContract(address(handler));
    }

    // Invariant: totalStaked equals the sum of all individual stake balances
    function invariant_totalStakedEqualsSumOfBalances() public view {
        // Sum over all addresses that the handler can manipulate
        uint256 sum;
        // Retrieve actors from handler by reading storage layout
        // Since actors is internal in the handler, we reconstruct the same set deterministically
        for (uint256 i = 0; i < 10; i++) {
            address a = address(uint160(uint256(keccak256(abi.encodePacked("ACTOR", i)))));
            (uint256 bal,,) = staking.stakes(a);
            sum += bal;
        }

        require(staking.totalStaked() == sum, "totalStaked must equal sum of individual balances");
    }
}

