// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/**
 * @title IPriceOracle
 * @notice A standardized interface for all price oracles integrated with the DRG.
 * @dev This allows the DRG to treat different oracle providers (e.g., Chainlink, Pyth, Hyperliquid)
 * in a uniform way, enhancing modularity and security through redundancy.
 */
interface IPriceOracle {
    /**
     * @notice Returns the latest price of a given asset.
     * @return price The latest price of the asset, returned with 18 decimals of precision.
     */
    function latestPrice() external view returns (uint256 price);
}