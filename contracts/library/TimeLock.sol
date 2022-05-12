//SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";


contract Timelock is 
    AccessControlUpgradeable
{

    bytes32 public constant SUPER_ADMIN = keccak256("SUPER_ADMIN");
    bytes32 public constant ADMIN = keccak256("ADMIN");
    bytes32 public constant GOVERNOR = keccak256("GOVERNOR");

    event NewAdmin(address indexed newAdmin);
    event NewPendingAdmin(address indexed newPendingAdmin);
    event NewDelay(uint256 indexed newDelay);
    event CancelTransaction(bytes32 indexed txHash, address indexed target, uint256 value, string signature,  bytes data, uint256 eta);
    event DefeatedTransaction(bytes32 indexed txHash, address indexed target, uint256 value, string signature,  bytes data, uint256 eta);
    event ExecuteTransaction(bytes32 indexed txHash, address indexed target, uint256 value, string signature,  bytes data, uint256 eta);
    event QueueTransaction(bytes32 indexed txHash, address indexed target, uint256 value, string signature, bytes data, uint256 eta);

    uint256 public constant MINIMUM_DELAY = 2 days;
    uint256 public constant MAXIMUM_DELAY = 30 days;

    uint256 public delay;

    mapping (bytes32 => bool) public queuedTransactions;

    function __Timelock_init__() internal  {
        __AccessControl_init();

        _setRoleAdmin(ADMIN, SUPER_ADMIN);
        _setRoleAdmin(GOVERNOR, SUPER_ADMIN);
        _setupRole(ADMIN, msg.sender);
        _setupRole(SUPER_ADMIN, msg.sender);
        _setupRole(GOVERNOR, msg.sender);

    }

    modifier adminOrGovernor() {
        require(
            hasRole(ADMIN, msg.sender) || hasRole(GOVERNOR, msg.sender),
            "Timelock: Call must come from admin or governor."
        );
        _;
    }

    receive() external payable { }

    function setDelay(uint256 delay_) public adminOrGovernor {
        require(delay_ >= MINIMUM_DELAY, "Timelock::setDelay: Delay must exceed minimum delay.");
        require(delay_ <= MAXIMUM_DELAY, "Timelock::setDelay: Delay must not exceed maximum delay.");
        delay = delay_;

        emit NewDelay(delay);
    }


    function queueTransaction(address target, uint256 value, string memory signature, bytes memory data, uint256 eta) internal returns (bytes32) {
        require(eta >= getBlockTimestamp() + delay, "Timelock::queueTransaction: Estimated execution block must satisfy delay.");

        bytes32 txHash = keccak256(abi.encode(target, value, signature, data, eta));
        queuedTransactions[txHash] = true;

        emit QueueTransaction(txHash, target, value, signature, data, eta);
        return txHash;
    }

    function cancelTransaction(address target, uint256 value, string memory signature, bytes memory data, uint256 eta) internal {

        bytes32 txHash = keccak256(abi.encode(target, value, signature, data, eta));
        queuedTransactions[txHash] = false;

        emit CancelTransaction(txHash, target, value, signature, data, eta);
    }

    function defeatedTransaction(address target, uint256 value, string memory signature, bytes memory data, uint256 eta) internal {

        bytes32 txHash = keccak256(abi.encode(target, value, signature, data, eta));
        queuedTransactions[txHash] = false;

        emit DefeatedTransaction(txHash, target, value, signature, data, eta);
    }

    function executeTransaction(address target, uint256 value, string memory signature, bytes memory data, uint256 eta) internal returns (bytes memory) {

        bytes32 txHash = keccak256(abi.encode(target, value, signature, data, eta));
        require(queuedTransactions[txHash], "Timelock::executeTransaction: Transaction hasn't been queued.");
        require(getBlockTimestamp() >= eta, "Timelock::executeTransaction: Transaction hasn't surpassed time lock.");

        queuedTransactions[txHash] = false;

        bytes memory callData;

        if (bytes(signature).length == 0) {
            callData = data;
        } else {
            callData = abi.encodePacked(bytes4(keccak256(bytes(signature))), data);
        }

        // solium-disable-next-line security/no-call-value
        (bool success, bytes memory returnData) = target.call{value: value}(callData);
        require(success, "Timelock::executeTransaction: Transaction execution reverted.");

        emit ExecuteTransaction(txHash, target, value, signature, data, eta);

        return returnData;
    }

    function getBlockTimestamp() internal view returns (uint256) {
        // solium-disable-next-line security/no-block-members
        return block.timestamp;
    }
}