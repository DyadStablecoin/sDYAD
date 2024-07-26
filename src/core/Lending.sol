// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IDyad}  from "../interfaces/IDyad.sol";
import {IVault} from "../interfaces/IVault.sol";

import {FixedPointMathLib} from "@solmate-6.7.0/src/utils/FixedPointMathLib.sol";

contract Lending {
  using FixedPointMathLib for uint;

  uint public constant k = 0.1e18;

  IDyad  public dyad;
  IVault public ethVault;

  uint  public totalDyadLent;
  uint  public totalDyadBorrowed;

  constructor(
    IDyad  _dyad,
    IVault _ethVault
  ) {
    dyad     = _dyad;
    ethVault = _ethVault;
  }

  function getInterestRate(uint id) 
    public 
    view 
    returns (uint) 
  {
    uint eth = ethVault.id2asset(id).mulWadDown(ethVault.assetPrice());
    uint a   = eth.mulWadDown(dyad.balanceOf(address(ethVault)));
    uint b   = (totalDyadBorrowed**2).mulWadDown(a);
    return k.mulWadDown(b);
  }
}
