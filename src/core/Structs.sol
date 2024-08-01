// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

struct Bond {
    uint96 collat;
    uint96 totalBorrowed;
    uint64 interestRate;
    uint96 interest;
    uint40 lastPaymentTime;
}