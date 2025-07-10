// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/**
 * @title DataStructures
 * @notice A central library that provide essential building blocks, including shared data structures and a safe, fixed-point math library for performing calculations with decimal precision.
 * @dev Consolidating structs and enums here keeps the main contract cleaner and more organized.
 */
library DataStructures {
    
    /**
     * @notice Defines the possible market regimes as classified by the DRG.
     */
    enum MarketRegime {
        NORMAL,
        LOW_VOL,
        HIGH_VOL_FAVORABLE,
        HIGH_VOL_UNFAVORABLE
    }

    /**
     * @notice Defines the type of Mean Absolute Deviation (MAD) to be used for the Sharpe Ratio proxy.
     */
    enum SharpeMetricType {
        DOWNSIDE_MAD, // Sortino-like ratio
        FULL_MAD      // Sharpe-like ratio
    }

    uint8 public constant MAX_TREND_LOOKBACK = 100;
    uint8 public constant MAX_KPI_LOOKBACK = 100;
    /**
     * @notice Configuration for an Alpha Module. These parameters are set by governance.
     * @param isRegistered A flag indicating if the module is active.
     * @param capitalWeight The module's target weight in the total vault allocation (e.g., 0.1 * WAD for 10%).
     * @param maxLeverage The maximum leverage the module is allowed to take (e.g., 10 * WAD for 10x).
     * @param assetId A unique identifier for the primary asset the module trades (e.g., coin index for oracle).
     * @param lookbackPeriodN The number of historical snapshots to use for KPI calculations.
     */
    struct ModuleConfig {
        bool isRegistered;
        uint256 capitalWeight;
        uint256 maxLeverage;
        uint32 assetId;
        uint8 lookbackPeriodN;
    }

    /**
     * @notice Stores the stateful risk metrics for an Alpha Module.
     * @dev This data is updated at every rebalancing event.
     * @param totalNAV The total Net Asset Value of the module, immune to capital flows.
     * @param totalShares The total number of shares issued for the module's NAV.
     * @param peakNavPerShare The highest recorded NAV per share, used for MDD calculation.
     * @param maxDrawdown The largest peak-to-trough decline observed, as a percentage (WAD precision).
     */
    struct ModuleRiskState {
        uint256 totalNAV;
        uint256 totalShares;
        uint256 peakNavPerShare;
        uint256 maxDrawdown;
    }

    /**
     * @notice Stores the historical performance data for a module in a circular buffer.
     * @dev Uses parallel arrays which is more gas-efficient for storage than an array of structs.
     * @param navPerShareHistory A fixed-size array holding the most recent NAV-per-share values.
     * @param timestampHistory A fixed-size array holding the timestamps of each snapshot.
     * @param nextSnapshotIndex A pointer indicating the next array index to be overwritten.
     * @param snapshotCount The number of snapshots currently stored in the buffer, up to N.
     */
    struct ModuleSnapshotHistory {
        uint256[MAX_KPI_LOOKBACK] navPerShareHistory;
        uint64[MAX_KPI_LOOKBACK] timestampHistory;
        uint8 nextSnapshotIndex;
        uint8 snapshotCount;
    }

    /**
     * @notice Stores a rolling history of recent oracle prices in a fixed-size circular buffer.
     * This data is used to calculate the short-term market trend via a Simple Moving Average (SMA).
     * @param prices A fixed-size array holding the most recent oracle price snapshots.
     * @param nextWriteIndex A pointer indicating the next array index to be overwritten, facilitating the circular buffer.
     * @param pointsWritten Track filled slots
     */
    struct PriceHistory {
        uint256[MAX_TREND_LOOKBACK] prices;
        uint8 nextWriteIndex;
        uint8 pointsWritten;
    }

    /**
     * @notice Defines a single coordinate (x, y) for the piecewise linear function
     * mapping a Sharpe Proxy score to a Sharpe Factor.
     * @param x The input value representing the Sharpe Proxy score (can be negative).
     * @param y The output value representing the resulting Sharpe Factor, formatted as a WAD (18 decimals).
     */
    struct Point {
        int256 x;  // SharpeProxy score
        uint256 y; // SharpeFactor (WAD)
    }

    /**
     * @notice Tracks a pending market regime change before it is confirmed.
     * @param regime The potential new market regime.
     * @param confirmationCounter The number of consecutive blocks the new regime condition has been met.
     */
    struct PendingRegimeState {
        MarketRegime regime;
        uint8 confirmationCounter;
    }

}
