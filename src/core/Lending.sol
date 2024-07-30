// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {sDYAD}         from "./sDYAD.sol";
import {IDyad}         from "../interfaces/IDyad.sol";
import {IVault}        from "../interfaces/IVault.sol";
import {IAggregatorV3} from "../interfaces/IAggregatorV3.sol";

import {FixedPointMathLib} from "@solmate-6.7.0/src/utils/FixedPointMathLib.sol";
import {SafeCast}          from "@openzeppelin-contracts-5.0.2/utils/math/SafeCast.sol";


contract Lending {
  using FixedPointMathLib for uint;
  using SafeCast          for int;

  error StaleData();

  uint          public constant  K = 0.1e18;
  uint          public constant  STALE_DATA_TIMEOUT = 90 minutes; 
  IAggregatorV3 public immutable oracle;

  IDyad public dyad;
  sDYAD public sDyad;
  uint  public totalDyadBorrowed;
  uint  public dyadInVault;
  uint  public totalCollatValue;

  struct Loan {
    uint collat;
    uint debt;
    uint interest;
    uint lastPaymentTime;
  }

  mapping(address => Loan) public loans;

  constructor(
    IDyad         _dyad,
    sDYAD         _sDyad,
    IAggregatorV3 _oracle
  ) {
    dyad   = _dyad;
    sDyad  = _sDyad;
    oracle = _oracle;
  }

  function interest(uint dyadAmount) 
    public 
    view 
    returns (uint) 
  {
    uint newTotalDyadBorrowed = totalDyadBorrowed + dyadAmount;

    // totalDyadDeployed^2
    uint totalDyadBorrowdSquared = newTotalDyadBorrowed.mulWadDown(newTotalDyadBorrowed);

    // (totalDyadDeployed^2) / dyadInVault
    uint ratio = totalDyadBorrowdSquared.divWadDown(dyadInVault);

    // k * ratio
    uint result = K.mulWadDown(ratio);

    // final result: (k * (totalDyadDeployed^2)) / (dyadInVault * totalCollatValue)
    return result.divWadDown(totalCollatValue);
  }

    function ethPrice() 
    public 
    view 
    returns (uint) {
      (
        ,
        int256 answer,
        , 
        uint256 updatedAt, 
      ) = oracle.latestRoundData();
      if (block.timestamp > updatedAt + STALE_DATA_TIMEOUT) revert StaleData();
      return answer.toUint256();
  }
}
