// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IL1Read} from "./interfaces/IL1Read.sol";

/**
 * @title AuraVault
 * @author Aura Protocol
 * @notice The core ERC-4626 compliant vault for Project Aura. This contract
 * holds all user-deposited capital and routes it based on commands from the
 * DRG and DCSM. Its administrative functions are intended to be owned by a
 * TimelockController governed by a multi-signature wallet.
 */
contract AuraVault is ERC4626, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // --- State Variables ---

    IL1Read constant L1_READ = IL1Read(0x0000000000000000000000000000000000000801);

    address public drgAddress;
    address public dcsmAddress;
    mapping(address => bool) public isWhitelistedModule;

    // --- Custom Errors ---

    error NotSystemAddress();
    error NotWhitelistedModule();
    error ZeroAddress();
    error CannotRescueAsset();

    // --- Events ---

    event CapitalRouted(address indexed destination, uint256 amount);
    event ModuleWhitelisted(address indexed module, bool status);
    event DrgAddressUpdated(address indexed newAddress);
    event DcsmAddressUpdated(address indexed newAddress);

    // --- Modifiers ---

    modifier onlySystem() {
        if (msg.sender != drgAddress && msg.sender != dcsmAddress) {
            revert NotSystemAddress();
        }
        _;
    }

    // --- Constructor ---

    constructor(
        IERC20 _asset,
        string memory _name,
        string memory _symbol,
        address _initialDrgAddress,
        address _initialDcsmAddress,
        address _initialOwner
    ) ERC4626(_asset) ERC20(_name, _symbol) {
        if (_initialDrgAddress == address(0) || _initialDcsmAddress == address(0) || _initialOwner == address(0)) {
            revert ZeroAddress();
        }
        drgAddress = _initialDrgAddress;
        dcsmAddress = _initialDcsmAddress;
        _transferOwnership(_initialOwner);
    }

    // --- Fallback Functions ---
    
    receive() external payable {
        revert("Native token deposits not accepted");
    }

    fallback() external payable {
        revert("Fallback not allowed");
    }

    // --- Core Logic ---

    function internalCapitalTransfer(uint256 amount, address destination) external onlySystem nonReentrant {
        if (!isWhitelistedModule[destination]) {
            revert NotWhitelistedModule();
        }
        IERC20(asset()).safeTransfer(destination, amount);
        emit CapitalRouted(destination, amount);
    }

    function allocatedCapital(address module) external view returns (uint256) {
        try L1_READ.userState(module) returns (string memory moduleInfo, uint256 usdcBalance) {
            return usdcBalance;
        } catch {
            return 0;
        }
    }

    function idleCapital() external view returns (uint256) {
        return IERC20(asset()).balanceOf(address(this));
    }

    // --- Administrative Functions ---

    function setModuleWhitelist(address _module, bool _status) external onlyOwner {
        bool currentStatus = isWhitelistedModule[_module];
        if (currentStatus == _status) return;
        
        isWhitelistedModule[_module] = _status;
        emit ModuleWhitelisted(_module, _status);
    }

    function setDrgAddress(address _newDrgAddress) external onlyOwner {
        if (_newDrgAddress == address(0)) revert ZeroAddress();
        drgAddress = _newDrgAddress;
        emit DrgAddressUpdated(_newDrgAddress);
    }

    function setDcsmAddress(address _newDcsmAddress) external onlyOwner {
        if (_newDcsmAddress == address(0)) revert ZeroAddress();
        dcsmAddress = _newDcsmAddress;
        emit DcsmAddressUpdated(_newDcsmAddress);
    }

    function rescueToken(address token, address to, uint256 amount) external onlyOwner {
        if (token == asset()) revert CannotRescueAsset();
        IERC20(token).safeTransfer(to, amount);
    }
}