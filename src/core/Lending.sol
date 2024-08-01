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

    uint256 public constant K = 0.1e18;
    uint256 public constant STALE_DATA_TIMEOUT = 90 minutes;
    uint256 public constant INTEREST_PERIOD = 30 days;

    IAggregatorV3 public immutable oracle;

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

    function borrow(uint256 dyadAmount, BondType bondType) public payable {
        weth.deposit{value: msg.value}();
        _borrow(dyadAmount, msg.value, bondType);
    }

    function borrow(uint256 dyadAmount, uint256 wethAmount, BondType bondType) public {
        SafeTransferLib.safeTransferFrom(address(weth), msg.sender, address(this), wethAmount);
        _borrow(dyadAmount, wethAmount, bondType);
    }

    function _borrow(uint256 dyadAmount, uint256 collatAmount, BondType bondType) private {
        uint256 collatValue = collatAmount.mulWad(ethPrice());

        require(collatValue >= dyadAmount, "Insufficient collateral");

        uint256 interestRate = interest(dyadAmount);

        uint256 initialInterest = dyadAmount.mulWad(interestRate).mulDiv(7 days, 365 days);

        uint256 tokenId = ++totalSupply;

        bondDetails[tokenId] = Bond({
            collat: uint96(collatAmount),
            totalBorrowed: uint96(dyadAmount + initialInterest),
            interestRate: uint64(interestRate),
            interest: uint96(initialInterest),
            lastPaymentTime: uint40(block.timestamp),
            bondType: bondType
        });

        sDyad.borrow(dyadAmount, msg.sender);
        _mint(msg.sender, tokenId);
    }

    function payInterest(uint256 loanId, uint256 amount) external {
        Bond storage bond = bondDetails[loanId];

        // Must be an active bond
        require(bond.totalBorrowed > 0);

        uint256 interestDue = _interestDue(bond);
        uint256 totalInterestPaid = bond.interest + amount;

        // Must pay at least the interest due
        // technically if this condition is not true the bond
        // has defaulted and not been liquidated yet
        require(totalInterestPaid < interestDue);

        bond.interest = uint96(totalInterestPaid - interestDue);

        dyad.transferFrom(msg.sender, address(sDyad), amount);
    }

    function _interestDue(Bond storage bond) internal view returns (uint256) {
        return uint256(bond.totalBorrowed).mulWad(bond.interestRate).mulDiv(
            block.timestamp - bond.lastPaymentTime, 365 days
        );
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

    function interest(uint256 dyadAmount) public view returns (uint256) {
        uint256 totalDyadBorrowed = sDyad.totalBorrowed();
        uint256 dyadInVault = dyad.balanceOf(address(sDyad));
        uint256 totalCollatValue = weth.balanceOf(address(this)).mulWad(ethPrice());

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
