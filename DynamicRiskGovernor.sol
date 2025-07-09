// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "./interfaces/IAlphaModule.sol";
import "./interfaces/IPriceOracle.sol";
import "./libraries/DataStructures.sol";
import "./libraries/FixedPointMath.sol";
import "./libraries/Math.sol";

/**
 * @title DynamicRiskGovernor (DRG)
 * @author Aura Protocol
 * @notice This contract is the core risk and allocation engine for the Aura protocol.
 * It dynamically adjusts capital allocations for various Alpha Modules based on their
 * performance (Sharpe-like ratio, Max Drawdown) and real-time market conditions
 * (volatility, trend) to maximize risk-adjusted returns for the vault.
 * It is designed with modularity, gas efficiency, and robust security features like
 * oracle circuit breakers and mandatory governance timelocks.
 * @dev See the Aura Protocol Technical Specification for detailed formulas and logic.
 */
contract DynamicRiskGovernor {
    // "attaches" all the functions inside FixedPointMath library to uint256 data type
    using FixedPointMath for uint256;

    // --- Events ---

    event ModuleRegistered(address indexed module, bytes32 indexed templateHash, DataStructures.ModuleConfig config);
    event AllocationCalculated(address indexed module, uint256 desiredCollateral, uint256 unconstrainedAllocation);
    event MarketRegimeChanged(uint32 indexed assetId, DataStructures.MarketRegime oldRegime, DataStructures.MarketRegime newRegime);
    event KPIsUpdated(address indexed module, uint256 newNavPerShare, uint256 sharpeProxy, uint256 newMaxDrawdown);
    event CircuitBreakerTripped(bool isTripped);
    // For parameters that apply to the entire protocol
    event ParameterUpdated(string indexed paramName, uint256 newValue);
    // For parameters that apply only to a specific Alpha Module under a specific market condition
    event ParameterUpdated(string indexed paramName, address indexed module, uint8 regime, uint256 newValue);
    event TimelockSet(bytes4 indexed funcSignature, uint256 executionTime);
    event ApprovedTemplateAdded(bytes32 indexed templateHash);
    event ApprovedTemplateRemoved(bytes32 indexed templateHash);
    event OracleAdded(uint32 indexed assetId, IPriceOracle indexed oracle);

    // --- Errors ---

    error NotGovernor();
    error NotSecurityCouncil();
    error TimelockActive(uint256 executionTime);
    error ModuleNotRegistered();
    error WarmupPhaseActive(uint256 timeRemaining);
    error CircuitBreakerTripped();
    error NoOraclesForAsset();
    error OracleDivergence(IPriceOracle oracle, uint256 price, uint256 medianPrice);
    error InvalidTemplate();
    error InsufficientData();
    error ZeroAddress();

    // --- State Variables ---

    // Governance & Security
    // Owner and controller of the protocol's configuration, administrative tasks
    address public immutable governor;
    // For emergency operation. Authority to unfreeze the system after circuit breaker activation
    address public immutable securityCouncil;
    mapping(bytes32 => bool) public approvedTemplateHashes;
    // Time-delay system by mapping a specific function (bytes4 signature) to a future timestamp (Current timestamp + duration)
    mapping(bytes4 => uint256) public timelockEnd;

    // Protocol State & Oracles
    bool public isCircuitBreakerTripped;
    // Marks when the contract has been deployed for the warmUpPeriod
    uint256 public immutable protocolLaunchTimestamp;
    // Map token internal ID to a list of oracle contract addresses price feed for the token
    // Example: Hype (ID 1) with Hyperliquid Oracle and Chainlink Oracle Hype price feeds contract addresses
    mapping(uint32 => IPriceOracle[]) public assetOracles;
    mapping(uint32 => uint256) public lastSeenPrice;
    // EWMA database to measure the recent volatility
    mapping(uint32 => uint256) public ewmaVariance;
    // Current market regime for an asset (LOW_VOL, HIGH_VOL_FAVORABLE, HIGH_VOL_UNFAVORABLE or NORMAL)
    mapping(uint32 => DataStructures.MarketRegime) public assetMarketRegime;

    // Module-specific State
    // Module static conf
    mapping(address => DataStructures.ModuleConfig) public moduleConfigs;
    // Modules real-time risk and performance data
    mapping(address => DataStructures.ModuleRiskState) public moduleRiskStates;
    mapping(address => DataStructures.ModuleSnapshotHistory) public moduleSnapshotHistories;
    // Fine-tune how a module should behave in different market regimes (module address => (regime ID => modifier value))
    mapping(address => mapping(uint8 => uint256)) public marketRegimeModifiers;
    // Define unique multi-point curve for every single module
    mapping(address => Point[]) public sharpeFactorCurves;

    // --- Governable Parameters ---
    // Modifiable by the governor
    uint256 public riskFreeRate; // Theoretical rate of return of a zero-risk investment
    uint256 public oracleDivergenceThreshold; //
    uint256 public warmUpPeriod; // in seconds
    DataStructures.SharpeMetricType public sharpeMetricType; // MAD used (downside or full)
    // Prevent division-by-zero or artificially inflated Sharpe ratios when a module has extremely low volatility
    uint256 public minMadThreshold;
    uint256 public mddLiquidationThreshold; // Critical safety limit for PerfModifier to become 0 and halt allocation
    uint256 public volatilityDecayFactor; // Control weight given to recent price data in EWMA calculation
    // Used to classify market's current volatility into regimes
    uint256 public lowVolThreshold;
    uint256 public highVolThreshold;
    uint8 public trendLookback; // Number of periods for Simple Moving Average (SMA) trend
    uint8 public regimeConfirmationPeriod; // number of blocks to confirm a regime change
    uint256 public maxSharpeFactorSlope; // Governable slope limit

    // --- Modifiers ---
    modifier onlyGovernor() {
        if (msg.sender != governor) revert NotGovernor();
        _;
    }

    modifier onlySecurityCouncil() {
        if (msg.sender != securityCouncil) revert NotSecurityCouncil();
        _;
    }
    // Security measure to disallow governor to perform actions on the go
    modifier withTimelock() {
        if (block.timestamp < timelockEnd[msg.sig]) revert TimelockActive(timelockEnd[msg.sig]);
        _;
        timelockEnd[msg.sig] = 0; // Reset after execution
    }

    // --- Constructor ---
    constructor(address _governor, address _securityCouncil, uint256 _warmUpPeriod) {
        // Assigned to valid ethereum addresses
        if (_governor == address(0) || _securityCouncil == address(0)) revert ZeroAddress();
        governor = _governor;
        securityCouncil = _securityCouncil;
        warmUpPeriod = _warmUpPeriod;
        protocolLaunchTimestamp = block.timestamp;
    }

    // --- Main External Functions ---

    /**
     * @notice Registers a new Alpha Module, linking it to an approved template and setting initial config.
     * @param module The address of the Alpha Module contract.
     * @param config The configuration for this specific module.
     */
    function registerModule(address module, DataStructures.ModuleConfig calldata config) external onlyGovernor {
        bytes32 deployedBytecodeHash = keccak256(module.code);
        // Check if the code of the module address contract is approved through hashes before registration
        if (!approvedTemplateHashes[deployedBytecodeHash]) revert InvalidTemplate();

        moduleConfigs[module] = config;
        // Initialize circular buffer module's perf history with governable size N
        moduleSnapshotHistories[module].navPerShareHistory.length = config.lookbackPeriodN;
        moduleSnapshotHistories[module].timestampHistory.length = config.lookbackPeriodN;

        emit ModuleRegistered(module, deployedBytecodeHash, config);
    }

    /**
     * @notice The core state-changing function called during rebalancing.
     * @dev It updates all KPIs and market data, then calculates the new desired collateral for a module.
     * @param module The address of the Alpha Module to rebalance.
     * @param totalVaultAssets The total assets in the main vault, used for base allocation.
     * @param tradingPnl The module's pure trading profit/loss since the last rebalance.
     * @return desiredCollateral The new target collateral allocation for the module.
     */

    function calculateNewAllocation(
        address module,
        uint256 totalVaultAssets,
        int256 netCapitalFlow,
        int256 tradingPnl
    ) external returns (uint256 desiredCollateral) {
        // --- Pre-computation Checks ---
        if (!moduleConfigs[module].isRegistered) revert ModuleNotRegistered(); // only for registered modules
        if (block.timestamp < protocolLaunchTimestamp + warmUpPeriod) { // Check if not in warmup mode
            revert WarmupPhaseActive(protocolLaunchTimestamp + warmUpPeriod - block.timestamp);
        }
        if (isCircuitBreakerTripped) revert CircuitBreakerTripped(); // Circuit Breaker not activated

        // --- Ingest & Update Market Data ---
        (uint256 medianPrice, bool oracleTripped) = _getMedianPrice(module);
        // Activate security circuitbreaker if there is an oracle divergeance
        if (oracleTripped) {
            isCircuitBreakerTripped = true;
            emit CircuitBreakerTripped(true);
            revert CircuitBreakerTripped();
        }
        _updateMarketRegime(module, medianPrice);
        DataStructures.MarketRegime regime = assetMarketRegime[moduleConfigs[module].assetId];

        // --- Update Module KPIs ---
        (uint256 sharpeProxy, uint256 mdd) = _updateAndGetKPIs(module, netCapitalFlow, tradingPnl);

        // --- Synthesize into Modifiers ---
        uint256 perfModifier = _calculatePerformanceModifier(sharpeProxy, mdd);
        uint256 marketModifier = marketRegimeModifiers[module][uint8(regime)];
        if (marketModifier == 0) marketModifier = FixedPointMath.WAD; // Default to neutral if not set

        // --- Calculate Final Allocation ---
        uint256 baseAllocation = (totalVaultAssets * moduleConfigs[module].capitalWeight) / FixedPointMath.WAD;
        uint256 unconstrainedAllocation = baseAllocation.mulWad(perfModifier).mulWad(marketModifier);

        // --- Enforce Constraints ---
        uint256 notionalExposure = IAlphaModule(module).getNotionalExposure();
        uint256 maxAllowedCollateral = notionalExposure.divWad(moduleConfigs[module].maxLeverage);
        
        desiredCollateral = Math.min(unconstrainedAllocation, maxAllowedCollateral);

        emit AllocationCalculated(module, desiredCollateral, unconstrainedAllocation);
        return desiredCollateral;
    }

    // --- Governance Functions ---

    function setTimelock(bytes4 funcSignature, uint256 duration) external onlyGovernor {
        emit TimelockSet(funcSignature, block.timestamp + duration);
        timelockEnd[funcSignature] = block.timestamp + duration;
    }
    
    function addApprovedTemplate(bytes32 templateHash) external onlyGovernor {
        approvedTemplateHashes[templateHash] = true;
        emit ApprovedTemplateAdded(templateHash);
    }

    function removeApprovedTemplate(bytes32 templateHash) external onlyGovernor {
        approvedTemplateHashes[templateHash] = false;
        emit ApprovedTemplateRemoved(templateHash);
    }

    function addOracle(uint32 assetId, IPriceOracle oracle) external onlyGovernor {
        assetOracles[assetId].push(oracle);
        emit OracleAdded(assetId, oracle);
    }

    function resetCircuitBreaker() external onlySecurityCouncil {
        isCircuitBreakerTripped = false;
        emit CircuitBreakerTripped(false);
    }

    function setRiskFreeRate(uint256 _rate) external onlyGovernor withTimelock {
        riskFreeRate = _rate;
        emit ParameterUpdated("riskFreeRate", _rate);
    }

    function setMddLiquidationThreshold(uint256 _threshold) external onlyGovernor withTimelock {
        mddLiquidationThreshold = _threshold;
        emit ParameterUpdated("mddLiquidationThreshold", _threshold);
    }

    function setMarketRegimeModifier(address module, uint8 regime, uint256 _modifierValue) external onlyGovernor {
        marketRegimeModifiers[module][regime] = _modifierValue;
        emit ParameterUpdated("marketRegimeModifier", module, regime, _modifierValue);
    }
    // ... Add setters for all other governable parameters, each with appropriate access control ...
    
    // --- Internal & Private Helper Functions ---

    /**
     * @dev Fetches prices from all registered oracles for an asset, calculates the median,
     * and checks for divergence to trip the circuit breaker.
     */
    function _getMedianPrice(address module) private returns (uint256 medianPrice, bool tripped) {
        uint32 assetId = moduleConfigs[module].assetId;
        IPriceOracle[] storage oracles = assetOracles[assetId]; // Get all approved IPriceOracle contract for the asset
        uint256 oracleCount = oracles.length;
        if (oracleCount == 0) revert NoOraclesForAsset();

        // temporary array to hold prices
        uint256[] memory prices = new uint256[](oracleCount);
        for (uint i = 0; i < oracleCount; i++) {
            prices[i] = oracles[i].latestPrice(); // by default with 8 decimals
        }

        medianPrice = Math.median(prices);

        // Circuit breaker check
        for (uint i = 0; i < oracleCount; i++) {
            uint256 diff = Math.abs(prices[i], medianPrice);
            if (diff.mulWad(FixedPointMath.WAD) / medianPrice > oracleDivergenceThreshold) {
                emit OracleDivergence(oracles[i], prices[i], medianPrice);
                return (medianPrice, true);
            }
        }
        return (medianPrice, false);
    }

    /**
     * @dev Updates the market regime based on volatility and trend.
     * @notice Implements EWMA for volatility and a simple trend indicator.
     */
    function _updateMarketRegime(address module, uint256 price) private {
        uint32 assetId = moduleConfigs[module].assetId;
        uint256 lastPrice = lastSeenPrice[assetId];
        if (lastPrice == 0) { // First time seeing this asset
            lastSeenPrice[assetId] = price;
            return; // Not enough data yet
        }

        // Calculate Volatility (EWMA of squared returns)
        // New Volatility = square root of (New Variance)
        // New Variance = (Old Variance x Decay Factor) + (Recent Squared Return x (1 - Decay Factor))

        // Calculate Price Change. WAD Multiplication to avoid division loose of information between unscaled numbers
        uint256 returnsSq = (Math.absDiff(price, lastPrice)).mulWad(FixedPointMath.WAD);
        // Calculate % return
        returnsSq = returnsSq.divWad(lastPrice);
        // Squaring % return
        returnsSq = returnsSq.mulWad(returnsSq);

        uint256 currentVariance = ewmaVariance[assetId];

        uint256 newVariance = (currentVariance.mulWad(volatilityDecayFactor)) // volatilityDecayFactor set by governor
            + (returnsSq.mulWad(FixedPointMath.WAD - volatilityDecayFactor));
        ewmaVariance[assetId] = newVariance / FixedPointMath.WAD;
        uint256 volatility = newVariance.sqrt(); // sqrt of the full precision value

        // Calculate Trend (Simple price change)
        int8 trend = _calculateSMATrend(assetId, price);

        // Classify Regime
        DataStructures.MarketRegime newRegime;
        if (volatility < lowVolThreshold) {
            newRegime = DataStructures.MarketRegime.LOW_VOL;
        } else if (volatility >= highVolThreshold) {
            // HIGH_VOL_FAVORABLE: High Volatility + price going up
            // HIGH_VOL_UNFAVORABLE: High Volatility + price going down
            if (trend > 0) newRegime = DataStructures.MarketRegime.HIGH_VOL_FAVORABLE;
            else newRegime = DataStructures.MarketRegime.HIGH_VOL_UNFAVORABLE;
        } else {
            // lowVolThreshold <= volatility < highVolThreshold
            newRegime = DataStructures.MarketRegime.NORMAL;
        }
        
        DataStructures.MarketRegime oldRegime = assetMarketRegime[assetId];
        if(newRegime != oldRegime) {
            emit MarketRegimeChanged(assetId, oldRegime, newRegime);
            assetMarketRegime[assetId] = newRegime;
        }
        
        lastSeenPrice[assetId] = price;
    }

    /**
    * @dev Updates and calculates module KPIs: Stateful MDD and Sharpe Proxy.
    * @param module The module address.
    * @param netCapitalFlow The net capital deposit or withdrawal.
    * @param tradingPnl The pure performance profit or loss.
    */
    function _updateAndGetKPIs(
        address module,
        int256 netCapitalFlow,
        int256 tradingPnl
    ) private returns (uint256 sharpeProxy, uint256 maxDrawdown) {
        DataStructures.ModuleRiskState storage riskState = moduleRiskStates[module];

        // --- Update navPerShare and Max Drawdown (MDD) (Stateful O(1) update) ---
        // Goal is to keep in memory the peak of performance and the maximal drowdawn that ever happened on a module

        // if totalShares = 0 oldNavPerShare = 0 else oldNavPerShare = totalNAV / totalShares
        
        if (netCapitalFlow != 0 && riskState.totalNAV > 0) {
            if (netCapitalFlow > 0) { // Deposit
                uint256 sharesToMint = uint256(netCapitalFlow).mulWad(riskState.totalShares) / riskState.totalNAV;
                riskState.totalNAV += uint256(netCapitalFlow);
                riskState.totalShares += sharesToMint;
            } else { // Withdrawal
                uint256 capitalToWithdraw = uint256(-netCapitalFlow);
                uint256 sharesToBurn = capitalToWithdraw.mulWad(riskState.totalShares) / riskState.totalNAV;
                riskState.totalNAV -= capitalToWithdraw;
                riskState.totalShares -= sharesToBurn;
            }
        }

        // Adding tradingPnl to  module's Net Asset Value
        riskState.totalNAV = uint256(int256(riskState.totalNAV) + tradingPnl);
        
        // check if initialization 
        uint256 newNavPerShare;
        if (riskState.totalShares > 0) {
            newNavPerShare = riskState.totalNAV.divWad(riskState.totalShares);

            // Update MDD
            uint256 peak = riskState.peakNavPerShare;
            if (newNavPerShare > peak) {
                riskState.peakNavPerShare = newNavPerShare;
            } else {
                uint256 currentDrawdown = (peak - newNavPerShare).mulWad(FixedPointMath.WAD) / peak;
                if (currentDrawdown > riskState.maxDrawdown) {
                    riskState.maxDrawdown = currentDrawdown;
                }
            }
        } else { // First-time initialization
            newNavPerShare = FixedPointMath.WAD;
            riskState.totalNAV = uint256(int256(riskState.totalNAV) + netCapitalFlow); // Initial deposit
            riskState.totalShares = riskState.totalNAV; // 1 share per unit of initial capital
            riskState.peakNavPerShare = FixedPointMath.WAD;
        }

        // --- Update Snapshot History (Circular Buffer) ---
        DataStructures.ModuleSnapshotHistory storage history = moduleSnapshotHistories[module];
        uint8 index = history.nextSnapshotIndex;
        history.navPerShareHistory[index] = newNavPerShare;
        history.timestampHistory[index] = uint64(block.timestamp);
        history.nextSnapshotIndex = (index + 1) % uint8(history.navPerShareHistory.length);
        if (history.snapshotCount < history.navPerShareHistory.length) {
            history.snapshotCount++; // Increment number of values in history
        }
        
        // --- Calculate Sharpe Proxy ---
        sharpeProxy = _calculateSharpeProxy(module);
        maxDrawdown = riskState.maxDrawdown;

        emit KPIsUpdated(module, newNavPerShare, sharpeProxy, maxDrawdown);
    }
    
    /**
     * @dev Calculates the Sharpe Proxy using the Mean Absolute Deviation method.
     */
    function _calculateSharpeProxy(address module) private view returns (uint256) {
        DataStructures.ModuleSnapshotHistory storage history = moduleSnapshotHistories[module];
        uint8 count = history.snapshotCount;
        if (count < 2) return FixedPointMath.WAD; // Not enough data, return neutral

        uint8 lookbackN = moduleConfigs[module].lookbackPeriodN;

        // Calculate how many return periods we can analyze from the snapshots
        uint8 returnCount = count - 1;

        // Create a temporary array in memory to hold the returns for the second pass
        int256[] memory periodReturns = new int256[](returnCount);
        int256 totalReturns = 0;

        // --- First Pass: Calculate and store each period's return ---
        for (uint8 i = 0; i < returnCount; i++) {
            // Ready data backwards from most recent entries
            uint8 currentIdx = (history.nextSnapshotIndex + lookbackN - 1 - i) % lookbackN;
            uint8 prevIdx = (history.nextSnapshotIndex + lookbackN - 2 - i) % lookbackN;

            uint256 currentNav = history.navPerShareHistory[currentIdx];
            uint256 prevNav = history.navPerShareHistory[prevIdx];
            
            // Exception when prevNav=0, we skip this invalid period
            if (prevNav > 0) {
                int256 r = int256(currentNav) - int256(prevNav);
                // Calculate the percentage return for this period
                int256 periodReturn = r.mulWad(int256(FixedPointMath.WAD)) / int256(prevNav);
                periodReturns[i] = periodReturn;
                totalReturns += periodReturn;
            }
        }

        // --- Calculations between passes ---
        int256 avgReturn = totalReturns / int256(returnCount);
        int256 excessReturn = avgReturn - int256(riskFreeRate);

        // --- Second Pass: Calculate Mean Absolute Deviation (MAD) ---
        int256 totalDeviation = 0;
        for (uint8 i = 0; i < returnCount; i++) {
            if (sharpeMetricType == DataStructures.SharpeMetricType.DOWNSIDE_MAD) {
                // Only consider returns less than the average for downside deviation
                if (periodReturns[i] < avgReturn) {
                    totalDeviation += Math.absDiff(avgReturn, periodReturns[i]);
                }
            } else { // Full MAD
                totalDeviation += Math.absDiff(avgReturn, periodReturns[i]);
            }
        }

        int256 mad = totalDeviation / int256(returnCount);

        // --- Final Stability Checks ---
        if (mad == 0) return type(uint256).max; // No deviation, return max value
        
        // Use the minimum threshold if calculated MAD is too low.
        if (uint256(Math.abs(mad)) < minMadThreshold) {
            mad = int256(minMadThreshold);
        }
        
        // Ensure we don't try to divide by a negative number if MAD is somehow negative.
        if (mad <= 0) return 0;

        // Calculate the final ratio: Excess Return / Volatility (MAD).
        return uint256(excessReturn).divWad(uint256(mad));
    }
        
    /**
    * @dev Calculates the final performance modifier based on Sharpe and MDD,
    * using a piecewise linear function for the Sharpe Factor.
    */
    function _calculatePerformanceModifier(
        address module,
        uint256 sharpeProxy,
        uint256 mdd
    ) private view returns (uint256) {
        // MDD Penalty: If MDD exceeds the liquidation threshold, allocation is halted.
        if (mdd >= mddLiquidationThreshold) return 0;

        // Linear penalty for MDD.
        uint256 mddPenaltyFactor = mdd.mulWad(FixedPointMath.WAD).divWad(mddLiquidationThreshold);

        // --- Sharpe Factor Calculation using Piecewise Linear Interpolation ---
        Point[] storage curve = sharpeFactorCurves[module];
        uint256 sharpeFactor = FixedPointMath.WAD; // Default to neutral

        if (curve.length >= 2) {
            int256 sharpeProxySigned = int256(sharpeProxy);

            // Find the segment where the sharpeProxy falls
            for (uint i = 0; i < curve.length - 1; i++) {
                Point memory p1 = curve[i];
                Point memory p2 = curve[i+1];

                if (sharpeProxySigned >= p1.x && sharpeProxySigned <= p2.x) {
                    // Perform linear interpolation: y = y1 + (x - x1) * (y2 - y1) / (x2 - x1)
                    int256 x_range = p2.x - p1.x;
                    if (x_range == 0) { // Avoid division by zero, use the lower point's factor
                        sharpeFactor = p1.y;
                        break;
                    }
                    int256 y_range = int256(p2.y) - int256(p1.y);
                    int256 x_delta = sharpeProxySigned - p1.x;

                    int256 interpolated_y_delta = (x_delta * y_range) / x_range;
                    sharpeFactor = uint256(int256(p1.y) + interpolated_y_delta);
                    break;
                }
            }
            // Handle out-of-bounds cases (use the first or last point's factor)
            if (sharpeProxySigned < curve[0].x) sharpeFactor = curve[0].y;
            if (sharpeProxySigned > curve[curve.length - 1].x) sharpeFactor = curve[curve.length - 1].y;
        }
        // Final modifier calculation
        return sharpeFactor.mulWad(FixedPointMath.WAD - mddPenaltyFactor);
    }


    /**
    * @dev Calculates the short-term market trend using a Simple Moving Average (SMA).
    * @param assetId The ID of the asset to analyze.
    * @param newPrice The latest price from the oracle.
    * @return trend -1 for negative, 1 for positive, 0 for neutral.
    */
    function _calculateSMATrend(uint32 assetId, uint256 newPrice) private returns (int8 trend) {
        DataStructures.PriceHistory storage history = assetPriceHistories[assetId];
        uint8 lookback = trendLookback; // Governable parameter

        // Initialize buffer if it's empty
        if (history.prices.length != lookback) {
            delete history.prices; // Clear any old data
            for (uint i = 0; i < lookback; i++) {
                history.prices.push(0);
            }
        }

        // Update the circular buffer with the new price
        history.prices[history.nextWriteIndex] = newPrice;
        history.nextWriteIndex = (history.nextWriteIndex + 1) % lookback;

        // Calculate the SMA
        uint256 sum = 0;
        uint8 points = 0;
        for (uint8 i = 0; i < lookback; i++) {
            if (history.prices[i] > 0) {
                sum += history.prices[i];
                points++;
            }
        }

        // Not enough data for a meaningful SMA yet
        if (points < lookback) return 0;

        uint256 sma = sum / lookback;

        // Determine trend
        if (newPrice > sma) {
            return 1; // Positive trend
        } else if (newPrice < sma) {
            return -1; // Negative trend
        } else {
            return 0; // Neutral trend
        }
    }
}