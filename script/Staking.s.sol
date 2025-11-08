// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script} from "forge-std/Script.sol";
import {StakingContract} from "../src/StakingContract.sol";
import {MockERC20} from "../src/MockERC20.sol";

contract StakingContractScript is Script {
    StakingContract public stakingContract;
    MockERC20 public token;
    function setUp() public {
        token = new MockERC20();
    }

    function run() public {
        vm.startBroadcast();

        stakingContract = new StakingContract(1e9, 100 ether, 7 days, address(token));

        vm.stopBroadcast();
    }
}
