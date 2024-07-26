// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Ownable} from "@solady/auth/Ownable.sol";
import {ERC4626} from "@solady/tokens/ERC4626.sol";
import {UUPSUpgradeable} from "@solady/utils/UUPSUpgradeable.sol";

contract sDYAD is ERC4626, UUPSUpgradeable, Ownable {

    address constant DYAD = 0xFd03723a9A3AbE0562451496a9a394D2C4bad4ab;

    uint8 version;

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

    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyOwner {}
}
