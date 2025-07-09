// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/**
 * @title IL1Read
 * @notice Interface for interacting with Hyperliquid's L1 precompiles.
 * @dev This provides direct, low-cost access to HyperCore data, such as native oracle prices.
 * The functions and addresses are based on Hyperliquid's official documentation.
 */
interface IL1Read {
    /**
     * @notice Fetches the oracle price for a given perpetual asset index from the HyperCore precompile.
     * @param index The unique index of the perpetual asset.
     * @return price The raw oracle price. Precision varies and must be handled using asset metadata.
     */
    function oraclePx(uint32 index) external view returns (uint128 price);

    /**
     * @notice Fetches metadata for a given perpetual asset, including its decimal precision.
     * @param index The unique index of the perpetual asset.
     * @return name The name of the asset.
     * @return szDecimals The number of decimals for the asset's price.
     */
    function perpAssetInfo(uint32 index) external view returns (string memory name, uint32 szDecimals);
}