pragma solidity ^0.4.24;

import "@aragon/os/contracts/apps/AragonApp.sol";
import "@aragon/os/contracts/common/IForwarder.sol";
import "@aragon/os/contracts/common/IForwarderFee.sol";
import "@aragon/os/contracts/common/SafeERC20.sol";
import "@aragon/os/contracts/lib/token/ERC20.sol";
import "@aragon/os/contracts/lib/math/SafeMath.sol";
import "./lib/WithdrawLockLib.sol";


contract Lock is AragonApp, IForwarder, IForwarderFee {

    using SafeERC20 for ERC20;
    using SafeMath for uint256;
    using WithdrawLockLib for WithdrawLockLib.WithdrawLock[];

    bytes32 public constant CHANGE_DURATION_ROLE = keccak256("CHANGE_DURATION_ROLE");
    bytes32 public constant CHANGE_AMOUNT_ROLE = keccak256("CHANGE_AMOUNT_ROLE");
    bytes32 public constant CHANGE_GRIEFING_ROLE = keccak256("CHANGE_GRIEFING_ROLE");
    bytes32 public constant LOCK_TOKENS_ROLE = keccak256("LOCK_TOKENS_ROLE");

    string private constant ERROR_TOO_MANY_WITHDRAW_LOCKS = "LOCK_TOO_MANY_WITHDRAW_LOCKS";
    string private constant ERROR_CAN_NOT_FORWARD = "LOCK_CAN_NOT_FORWARD";
    string private constant ERROR_TRANSFER_REVERTED = "LOCK_TRANSFER_REVERTED";

    ERC20 public token;
    uint256 public lockDuration;
    uint256 public lockAmount;
    uint256 public griefingFactor;

    uint256 private constant WHOLE_GRIEFING = 100;

    // Using an array of WithdrawLocks instead of a mapping here means we cannot add fields to the WithdrawLock
    // struct in an upgrade of this contract. If we want to be able to add to the WithdrawLock structure in
    // future we must use a mapping instead.
    mapping(address => WithdrawLockLib.WithdrawLock[]) public addressesWithdrawLocks;

    event ChangeLockDuration(uint256 newLockDuration);
    event ChangeLockAmount(uint256 newLockAmount);
    event NewLock(address lockAddress, uint256 unlockTime, uint256 lockAmount);
    event Withdrawal(address withdrawalAddress ,uint256 withdrawalLockCount);

    /**
    * @notice Initialize the Lock app
    * @param _token The token which will be locked when forwarding actions
    * @param _lockDuration The duration tokens will be locked before being able to be withdrawn
    * @param _lockAmount The amount of the token that is locked for each forwarded action
    * @param _griefingFactor The griefing pct will be calculated as `griefingFactor / WHOLE_GRIEFING`
    */
    function initialize(address _token, uint256 _lockDuration, uint256 _lockAmount, uint256 _griefingFactor) external onlyInit {
        token = ERC20(_token);
        lockDuration = _lockDuration;
        lockAmount = _lockAmount;
        griefingFactor = _griefingFactor;

        initialized();
    }

    /**
    * @notice Change lock duration to `_lockDuration`
    * @param _lockDuration The new lock duration
    */
    function changeLockDuration(uint256 _lockDuration) external auth(CHANGE_DURATION_ROLE) {
        lockDuration = _lockDuration;
        emit ChangeLockDuration(lockDuration);
    }

    /**
    * @notice Change lock amount to `_lockAmount`
    * @param _lockAmount The new lock amount
    */
    function changeLockAmount(uint256 _lockAmount) external auth(CHANGE_AMOUNT_ROLE) {
        lockAmount = _lockAmount;
        emit ChangeLockAmount(lockAmount);
    }

    /**
    * @notice Change griefing factor to `_griefingFactor`
    * @param _griefingFactor The new griefing factor
    */
    function changeGriefingFactor(uint256 _griefingFactor) external auth(CHANGE_GRIEFING_ROLE) {
        griefingFactor = _griefingFactor;
        emit ChangeLockAmount(griefingFactor);
    }

    /**
    * @notice Withdraw all withdrawable tokens
    */
    function withdrawTokens() external {
        WithdrawLockLib.WithdrawLock[] storage addressWithdrawLocks = addressesWithdrawLocks[msg.sender];
        _withdrawTokens(msg.sender, addressWithdrawLocks.length);
    }

    /**
    * @notice Withdraw all withdrawable tokens from the `_numberWithdrawLocks` oldest withdraw lock's
    * @param _numberWithdrawLocks The number of withdraw locks to attempt withdrawal from
    */
    function withdrawTokens(uint256 _numberWithdrawLocks) external {
        _withdrawTokens(msg.sender, _numberWithdrawLocks);
    }

    /**
    * @notice Tells the forward fee token and amount of the Lock app
    * @dev IFeeForwarder interface conformance
    *      Note that the Lock app has to be the first forwarder in the transaction path, it must be called by an EOA not another forwarder, in order for the griefing mechanism to work
    * @return Forwarder token address
    * @return Forwarder lock amount
    */
    function forwardFee() external view returns (address, uint256) {
        (uint256 _griefAmount, ) = getGriefing(msg.sender);

        uint256 totalLockAmountRequired = lockAmount.add(_griefAmount);

        return (address(token), totalLockAmountRequired);
    }

    /**
    * @notice Tells whether the Lock app is a forwarder or not
    * @dev IForwarder interface conformance
    * @return Always true
    */
    function isForwarder() external pure returns (bool) {
        return true;
    }

    /**
    * @notice Tells whether the _sender can forward actions or not
    * @dev IForwarder interface conformance
    * @return True if _sender has LOCK_TOKENS_ROLE role
    */
    function canForward(address _sender, bytes) public view returns (bool) {
        return canPerform(_sender, LOCK_TOKENS_ROLE, arr());
    }

    /**
    * @notice Locks the required amount of tokens and executes the specified action
    * @dev IForwarder interface conformance. Consider using pretransaction on UI for necessary approval.
    *      Note that the Lock app has to be the first forwarder in the transaction path, it must be called by an EOA not another forwarder, in order for the griefing mechanism to work
    * @param _evmCallScript Script to execute
    */
    function forward(bytes _evmCallScript) public {
        require(canForward(msg.sender, _evmCallScript), ERROR_CAN_NOT_FORWARD);

        (uint256 griefAmount, uint256 griefDuration) = getGriefing(msg.sender);

        uint256 totalAmount = lockAmount.add(griefAmount);
        uint256 totalDuration = lockDuration.add(griefDuration);

        WithdrawLockLib.WithdrawLock[] storage addressWithdrawLocks = addressesWithdrawLocks[msg.sender];
        uint256 unlockTime = getTimestamp().add(totalDuration);
        addressWithdrawLocks.push(WithdrawLockLib.WithdrawLock(unlockTime, totalAmount));

        require(token.safeTransferFrom(msg.sender, address(this), totalAmount), ERROR_TRANSFER_REVERTED);

        emit NewLock(msg.sender, unlockTime, totalAmount);
        runScript(_evmCallScript, new bytes(0), new address[](0));
    }

    function getWithdrawLocksCount(address _lockAddress) public view returns (uint256) {
        return addressesWithdrawLocks[_lockAddress].length;
    }

    /**
    * @notice Get's amount and duration penalty based on the number of current locks `_sender` has
    * @param _sender account that is going to lock tokens
    * @return amount penalty
    * @return duration penalty
    */
    function getGriefing(address _sender) public view returns (uint256, uint256) {
        WithdrawLockLib.WithdrawLock[] memory addressWithdrawLocks = addressesWithdrawLocks[_sender];

        uint256 activeLocks = 0;
        for (uint256 withdrawLockIndex = 0; withdrawLockIndex < addressWithdrawLocks.length; withdrawLockIndex++) {
            if (getTimestamp() < addressWithdrawLocks[withdrawLockIndex].unlockTime) {
                activeLocks += 1;
            }
        }

        return (lockAmount.mul(activeLocks).mul(griefingFactor).div(WHOLE_GRIEFING), lockDuration.mul(activeLocks).mul(griefingFactor).div(WHOLE_GRIEFING));
    }

    function _withdrawTokens(address _sender, uint256 _numberWithdrawLocks) internal {
        WithdrawLockLib.WithdrawLock[] storage addressWithdrawLocksStorage = addressesWithdrawLocks[_sender];
        WithdrawLockLib.WithdrawLock[] memory addressWithdrawLocksCopy = addressesWithdrawLocks[_sender];

        require(_numberWithdrawLocks <= addressWithdrawLocksCopy.length, ERROR_TOO_MANY_WITHDRAW_LOCKS);

        uint256 amountOwed = 0;
        uint256 withdrawLockCount = 0;

        for (uint256 withdrawLockIndex = 0; withdrawLockIndex < _numberWithdrawLocks; withdrawLockIndex++) {

            WithdrawLockLib.WithdrawLock memory withdrawLock = addressWithdrawLocksCopy[withdrawLockIndex];

            if (getTimestamp() > withdrawLock.unlockTime) {
                amountOwed = amountOwed.add(withdrawLock.lockAmount);
                withdrawLockCount += 1;
                addressWithdrawLocksStorage.deleteItem(withdrawLock);
            }
        }
        token.transfer(_sender, amountOwed);

        emit Withdrawal(_sender, withdrawLockCount);
    }
}
