// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// OpenZeppelin implementations
import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/governance/TimelockController.sol";

contract Timelock is TimelockController {
    using Counters for Counters.Counter;

    Counters.Counter private numPendingAndReadyOperations;

    constructor(
        uint256 _minDelay,
        address[] memory _proposers,
        address[] memory _executors
    ) TimelockController(_minDelay, _proposers, _executors) {}

    function getNumPendingAndReadyOperations() external view returns (uint256) {
        return numPendingAndReadyOperations.current();
    }

    function schedule(
        address _target,
        uint256 _value,
        bytes calldata _data,
        bytes32 _predecessor,
        bytes32 _salt,
        uint256 _delay
    ) public virtual override onlyRole(PROPOSER_ROLE) {
        super.schedule(_target, _value, _data, _predecessor, _salt, _delay);
        numPendingAndReadyOperations.increment();
    }

    function scheduleBatch(
        address[] calldata _targets,
        uint256[] calldata _values,
        bytes[] calldata _datas,
        bytes32 _predecessor,
        bytes32 _salt,
        uint256 _delay
    ) public virtual override onlyRole(PROPOSER_ROLE) {
        super.scheduleBatch(
            _targets,
            _values,
            _datas,
            _predecessor,
            _salt,
            _delay
        );
        numPendingAndReadyOperations.increment();
    }

    function cancel(bytes32 _id)
        public
        virtual
        override
        onlyRole(PROPOSER_ROLE)
    {
        super.cancel(_id);
        numPendingAndReadyOperations.decrement();
    }

    function execute(
        address _target,
        uint256 _value,
        bytes calldata _data,
        bytes32 _predecessor,
        bytes32 _salt
    ) public payable virtual override onlyRoleOrOpenRole(EXECUTOR_ROLE) {
        super.execute(_target, _value, _data, _predecessor, _salt);
        numPendingAndReadyOperations.decrement();
    }

    function executeBatch(
        address[] calldata _targets,
        uint256[] calldata _values,
        bytes[] calldata _datas,
        bytes32 _predecessor,
        bytes32 _salt
    ) public payable virtual override onlyRoleOrOpenRole(EXECUTOR_ROLE) {
        super.executeBatch(_targets, _values, _datas, _predecessor, _salt);
        numPendingAndReadyOperations.decrement();
    }
}
