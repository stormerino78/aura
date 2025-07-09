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
        (uint256 sharpeProxy, uint256 mdd) = _updateAndGetKPIs(module, tradingPnl);

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
        // A more complex SMA implementation is possible but this is gas efficient
        int256 trend = int256(price) - int256(lastPrice);

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
     */
    function _updateAndGetKPIs(address module, int256 tradingPnl) private returns (uint256 sharpeProxy, uint256 maxDrawdown) {
        DataStructures.ModuleRiskState storage riskState = moduleRiskStates[module];

        // --- Update navPerShare and Max Drawdown (MDD) (Stateful O(1) update) ---
        // Goal is to keep in memory the peak of performance and the maximal drowdawn that ever happened on a module

        // if totalShares = 0 oldNavPerShare = 0 else oldNavPerShare = totalNAV / totalShares
        uint256 oldNavPerShare = riskState.totalShares == 0 ? 0 : riskState.totalNAV.divWad(riskState.totalShares);
        
        // Adding tradingPnl to  module's Net Asset Value
        riskState.totalNAV = uint256(int256(riskState.totalNAV) + tradingPnl);
        
        // check if initialization 
        uint256 newNavPerShare;
        if (riskState.totalShares > 0) {
            newNavPerShare = riskState.totalNAV.divWad(riskState.totalShares);

            // Update MDD
            uint256 peak = riskState.peakNavPerShare;
            if (newNavPerShare > peak) {
                riskState.peakNavPerShare = newNavPerShare; // Profit generated as each share is more valuable
            } else {
                uint256 currentDrawdown = (peak - newNavPerShare).divWad(peak); // current drawdown coef
                if (currentDrawdown > riskState.maxDrawdown) {
                    riskState.maxDrawdown = currentDrawdown;
                }
            }
        } else { // First-time initialization (Values are then again updated when deposits are made)
            newNavPerShare = FixedPointMath.WAD;
            riskState.totalNAV = FixedPointMath.WAD;
            riskState.totalShares = FixedPointMath.WAD;
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
        uint256 count = history.snapshotCount;
        if (count < 2) return FixedPointMath.WAD; // Not enough data, return neutral

        uint256[] memory periodReturns = new uint256[](count - 1);
        int256 totalReturns = 0;

        // Calculate period-over-period returns
        for (uint256 i = 0; i < count - 1; i++) {
            // Ready data backwards from most recent entries
            uint256 currentIdx = (history.nextSnapshotIndex + history.navPerShareHistory.length - 1 - i) % history.navPerShareHistory.length;
            uint256 prevIdx = (history.nextSnapshotIndex + history.navPerShareHistory.length - 2 - i) % history.navPerShareHistory.length;
            uint256 currentNav = history.navPerShareHistory[currentIdx];
            uint256 prevNav = history.navPerShareHistory[prevIdx];
            // Exception when prevNav=0 (only one period)
            if (prevNav == 0) continue;
            
            int256 r = int256(currentNav) - int256(prevNav);
            periodReturns[i] = uint256(r); // absolute value of the difference of performance
            totalReturns += r.mulWad(int256(FixedPointMath.WAD)) / int256(prevNav); // coef of return (+/-)
        }

        int256 avgReturn = totalReturns / int256(count - 1);
        int256 excessReturn = avgReturn - int256(riskFreeRate);

        // Calculate Mean Absolute Deviation (MAD)
        int256 mad = 0;
        for(uint256 i = 0; i < periodReturns.length; ++i) {
            if(sharpeMetricType == DataStructures.SharpeMetricType.DOWNSIDE_MAD) {
                // Only consider returns less than the average (downside deviation)
                if (int256(periodReturns[i]) < avgReturn) {
                    mad += Math.abs(avgReturn, int256(periodReturns[i]));
                }
            } else { // Full MAD
                mad += Math.abs(avgReturn, int256(periodReturns[i]));
            }
        }
        mad /= int256(periodReturns.length);
        
        // Handle edge cases and calculate final ratio
        if (mad == 0) return type(uint256).max; // No downside deviation, return max value
        if (uint256(Math.abs(mad, 0)) < minMadThreshold) {
            mad = int256(minMadThreshold);
        }

        return uint256(excessReturn).divWad(uint256(mad));
    }

    /**
     * @dev Calculates the final performance modifier based on Sharpe and MDD.
     */
    function _calculatePerformanceModifier(uint256 sharpeProxy, uint256 mdd) private view returns (uint256) {
        // MDD Penalty: If MDD exceeds the liquidation threshold, allocation is halted.
        if (mdd >= mddLiquidationThreshold) return 0;
        
        // A simple linear penalty for this example (mdd / mdd liquidation price). The spec's piecewise function can be implemented here.
        uint256 mddPenaltyFactor = mdd.mulWad(FixedPointMath.WAD).divWad(mddLiquidationThreshold);

        // Sharpe Factor: A simple bounded factor. The spec's piecewise function would provide smoother scaling.
        uint256 sharpeFactor = FixedPointMath.WAD; // Neutral
        if (sharpeProxy > FixedPointMath.WAD.mulWad(2)) sharpeFactor = FixedPointMath.WAD.mulWad(12) / 10; // 1.2x
        else if (sharpeProxy < FixedPointMath.WAD.divWad(2)) sharpeFactor = FixedPointMath.WAD.mulWad(8) / 10; // 0.8x
        // Add both mdd ratio with sharp proxy to define the allocation/desalloacation
        return sharpeFactor.mulWad(FixedPointMath.WAD - mddPenaltyFactor);
    }
}