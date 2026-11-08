// SPDX-License-Identifier: MIT

pragma solidity >=0.8.20;

import { IPayable } from "../lib/reactive-lib-omni/src/interfaces/IPayable.sol";
import { OmniAegisReactiveGuard } from "../contracts/OmniAegisReactiveGuard.sol";
import { AegisVaultCallbackReceiver } from "../contracts/AegisVaultCallbackReceiver.sol";
import { AIThreatSignalEmitter } from "../contracts/AIThreatSignalEmitter.sol";
import { MockDEXPool } from "../contracts/mocks/MockDEXPool.sol";
import { MockLendingMarket } from "../contracts/mocks/MockLendingMarket.sol";

interface VmScript {
    function envUint(string calldata name) external view returns (uint256);
    function envOr(string calldata name, address defaultValue) external view returns (address);
    function startBroadcast(uint256 privateKey) external;
    function stopBroadcast() external;
}

/**
 * @title DeployOmniAegis
 * @notice Multi-chain deployment script for Base Sepolia (84532), Unichain Sepolia (1301),
 *         and Reactive Lasna Testnet (5318007) / Reactive Mainnet (1597).
 */
contract DeployOmniAegis {
    VmScript internal constant vm = VmScript(address(uint160(uint256(keccak256("hevm cheat code")))));

    address public constant BASE_SEPOLIA_CALLBACK_PROXY = 0x476F44b11F5C942c58f4c8E3d0300E5710743585;
    address public constant UNICHAIN_SEPOLIA_CALLBACK_PROXY = 0x775c9B990ADe401060B78D0e98684eEf8d2466C1;

    function runOriginAndDestination(address callbackProxy_)
        external
        returns (
            MockDEXPool pool,
            MockLendingMarket lending,
            AIThreatSignalEmitter aiEmitter,
            AegisVaultCallbackReceiver vault
        )
    {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerKey);

        pool = new MockDEXPool(100e18, 250_000e18);
        lending = new MockLendingMarket();
        aiEmitter = new AIThreatSignalEmitter(msg.sender);
        vault = new AegisVaultCallbackReceiver{ value: 0.02 ether }(
            IPayable(payable(callbackProxy_)),
            address(0),
            100 ether,
            250_000 ether,
            60
        );

        vm.stopBroadcast();
    }

    function runReactiveOmni(
        address basePool_,
        address unichainPool_,
        address baseLending_,
        address aiEmitter_,
        address baseVault_,
        address unichainVault_
    ) external returns (OmniAegisReactiveGuard guard) {
        uint256 deployerKey = vm.envUint("REACTIVE_PRIVATE_KEY");
        vm.startBroadcast(deployerKey);

        guard = new OmniAegisReactiveGuard{ value: 0.1 ether }(
            basePool_,
            unichainPool_,
            baseLending_,
            aiEmitter_,
            baseVault_,
            unichainVault_,
            true
        );

        vm.stopBroadcast();
    }
}
