// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Ownable} from "@solady/auth/Ownable.sol";
import {ERC4626} from "@solady/tokens/ERC4626.sol";
import {UUPSUpgradeable} from "@solady/utils/UUPSUpgradeable.sol";
import {SafeTransferLib} from "@solady/utils/SafeTransferLib.sol";

contract sDYAD is ERC4626, UUPSUpgradeable, Ownable {
    address constant DYAD = 0xFd03723a9A3AbE0562451496a9a394D2C4bad4ab;

    uint8 version;
    address loanManager;

    uint256 public totalBorrowed;

    constructor() {
        version = type(uint8).max;
    }

    function initialize() external {
        if (version > 0) {
            revert AlreadyInitialized();
        }
        _initializeOwner(tx.origin);
    }

    function asset() public pure override returns (address) {
        return DYAD;
    }

    function name() public pure override returns (string memory) {
        return "Staked DYAD";
    }

    function symbol() public pure override returns (string memory) {
        return "sDYAD";
    }

    /// @notice Borrows assets from the vault - only callable by the loan manager
    /// @param amount The amount to borrow
    /// @param to The address to send the borrowed assets to
    function borrow(uint256 amount, address to) external {
        if (msg.sender != loanManager) {
            revert Unauthorized();
        }
        totalBorrowed += amount;
        SafeTransferLib.safeTransfer(DYAD, to, amount);
    }

    /// @notice Reduce the total borrowed amount - only callable by the loan manager
    /// to be called in the event of a liquidation that results in a loss, or a repayment
    /// @param amount The amount to reduce the total borrowed amount by
    function reduceBorrowed(uint256 amount) external {
        if (msg.sender != loanManager) {
            revert Unauthorized();
        }
        totalBorrowed -= amount;
    }

    /// @notice Total amount of assets managed by the vault, including
    /// the total amount currently lent out via bonds.
    function totalAssets() public view override returns (uint256) {
        return super.totalAssets() + totalBorrowed;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
