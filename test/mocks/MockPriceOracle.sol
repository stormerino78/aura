// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IPriceOracle} from "../../interfaces/IPriceOracle.sol";

contract MockPriceOracle is IPriceOracle {
    uint256 public price;

    function setPrice(uint256 _price) external {
        price = _price;
    }

    function latestPrice() external view returns (uint256) {
        return price;
    }
}