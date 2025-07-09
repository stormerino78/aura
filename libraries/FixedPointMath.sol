// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/**
 * @title FixedPointMath
 * @notice A simple, gas-efficient library for fixed-point arithmetic with 18 decimals (WAD).
 * @dev Provides safe multiplication, division, and square root operations.
 */
library FixedPointMath {
    uint256 private constant WAD = 1e18;

    /// @dev Thrown when multiplication overflows.
    error MulOverflow(uint256 x, uint256 y);

    /// @dev Thrown when division by zero occurs.
    error DivByZero();

    /**
     * @notice Multiplies two WAD-precision numbers.
     * @return z The product of x and y, maintaining WAD precision.
     */
    function mulWad(uint256 x, uint256 y) internal pure returns (uint256 z) {
        if (x == 0 || y == 0) return 0;
            z = x * y;
        if (z / x!= y) revert MulOverflow(x, y);
            z /= WAD;
    }

    /**
     * @notice Divides two WAD-precision numbers.
     * @return z The result of x / y, maintaining WAD precision.
     */
    function divWad(uint256 x, uint256 y) internal pure returns (uint256 z) {
        if (y == 0) revert DivByZero();
        z = x * WAD;
        if (z / x!= WAD) revert MulOverflow(x, WAD);
        z /= y;
    }

    /**
     * @notice Calculates the square root of a WAD-precision number.
     * @dev Uses the Babylonian method for integer square root.
     * @return z The square root of x, maintaining WAD precision.
     */
    function sqrt(uint256 x) internal pure returns (uint256 z) {
        if (x == 0) return 0;
        // Scale up to maintain precision after square root
        uint256 x_scaled = x * WAD;
        z = x_scaled;
        uint256 y = (z + x_scaled / z) / 2;
        while (y < z) {
            z = y;
            y = (z + x_scaled / z) / 2;
        }
    }
}
