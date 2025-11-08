// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {StakingContract} from "../../src/StakingContract.sol";

contract StakingContractV2 is StakingContract {
    function version() external pure returns (uint256) {
        return 2;
    }
}

