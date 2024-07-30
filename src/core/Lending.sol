// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {sDYAD}         from "./sDYAD.sol";
import {IDyad}         from "../interfaces/IDyad.sol";
import {IVault}        from "../interfaces/IVault.sol";
import {IAggregatorV3} from "../interfaces/IAggregatorV3.sol";

import {FixedPointMathLib} from "@solmate-6.7.0/src/utils/FixedPointMathLib.sol";
import {ERC20}             from "@solmate-6.7.0/src/tokens/ERC20.sol";
import {SafeTransferLib}   from "@solmate-6.7.0/src/utils/SafeTransferLib.sol";
import {SafeCast}          from "@openzeppelin-contracts-5.0.2/utils/math/SafeCast.sol";

contract Lending {
  using SafeTransferLib   for ERC20;
  using FixedPointMathLib for uint;
  using SafeCast          for int;

  error StaleData();

  uint          public constant  K                  = 0.1e18;
  uint          public constant  STALE_DATA_TIMEOUT = 90 minutes; 
  uint          public constant  INTEREST_PERIOD    = 1 days;
  IAggregatorV3 public immutable oracle;

  IDyad public dyad;
  sDYAD public sDyad;
  ERC20 public weth;
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
    ERC20         _weth,
    IAggregatorV3 _oracle
  ) {
    dyad   = _dyad;
    sDyad  = _sDyad;
    weth   = _weth;
    oracle = _oracle;
  }

  function lend(uint dyadAmount)
    external 
  {
    dyad.transferFrom(msg.sender, address(this), dyadAmount);
    dyadInVault += dyadAmount;
    sDyad.deposit(dyadAmount, msg.sender);
  }

  function addCollat(uint wethAmount)
    external 
  {
    weth.safeTransferFrom(msg.sender, address(this), wethAmount);
    loans[msg.sender].collat += wethAmount;
  }

  function borrow(uint dyadAmount)
    external 
  {
    uint ethCollat   = loans[msg.sender].collat;
    uint collatValue = ethCollat.mulWadDown(ethPrice());

    require(collatValue >= dyadAmount, "Insufficient collateral");

    uint interestRate = interest(dyadAmount);

    loans[msg.sender].debt            += dyadAmount;
    loans[msg.sender].interest         = interestRate;
    loans[msg.sender].lastPaymentTime  = block.timestamp;

    totalDyadBorrowed += dyadAmount;
    dyadInVault       -= dyadAmount;
    totalCollatValue  += collatValue;

    dyad.transfer(msg.sender, dyadAmount);
  }

  function repayDyad(uint amount)
    external
  {
    Loan storage loan = loans[msg.sender];
    uint interestDue = (loan.debt * loan.interest) 
                        * (block.timestamp - loan.lastPaymentTime) 
                        / INTEREST_PERIOD;
    require(amount >= interestDue);

    uint repaymentAmount = amount - interestDue;
    loan.debt         -= repaymentAmount;
    totalDyadBorrowed -= repaymentAmount;
    dyadInVault       += repaymentAmount;

    dyad.transferFrom(msg.sender, address(this), repaymentAmount);
  }

  function defaultLoan() 
    external
  {
    Loan storage loan = loans[msg.sender];
    require(loan.debt > 0);
    require(block.timestamp > loan.lastPaymentTime + INTEREST_PERIOD);

    dyad.transferFrom(msg.sender, address(this), loan.debt);

    totalCollatValue -= loan.collat;
    loan.collat          = 0;
    loan.debt            = 0;
    loan.interest        = 0;
    loan.lastPaymentTime = 0;

    // sDyad.withdraw(loan.debt, msg.sender);
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
