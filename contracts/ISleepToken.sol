// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface ISleepToken {
    function mintRewards(address recipient, uint256 rewardAmount) external;

    function transfer(address to, uint256 amount) external returns (bool);

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool);
}
