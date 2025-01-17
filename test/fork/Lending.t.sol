// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import {Parameters} from "../../src/Parameters.sol";
import {Lending} from "../../src/core/Lending.sol";
import {sDYAD} from "../../src/core/sDYAD.sol";
import {IDyad} from "../../src/interfaces/IDyad.sol";
import {IVault} from "../../src/interfaces/IVault.sol";

contract LendingTest is Test, Parameters {
    Lending public lending;

    // function setUp() public {
    //   sDYAD sDyad = new sDYAD();

    //   lending = new Lending(
    //     IDyad(MAINNET_V2_DYAD),
    //     sDyad,
    //     IVault(MAINNET_V2_WETH_VAULT)
    //   );
    // }

    // function testA() public {
    //   uint interest = lending.interest(0);
    //   console.log("Interest Rate: %d", interest);
    // }
}
