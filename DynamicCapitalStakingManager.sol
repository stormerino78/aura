// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

interface IYieldStrategy {
    /**
     * @notice Returns the underlying asset this strategy works with (e.g., USDC).
     */
    function asset() external view returns (address);

    /**
     * @notice Deposits the underlying asset into the yield protocol.
     * @param amount The amount of the asset to deposit.
     * @return success A boolean indicating if the deposit was successful.
     */
    function deposit(uint256 amount) external returns (bool success);

    /**
     * @notice Withdraws the underlying asset from the yield protocol.
     * @param amount The amount of the asset to withdraw.
     * @return success A boolean indicating if the withdrawal was successful.
     */
    function withdraw(uint256 amount) external returns (bool success);

    /**
     * @notice Returns the total balance of the underlying asset managed by this strategy.
     * @dev This should include both the principal and any accrued yield.
     * @return The total balance of the underlying asset.
     */
    function balanceOf() external view returns (uint256);
}