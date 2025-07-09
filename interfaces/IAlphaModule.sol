// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @title IAlphaModule
 * @notice Interface that all Alpha Modules must implement to be compatible with the DRG.
 * @dev This interface ensures that the DRG can reliably query the notional exposure of any module,
 * which is critical for enforcing leverage constraints.
 */
interface IAlphaModule {
    /**
     * @notice Returns the total notional value of the module's open positions.
     * @dev This value is used by the DRG to enforce the module's maxLeverage constraint.
     * It is crucial that this function provides an accurate, real-time value.
     * @return notionalExposure The total notional exposure in the vault's base asset, with 18 decimals.
     */
    function getNotionalExposure() external view returns (uint256 notionalExposure);
}
