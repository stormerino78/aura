// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/**
 * @title Math
 * @author Aura Protocol
 * @notice Provides common, gas-efficient mathematical functions.
 * Includes functions for finding the minimum, absolute difference, median of an array,
 * and integer square root.
 */
library Math {
    /**
     * @dev Returns the smaller of two numbers.
     */
    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    /**
     * @dev Returns the absolute difference between two unsigned integers.
     */
    function absDiff(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : b - a;
    }

    /**
     * @dev Returns the absolute value of a signed integer.
     */
    function abs(int256 a) internal pure returns (int256) {
        return a >= 0 ? a : -a;
    }

    /**
     * @dev Calculates the median of an array of unsigned integers.
     * @notice For gas efficiency on small arrays (like oracle prices), this uses a simple
     * insertion sort on a memory copy of the array. Reverts if the array is empty.
     * @param _arr The array of numbers.
     * @return The median value. If the array has an even number of elements, it's the
     * average of the two middle elements.
     */
    function median(uint256[] memory _arr) internal pure returns (uint256) {
        uint256 n = _arr.length;
        require(n > 0, "Math: empty array");

        // Create a copy to sort in-place without modifying the original array
        uint256[] memory sortedArr = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            sortedArr[i] = _arr[i];
        }

        // Insertion sort - efficient for small n
        for (uint256 i = 1; i < n; i++) {
            uint256 key = sortedArr[i];
            int256 j = int256(i - 1);
            while (j >= 0 && sortedArr[uint256(j)] > key) {
                sortedArr[uint256(j + 1)] = sortedArr[uint256(j)];
                j--;
            }
            sortedArr[uint256(j + 1)] = key;
        }

        // Return the median from the sorted array
        if (n % 2 != 0) {
            // Odd number of elements
            return sortedArr[n / 2];
        } else {
            // Even number of elements, return average of the two middle elements
            return (sortedArr[n / 2 - 1] + sortedArr[n / 2]) / 2;
        }
    }

    /**
     * @dev Calculates the integer square root of a number.
     * @notice Uses a gas-efficient binary search algorithm.
     * @param x The number to calculate the square root of.
     * return The integer square root of x.
     */
    function sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        // Starting with x / 2 is a good initial guess
        y = x;
        uint256 z = (x / 2) + 1;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }
}