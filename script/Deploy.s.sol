// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";

import {Parameters}   from "../src/Parameters.sol";
import {Lending} from "../src/core/Lending.sol";
import {sDYAD} from "../src/core/sDYAD.sol";

import {IDyad} from "../src/interfaces/IDyad.sol";
import {IAggregatorV3} from "../src/interfaces/IAggregatorV3.sol";
import {IWETH} from "../src/interfaces/IWETH.sol";
import {ITokenRenderer} from "../src/interfaces/ITokenRenderer.sol";

contract Deploy is Script, Parameters {
  function run() public {
    vm.startBroadcast();  // ----------------------

    sDYAD sDyad = new sDYAD();

    Lending lending = new Lending(
      IDyad(MAINNET_V2_DYAD), 
      sDyad, 
      IWETH(MAINNET_WETH), 
      IAggregatorV3(MAINNET_WETH_ORACLE), 
      ITokenRenderer(address(0)) // TODO: set renderer
    );

    vm.stopBroadcast();  // ----------------------------
  }
}


