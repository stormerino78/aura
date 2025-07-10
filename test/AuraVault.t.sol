// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {AuraVault} from "../AuraVault.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {IL1Read} from "../interfaces/IL1Read.sol";

contract AuraVaultTest is Test {
    // Contracts
    AuraVault internal vault;
    MockERC20 internal usdc;

    // Users & System Addresses
    address internal owner = address(0x1000);
    address internal drg = address(0x2000);
    address internal dcsm = address(0x3000);
    address internal user = address(0x4000);
    address internal module = address(0x5000);
    address internal otherAddress = address(0x6000);

    // Constants
    uint256 internal constant WAD = 1e18;

    /// @notice This function handles the automatic deployment and configuration before each test.
    function setUp() public {
        // --- Deploy Contracts ---
        usdc = new MockERC20("USD Coin", "USDC");
        
        // Owner is used to perform the test
        vm.startPrank(owner);
        // Initialisation of a new AuraVault
        vault = new AuraVault(
            usdc,
            "Aura Vault",
            "aVLT",
            drg,
            dcsm,
            owner
        );
        // Whitelist the module for capital transfers
        vault.setModuleWhitelist(module, true);
        vm.stopPrank();

        // --- Fund User ---
        // Give the user 10,000 USDC to test deposits
        usdc.mint(user, 10_000 * 1e6); // Assuming USDC has 6 decimals
    }

    // --- Test Core ERC4626 Functionality ---

    function test_Deposit() public {
        uint256 depositAmount = 1000 * 1e6; // 1,000 USDC

        // User must first approve the vault to spend their USDC
        vm.startPrank(user);
        usdc.approve(address(vault), depositAmount);

        // User deposits assets and receives shares
        uint256 shares = vault.deposit(depositAmount, user);
        vm.stopPrank();
        
        // Check that shares were minted to the user
        assertEq(shares, depositAmount * 1e12, "Initial shares should be 1:1 with assets, adjusted for decimals");
        assertEq(vault.balanceOf(user), shares);
        
        // Check that the vault now holds the user's USDC
        assertEq(usdc.balanceOf(address(vault)), depositAmount);
        assertEq(vault.totalAssets(), depositAmount);
    }

    // --- Test Access Control ---

    function test_Fail_SetDrgAddress_NotOwner() public {
        vm.prank(otherAddress); // A random address tries to call
        vm.expectRevert("Ownable: caller is not the owner");
        vault.setDrgAddress(otherAddress);
    }

    function test_Fail_InternalCapitalTransfer_NotSystem() public {
        vm.prank(otherAddress); // A random address tries to call
        vm.expectRevert(AuraVault.NotSystemAddress.selector);
        vault.internalCapitalTransfer(100, module);
    }

    // --- Test Custom Logic & Mocks ---

    function test_InternalCapitalTransfer() public {
        uint256 transferAmount = 500 * 1e6;
        // First, deposit some capital into the vault to be transferred
        vm.prank(user);
        usdc.approve(address(vault), transferAmount);
        vault.deposit(transferAmount, user);
        vm.stopPrank();

        // The DRG or DCSM calls the function to route capital
        vm.prank(drg);
        vault.internalCapitalTransfer(transferAmount, module);

        // Check that the capital was successfully moved to the module
        assertEq(usdc.balanceOf(module), transferAmount);
        assertEq(usdc.balanceOf(address(vault)), 0);
    }

    /// @dev This test demonstrates how to mock Hyperliquid's precompile calls.
    function test_AllocatedCapital_MockL1Read() public {
        uint256 mockModuleBalance = 5000 * WAD; // Mock balance with 18 decimals

        // Prepare the mock return data
        bytes memory returnData = abi.encode("mock_user_state", mockModuleBalance);

        // Tell the VM to return our mock data whenever L1_READ.userState(module) is called
        vm.mockCall(
            address(vault.L1_READ()),
            abi.encodeWithSelector(IL1Read.userState.selector, module),
            returnData
        );

        // Call the function and assert it returns our mocked value
        uint256 allocated = vault.allocatedCapital(module);
        assertEq(allocated, mockModuleBalance);
    }
}