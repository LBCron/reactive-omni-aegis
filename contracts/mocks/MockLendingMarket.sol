// SPDX-License-Identifier: MIT

pragma solidity >=0.8.20;

/**
 * @title MockLendingMarket
 * @notice Lending market on Base Sepolia / Unichain Sepolia emitting `HealthFactorUpdated` events.
 */
contract MockLendingMarket {
    event HealthFactorUpdated(
        address indexed user,
        uint256 indexed positionId,
        uint256 healthFactorWad,
        uint256 collateralUsd,
        uint256 debtUsd
    );

    function emitHealthFactorUpdate(
        address user_,
        uint256 positionId_,
        uint256 healthFactorWad_,
        uint256 collateralUsd_,
        uint256 debtUsd_
    ) external {
        emit HealthFactorUpdated(user_, positionId_, healthFactorWad_, collateralUsd_, debtUsd_);
    }
}
