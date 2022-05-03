// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface ISleepNFT {
    function safeTransferFrom(
        address from,
        address to,
        uint256 tokenId
    ) external;

    function tokenType(uint256 tokenId) external view returns (uint8);
}
