// SPDX-License-Identifier: MIT

pragma solidity >=0.8.20;

/**
 * @title MockDEXPool
 * @notice Uniswap V2-compatible AMM pool on Base Sepolia / Unichain Sepolia that emits `Sync` and `Swap` events.
 */
contract MockDEXPool {
    event Sync(uint112 reserve0, uint112 reserve1);
    event Swap(
        address indexed sender,
        uint256 amount0In,
        uint256 amount1In,
        uint256 amount0Out,
        uint256 amount1Out,
        address indexed to
    );

    uint112 public reserve0;
    uint112 public reserve1;

    constructor(uint112 initialReserve0_, uint112 initialReserve1_) {
        reserve0 = initialReserve0_;
        reserve1 = initialReserve1_;
        emit Sync(reserve0, reserve1);
    }

    function updateReserves(uint112 newReserve0_, uint112 newReserve1_) external {
        reserve0 = newReserve0_;
        reserve1 = newReserve1_;
        emit Sync(newReserve0_, newReserve1_);
    }

    function simulateSwap(
        uint256 amount0In_,
        uint256 amount1In_,
        uint256 amount0Out_,
        uint256 amount1Out_,
        uint112 newReserve0_,
        uint112 newReserve1_
    ) external {
        reserve0 = newReserve0_;
        reserve1 = newReserve1_;
        emit Swap(msg.sender, amount0In_, amount1In_, amount0Out_, amount1Out_, msg.sender);
        emit Sync(newReserve0_, newReserve1_);
    }
}
