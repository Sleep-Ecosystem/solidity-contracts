// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IDividendDistributor {
    function setDistributionCriteria(uint256 minPeriod, uint256 minDistribution)
        external;

    function setShare(address shareholder, uint256 amount) external;

    function deposit() external payable;

    function process(uint256 gas) external;
}
