// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// OpenZeppelin implementations
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

abstract contract Auth is Initializable {
    address internal owner;

    mapping(address => bool) internal authorizations;

    event OwnershipTransferred(address owner);

    modifier onlyOwner() {
        require(isOwner(msg.sender), "Auth: Caller is not the owner");
        _;
    }

    modifier authorized() {
        require(isAuthorized(msg.sender), "Auth: Caller is not authorized");
        _;
    }

    function __Auth_init(address _owner) internal onlyInitializing {
        owner = _owner;
        authorizations[_owner] = true;
    }

    function getOwner() public view returns (address) {
        return owner;
    }

    function authorize(address _account) public onlyOwner {
        authorizations[_account] = true;
    }

    function unauthorize(address _account) public onlyOwner {
        authorizations[_account] = false;
    }

    function isOwner(address _account) public view returns (bool) {
        return _account == owner;
    }

    function isAuthorized(address _account) public view returns (bool) {
        return authorizations[_account];
    }

    function transferOwnership(address payable _account) public onlyOwner {
        owner = _account;
        authorizations[_account] = true;
        emit OwnershipTransferred(_account);
    }
}
