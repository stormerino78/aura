// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAlphaModule} from "../../interfaces/IAlphaModule.sol";

contract MockAlphaModule is IAlphaModule {
    uint256 public notionalExposure;

    function setNotionalExposure(uint256 _exposure) external {
        notionalExposure = _exposure;
    }

    function getNotionalExposure() external view returns (uint256) {
        return notionalExposure;
    }
}