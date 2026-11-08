// SPDX-License-Identifier: MIT

pragma solidity >=0.8.20;

import { ISystemContract } from "../../lib/reactive-lib-omni/src/interfaces/ISystemContract.sol";
import { IReactive } from "../../lib/reactive-lib-omni/src/interfaces/IReactive.sol";
import { IPayer } from "../../lib/reactive-lib-omni/src/interfaces/IPayer.sol";

/**
 * @title MockOmniSystemContract
 * @notice High-fidelity simulation of the Reactive Omni System Contract at `0x8888888888888888888888888888888888888888`.
 * @dev Used in Foundry (`vm.etch`) and Hardhat (`hardhat_setCode`) to test the full Reactive Omni
 *      subscription, `react(LogRecord)`, `requestCallbackV_1_0`, and debt settlement lifecycle.
 */
contract MockOmniSystemContract is ISystemContract {
    struct SubscriptionRecord {
        address subscriber;
        uint256 chainId;
        address contractAddress;
        uint256 topic0;
        uint256 topic1;
        uint256 topic2;
        uint256 topic3;
        bool active;
    }

    event Subscribed(
        address indexed subscriber,
        uint256 indexed chainId,
        address indexed contractAddress,
        uint256 topic0
    );

    event Unsubscribed(
        address indexed subscriber,
        uint256 indexed chainId,
        address indexed contractAddress,
        uint256 topic0
    );

    event CallbackRequest(
        uint256 indexed chainId,
        address indexed sender,
        address indexed recipient,
        CallbackVersion version,
        bytes configuration
    );

    error InvalidCallbackVersion();

    SubscriptionRecord[] public subscriptions;
    CallbackConfiguration_V_1_0[] public callbackQueue;
    mapping(address => uint256) public debts;

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

    function subscribe(
        uint256 chainId_,
        address contract_,
        uint256 topic0_,
        uint256 topic1_,
        uint256 topic2_,
        uint256 topic3_
    ) external override {
        subscriptions.push(
            SubscriptionRecord({
                subscriber: msg.sender,
                chainId: chainId_,
                contractAddress: contract_,
                topic0: topic0_,
                topic1: topic1_,
                topic2: topic2_,
                topic3: topic3_,
                active: true
            })
        );
        emit Subscribed(msg.sender, chainId_, contract_, topic0_);
    }

    function unsubscribe(
        uint256 chainId_,
        address contract_,
        uint256 topic0_,
        uint256 topic1_,
        uint256 topic2_,
        uint256 topic3_
    ) external override {
        uint256 len = subscriptions.length;
        for (uint256 i = 0; i < len; ++i) {
            SubscriptionRecord storage sub = subscriptions[i];
            if (
                sub.active &&
                sub.subscriber == msg.sender &&
                sub.chainId == chainId_ &&
                sub.contractAddress == contract_ &&
                sub.topic0 == topic0_ &&
                sub.topic1 == topic1_ &&
                sub.topic2 == topic2_ &&
                sub.topic3 == topic3_
            ) {
                sub.active = false;
            }
        }
        emit Unsubscribed(msg.sender, chainId_, contract_, topic0_);
    }

    function requestCallback(CallbackVersion version_, bytes memory config_) public override {
        if (version_ != CallbackVersion.V_1_0) revert InvalidCallbackVersion();
        CallbackConfiguration_V_1_0 memory decoded = abi.decode(config_, (CallbackConfiguration_V_1_0));
        callbackQueue.push(decoded);
        emit CallbackRequest(decoded.chainId, msg.sender, decoded.recipient, version_, config_);
    }

    function requestCallbackV_1_0(CallbackConfiguration_V_1_0 memory config_) external override {
        requestCallback(CallbackVersion.V_1_0, abi.encode(config_));
    }

    /// @notice Delivers a normalized `LogRecord` to a reactive contract as `msg.sender == SYSTEM`.
    function deliverLog(address reactiveContract_, IReactive.LogRecord calldata log_) external {
        IReactive(payable(reactiveContract_)).react(log_);
    }

    function getSubscriptionsCount() external view returns (uint256) {
        return subscriptions.length;
    }

    function getActiveSubscriptionsCount(address subscriber_) external view returns (uint256 count) {
        uint256 len = subscriptions.length;
        for (uint256 i = 0; i < len; ++i) {
            if (subscriptions[i].subscriber == subscriber_ && subscriptions[i].active) {
                ++count;
            }
        }
    }

    function getCallbackQueueLength() external view returns (uint256) {
        return callbackQueue.length;
    }

    function getQueuedCallback(uint256 index_) external view returns (CallbackConfiguration_V_1_0 memory) {
        return callbackQueue[index_];
    }
}
