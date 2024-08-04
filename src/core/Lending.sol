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
import {Bond, BondType} from "./Structs.sol";

contract Lending is ERC721 {
    using FixedPointMathLib for uint256;
    using SafeCast for int256;

    error StaleData();
    error LoanDoesNotExist();

    uint256 public constant K = 0.1e18;
    uint256 public constant STALE_DATA_TIMEOUT = 90 minutes;
    uint256 public constant INTEREST_PERIOD = 30 days;

    IAggregatorV3 public immutable ORACLE;

    IDyad public dyad;
    sDYAD public sDyad;
    IWETH public weth;
    ITokenRenderer public renderer;

    uint256 public totalSupply;

    mapping(uint256 => Bond) public bondDetails;

    constructor(IDyad _dyad, sDYAD _sDyad, IWETH _weth, IAggregatorV3 _oracle, ITokenRenderer _renderer) {
        dyad = _dyad;
        sDyad = _sDyad;
        weth = _weth;
        ORACLE = _oracle;
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

    /**************************************************************************
        Public state changing methods
    **************************************************************************/

    function borrow(uint256 dyadAmount, BondType bondType) external payable {
        weth.deposit{value: msg.value}();
        _borrow(dyadAmount, msg.value, bondType);
    }

    function borrow(uint256 dyadAmount, uint256 wethAmount, BondType bondType) external {
        SafeTransferLib.safeTransferFrom(address(weth), msg.sender, address(this), wethAmount);
        _borrow(dyadAmount, wethAmount, bondType);
    }

    function payInterest(uint256 loanId, uint256 amount) external {
        Bond storage bond = bondDetails[loanId];

        if (bond.totalBorrowed == 0) {
            revert LoanDoesNotExist();
        }

        uint256 interestDue = _interestDue(bond);
        uint256 totalInterestPaid = bond.interest + amount;

        // Must pay at least the interest due
        // technically if this condition is not true the bond
        // has defaulted and not been liquidated yet
        require(totalInterestPaid < interestDue);

        bond.interest = uint96(totalInterestPaid - interestDue);

        dyad.transferFrom(msg.sender, address(sDyad), amount);
    }

    function repay(uint256 loanId, uint256 amount) external {
        Bond memory bond = bondDetails[loanId];

        if (bond.totalBorrowed == 0) {
            revert LoanDoesNotExist();
        }

        uint256 interestDue = _interestDue(bond);
        uint256 totalDue = _payoffAmount(bond);

        if (amount > totalDue) {
            SafeTransferLib.safeTransferFrom(address(dyad),msg.sender, address(sDyad), totalDue);
            SafeTransferLib.safeTransfer(address(weth), msg.sender, bond.collat);
            _burn(loanId);
            delete bondDetails[loanId];
        } else {

            uint256 proportionalCollatAmount = uint256(bond.collat).mulDiv(amount, totalDue);
            
            bondDetails[loanId] = Bond({
                collat: uint96(bond.collat - proportionalCollatAmount),
                totalBorrowed: uint96(bond.totalBorrowed - amount),
                interestRate: bond.interestRate,
                interest: uint96(bond.interest - interestDue),
                lastPaymentTime: uint40(block.timestamp),
                bondType: bond.bondType
            });

            SafeTransferLib.safeTransferFrom(address(dyad), msg.sender, address(sDyad), amount);
            SafeTransferLib.safeTransfer(address(weth), msg.sender, proportionalCollatAmount);
        }
    }

    function liquidate(uint256 loanId, address receiver) external {
        Bond storage bond = bondDetails[loanId];
        require(bond.totalBorrowed > 0);
        require(block.timestamp > bond.lastPaymentTime + INTEREST_PERIOD);

        uint256 interestDue = _interestDue(bond);
        uint256 totalDue = bond.totalBorrowed + interestDue - bond.interest;

        dyad.transferFrom(msg.sender, address(this), totalDue);
        SafeTransferLib.safeTransfer(address(weth), receiver, bond.collat);

        delete bondDetails[loanId];
    }

    /**************************************************************************
        Internal state changing methods
    **************************************************************************/

    function _borrow(uint256 dyadAmount, uint256 collatAmount, BondType bondType) private {
        uint256 collatValue = collatAmount.mulWad(_ethPrice());

        require(collatValue >= dyadAmount, "Insufficient collateral");

        uint256 rate = _interestRate(SafeCast.toInt256(dyadAmount));

        uint256 initialInterest = dyadAmount.mulWad(rate).mulDiv(7 days, 365 days);

        uint256 tokenId = ++totalSupply;

        bondDetails[tokenId] = Bond({
            collat: uint96(collatAmount),
            totalBorrowed: uint96(dyadAmount + initialInterest),
            interestRate: uint64(rate),
            interest: uint96(initialInterest),
            lastPaymentTime: uint40(block.timestamp),
            bondType: bondType
        });

        sDyad.borrow(dyadAmount, msg.sender);
        _mint(msg.sender, tokenId);
    }

    /**************************************************************************
        Public view methods
    **************************************************************************/

    function interestRate() external view returns (uint256) {
        return _interestRate(0);
    }

    function payoffAmount(uint256 loanId) external view returns (uint256) {
        Bond memory bond = bondDetails[loanId];
        if (bond.totalBorrowed == 0) revert LoanDoesNotExist();

        return _payoffAmount(bond);
    }

    /**************************************************************************
        Internal view methods
    **************************************************************************/

    function _interestRate(int256 dyadAmount) internal view returns (uint256) {
        uint256 totalDyadBorrowed = sDyad.totalBorrowed();
        uint256 dyadInVault = dyad.balanceOf(address(sDyad));
        uint256 totalCollatValue = weth.balanceOf(address(this)).mulWad(_ethPrice());

        uint256 newTotalDyadBorrowed = SafeCast.toUint256(SafeCast.toInt256(totalDyadBorrowed) + dyadAmount);

        // totalDyadDeployed^2
        uint256 totalDyadBorrowdSquared = newTotalDyadBorrowed.mulWad(newTotalDyadBorrowed);

        // (totalDyadDeployed^2) / dyadInVault
        uint256 ratio = totalDyadBorrowdSquared.divWad(dyadInVault);

        // k * ratio
        uint256 result = K.mulWad(ratio);

        // final result: (k * (totalDyadDeployed^2)) / (dyadInVault * totalCollatValue)
        return result.divWad(totalCollatValue);
    }

    function _payoffAmount(Bond memory bond) internal view returns (uint256 totalDue) {
        totalDue = bond.totalBorrowed + _interestDue(bond);
        if (bond.bondType == BondType.FixedPrincipal) {
            totalDue -= bond.interest;
        } else {
            // get the interest rate after repayment
            uint256 newInterestRate = _interestRate(SafeCast.toInt256(bond.totalBorrowed) * -1);
            // repay amount is inversely proportional to the change in interest rate since origination
            if (bond.interestRate > newInterestRate) {
                totalDue += uint256(bond.totalBorrowed).mulDiv(newInterestRate - bond.interestRate, bond.interestRate);
            } else {
                totalDue -= uint256(bond.totalBorrowed).mulDiv(bond.interestRate - newInterestRate, bond.interestRate);
            }
        }
    }

    function _interestDue(Bond memory bond) internal view returns (uint256) {
        return uint256(bond.totalBorrowed).mulWad(bond.interestRate).mulDiv(
            block.timestamp - bond.lastPaymentTime, 365 days
        );
    }

    function _ethPrice() internal view returns (uint256) {
        (, int256 answer,, uint256 updatedAt,) = ORACLE.latestRoundData();
        if (block.timestamp > updatedAt + STALE_DATA_TIMEOUT) revert StaleData();
        return answer.toUint256();
    }
}
