// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {sDYAD} from "./sDYAD.sol";
import {IDyad} from "../interfaces/IDyad.sol";
import {IVault} from "../interfaces/IVault.sol";
import {IAggregatorV3} from "../interfaces/IAggregatorV3.sol";

import {FixedPointMathLib} from "@solady/utils/FixedPointMathLib.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IWETH} from "../interfaces/IWETH.sol";
import {SafeTransferLib} from "@solady/utils/SafeTransferLib.sol";
import {SafeCast} from "@openzeppelin-contracts-5.0.2/utils/math/SafeCast.sol";
import {ERC721} from "@solady/tokens/ERC721.sol";
import {ITokenRenderer} from "../interfaces/ITokenRenderer.sol";
contract Lending is ERC721 {
    using FixedPointMathLib for uint256;
    using SafeCast for int256;

    error StaleData();

    uint256 public constant K = 0.1e18;
    uint256 public constant STALE_DATA_TIMEOUT = 90 minutes;
    uint256 public constant INTEREST_PERIOD = 30 days;

    IAggregatorV3 public immutable oracle;

    IDyad public dyad;
    sDYAD public sDyad;
    IWETH public weth;
    ITokenRenderer public renderer;

    uint256 public totalDyadBorrowed;
    uint256 public dyadInVault;
    uint256 public totalCollatValue;

    uint256 public globalInterestRate;
    uint256 public lastInterestUpdateTime;

    uint256 public totalSupply;

    struct Lender {
        uint256 dyadDeposited;
        uint256 lastGlobalInterestRate;
        uint256 interestEarned;
    }

    struct Loan {
        uint256 collat;
        uint256 debt;
        uint256 interest;
        uint256 lastPaymentTime;
    }

    mapping(address => Loan) public loans;
    mapping(address => Lender) public lenders;

    constructor(IDyad _dyad, sDYAD _sDyad, IWETH _weth, IAggregatorV3 _oracle, ITokenRenderer _renderer) {
        dyad = _dyad;
        sDyad = _sDyad;
        weth = _weth;
        oracle = _oracle;
        renderer = _renderer;
    }

    function name() public pure override returns (string memory) {
        return "DYAD Bond";
    }

    function symbol() public pure override returns (string memory) {
        return "BOND";
    }

    function tokenURI(uint256 id) public view override returns (string memory) {
        if (!_exists(id)) {
            revert TokenDoesNotExist();
        }

        return renderer.tokenURI(id);
    }

    function lend(uint256 dyadAmount) external {
        dyad.transferFrom(msg.sender, address(this), dyadAmount);
        dyadInVault += dyadAmount;
        sDyad.deposit(dyadAmount, msg.sender);

        updateInterest();

        Lender storage lender = lenders[msg.sender];
        lender.dyadDeposited += dyadAmount;
        lender.lastGlobalInterestRate = globalInterestRate;
        uint256 newInterestRate = globalInterestRate - lender.lastGlobalInterestRate;
        lender.interestEarned += lender.dyadDeposited.mulWad(newInterestRate);
    }

    function borrow(uint256 dyadAmount) public payable {
        weth.deposit{value: msg.value}();
        _borrow(dyadAmount);
    }

    function borrow(uint256 dyadAmount, uint256 wethAmount) public {
        SafeTransferLib.safeTransferFrom(address(weth), msg.sender, address(this));
        _borrow(dyadAmount, wethAmount);
    }

    function _borrow(uint256 dyadAmount, uint256 collatAmount) private {
        uint256 ethCollat = loans[msg.sender].collat;
        uint256 collatValue = ethCollat.mulWad(ethPrice());

        require(collatValue >= dyadAmount, "Insufficient collateral");

        uint256 interestRate = interest(dyadAmount);

        loans[msg.sender].debt += dyadAmount;
        loans[msg.sender].interest = interestRate;
        loans[msg.sender].lastPaymentTime = block.timestamp;

        totalDyadBorrowed += dyadAmount;
        dyadInVault -= dyadAmount;
        totalCollatValue += collatValue;

        dyad.transfer(msg.sender, dyadAmount);
        _mint(msg.sender, ++totalSupply);
    }

    function payInterest(uint256 amount) external {
        Loan storage loan = loans[msg.sender];
        uint256 interestDue = (loan.debt * loan.interest) * (block.timestamp - loan.lastPaymentTime) / INTEREST_PERIOD;
        require(amount >= interestDue);

        uint256 repaymentAmount = amount - interestDue;
        loan.debt -= repaymentAmount;
        totalDyadBorrowed -= repaymentAmount;
        dyadInVault += repaymentAmount;

        globalInterestRate += interestDue.divWad(dyadInVault);

        dyad.transferFrom(msg.sender, address(this), repaymentAmount);
    }

    function collectInterest() external {
        updateInterest();

        Lender storage lender = lenders[msg.sender];
        uint256 accumaledInterest = lender.dyadDeposited.mulWad(globalInterestRate - lender.lastGlobalInterestRate);
        lender.interestEarned += accumaledInterest;
        lender.lastGlobalInterestRate = globalInterestRate;

        uint256 interestToCollect = lender.interestEarned;

        lender.interestEarned = 0;
        dyad.transfer(msg.sender, interestToCollect);
    }

    function liquidate(address borrower, address receiver) external {
        Loan storage loan = loans[borrower];
        require(loan.debt > 0);
        require(block.timestamp > loan.lastPaymentTime + INTEREST_PERIOD);

        uint256 interestDue = (loan.debt * loan.interest) * (block.timestamp - loan.lastPaymentTime) / INTEREST_PERIOD;
        uint256 totalDue = loan.debt + interestDue;

        dyad.transferFrom(msg.sender, address(this), totalDue);

        SafeTransferLib.safeTransfer(address(weth), receiver, loan.collat);

        totalCollatValue -= loan.collat;

        loan.collat = 0;
        loan.debt = 0;
        loan.interest = 0;
        loan.lastPaymentTime = 0;

        sDyad.withdraw(loan.debt, receiver, msg.sender);
    }

    function updateInterest() internal {
        if (block.timestamp > lastInterestUpdateTime) {
            uint256 timeElapsed = block.timestamp - lastInterestUpdateTime;
            globalInterestRate += timeElapsed * K;
            lastInterestUpdateTime = block.timestamp;
        }
    }

    function interest(uint256 dyadAmount) public view returns (uint256) {
        uint256 newTotalDyadBorrowed = totalDyadBorrowed + dyadAmount;

        // totalDyadDeployed^2
        uint256 totalDyadBorrowdSquared = newTotalDyadBorrowed.mulWad(newTotalDyadBorrowed);

        // (totalDyadDeployed^2) / dyadInVault
        uint256 ratio = totalDyadBorrowdSquared.divWad(dyadInVault);

        // k * ratio
        uint256 result = K.mulWad(ratio);

        // final result: (k * (totalDyadDeployed^2)) / (dyadInVault * totalCollatValue)
        return result.divWad(totalCollatValue);
    }

    function ethPrice() public view returns (uint256) {
        (, int256 answer,, uint256 updatedAt,) = oracle.latestRoundData();
        if (block.timestamp > updatedAt + STALE_DATA_TIMEOUT) revert StaleData();
        return answer.toUint256();
    }
}
