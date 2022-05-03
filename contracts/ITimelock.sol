// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface ITimelock {
    function getNumPendingAndReadyOperations() external view returns (uint256);
}
