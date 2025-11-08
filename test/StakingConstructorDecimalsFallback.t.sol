// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {StakingContract} from "../src/StakingContract.sol";

// Minimal token with no decimals() implementation to trigger the constructor catch branch
contract NoDecimalsToken {
    // intentionally empty; no IERC20Metadata.decimals()
}

contract StakingConstructorDecimalsFallbackTest is Test {
    function test_REWARD_SCALE_Fallback_WhenNoDecimals() public {
        address token = address(new NoDecimalsToken());
        StakingContract s = new StakingContract(1, 1, 1, token);
        assertEq(s.REWARD_SCALE(), 1e18);
    }
}


