// SPDX-License-Identifier: MIT

pragma solidity >=0.8.20;

import { IPayable } from "../../lib/reactive-lib-omni/src/interfaces/IPayable.sol";
import { IPayer } from "../../lib/reactive-lib-omni/src/interfaces/IPayer.sol";

/**
 * @title MockCallbackProxy
 * @notice Simulates the Reactive Network Destination Callback Proxy
 *         (Base Sepolia: `0x476F44b11F5C942c58f4c8E3d0300E5710743585`,
 *          Unichain Sepolia: `0x775c9B990ADe401060B78D0e98684eEf8d2466C1`).
 * @dev Implements the exact Reactive Network callback authentication protocol:
 *      overwrites the first argument (`payload[4..36]`) of the ABI-encoded payload with the
 *      `reactiveSender` address before calling `recipient`.
 */
contract MockCallbackProxy is IPayable {
    error PayloadTooShort(uint256 length);
    error CallbackExecutionFailed(bytes returnData);

    event CallbackDelivered(
        address indexed reactiveSender,
        address indexed recipient,
        uint64 gasLimit,
        bool success
    );

    mapping(address => uint256) public debts;
    uint256 public totalDelivered;

    receive() external payable override {}

    function debt(address contract_) external view override returns (uint256 debt_) {
        return debts[contract_];
    }

    function setDebt(address contract_, uint256 amount_) external {
        debts[contract_] = amount_;
    }

    function requestPayment(address payer_, uint256 amount_) external {
        IPayer(payable(payer_)).pay(amount_);
        if (debts[payer_] >= amount_) {
            debts[payer_] -= amount_;
        } else {
            debts[payer_] = 0;
        }
    }

    /**
     * @notice Injects `reactiveSender_` into the first ABI parameter of `payload_` and invokes `recipient_`.
     */
    function dispatch(
        address reactiveSender_,
        address recipient_,
        uint64 gasLimit_,
        bytes memory payload_
    ) external returns (bytes memory returnData) {
        if (payload_.length < 36) revert PayloadTooShort(payload_.length);

        // Overwrite first 32-byte word after the 4-byte function selector with `uint256(uint160(reactiveSender_))`
        uint256 senderWord = uint256(uint160(reactiveSender_));
        assembly {
            // `payload_` data starts at `add(payload_, 32)`.
            // Selector is 4 bytes (`add(payload_, 32)` .. `add(payload_, 36)`).
            // First parameter word is at `add(payload_, 36)`.
            mstore(add(payload_, 36), senderWord)
        }

        bool success;
        (success, returnData) = recipient_.call{ gas: gasLimit_ }(payload_);
        if (!success) {
            revert CallbackExecutionFailed(returnData);
        }

        ++totalDelivered;
        emit CallbackDelivered(reactiveSender_, recipient_, gasLimit_, true);
    }
}
