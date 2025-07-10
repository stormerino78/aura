// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {DynamicRiskGovernor} from "../DynamicRiskGovernor.sol";
import {AuraVault} from "../AuraVault.sol";
import {DataStructures} from "../libraries/DataStructures.sol";
import {MockPriceOracle} from "./mocks/MockPriceOracle.sol";
import {MockAlphaModule} from "./mocks/MockAlphaModule.sol";
import {IPriceOracle} from "../interfaces/IPriceOracle.sol";

contract DRGTest is Test {
    // Contracts
    DynamicRiskGovernor internal drg;
    AuraVault internal vault;
    MockAlphaModule internal module1;
    MockPriceOracle internal oracle1;
    MockPriceOracle internal oracle2;

    // Users
    address internal governor = address(0x1000);
    address internal securityCouncil = address(0x2000);
    address internal user = address(0x3000);
    
    // Constants
    uint256 internal constant WAD = 1e18;
    uint32 internal constant ASSET_ID = 1;

    function setUp() public {
        // --- Deploy Contracts ---
        drg = new DynamicRiskGovernor(governor, securityCouncil, 1 days);
        // We'll use a mock ERC20 for the vault asset for simplicity
        // For a real ERC4626 test, you'd deploy a full mock token.
        vault = new AuraVault(
            IERC20(address(0)), // Mock asset
            "Aura Vault",
            "aVLT",
            address(drg),
            address(this), // This test contract acts as the DCSM
            governor
        );
        module1 = new MockAlphaModule();
        oracle1 = new MockPriceOracle();
        oracle2 = new MockPriceOracle();
        
        // --- Initial Configuration ---
        vm.startPrank(governor);
        
        // 1. Add approved template hash for our mock module
        bytes32 templateHash = keccak256(address(module1).code);
        drg.addApprovedTemplate(templateHash);

        // 2. Add oracles for our asset
        oracle1.setPrice(1000 * 1e8); // Assuming 8 decimals from oracle
        oracle2.setPrice(1000 * 1e8);
        drg.addOracle(ASSET_ID, IPriceOracle(address(oracle1)));
        drg.addOracle(ASSET_ID, IPriceOracle(address(oracle2)));

        // 3. Register the Alpha Module
        DataStructures.ModuleConfig memory config = DataStructures.ModuleConfig({
            isRegistered: true,
            capitalWeight: 0.5 * WAD, // 50% target weight
            maxLeverage: 10 * WAD, // 10x max leverage
            assetId: ASSET_ID,
            lookbackPeriodN: 30
        });
        drg.registerModule(address(module1), config);
        
        // 4. Set initial risk parameters
        drg.setOracleDivergenceThreshold(0.05 * WAD); // 5%
        //... set other params as needed for tests

        vm.stopPrank();
    }

    /// @dev Tests that a module with a valid template can be registered successfully.
    function test_RegisterModule_Success() public {
        // The module is already registered in setUp(), so we just check the state.
        DataStructures.ModuleConfig memory config = drg.moduleConfigs(address(module1));
        
        assertTrue(config.isRegistered);
        assertEq(config.capitalWeight, 0.5 * WAD);
        assertEq(config.assetId, ASSET_ID);
    }

    /// @dev Tests that registration reverts if the module's template is not approved.
    function test_Fail_RegisterModule_InvalidTemplate() public {
        // Deploy a new, unapproved module
        MockAlphaModule newModule = new MockAlphaModule();
        
        DataStructures.ModuleConfig memory config = DataStructures.ModuleConfig({
            isRegistered: true,
            capitalWeight: 0.5 * WAD,
            maxLeverage: 10 * WAD,
            assetId: ASSET_ID,
            lookbackPeriodN: 30
        });
        
        vm.startPrank(governor);
        // Expect a revert with the custom error "InvalidTemplate"
        vm.expectRevert(DynamicRiskGovernor.InvalidTemplate.selector);
        drg.registerModule(address(newModule), config);
        vm.stopPrank();
    }
}