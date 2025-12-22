// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {VRFCoordinatorV2Mock as ChainlinkVRFCoordinatorV2Mock} from "@chainlink/contracts/src/v0.8/vrf/mocks/VRFCoordinatorV2Mock.sol";

// Re-export Chainlink's VRFCoordinatorV2Mock for easier imports
contract VRFCoordinatorV2Mock is ChainlinkVRFCoordinatorV2Mock {
    constructor(uint96 _baseFee, uint96 _gasPriceLink) ChainlinkVRFCoordinatorV2Mock(_baseFee, _gasPriceLink) {}
}
