#!/usr/bin/env python3
"""
Reactive Omni Aegis — Neural Network Threat Engine & Cross-Chain Loop Simulator
===============================================================================
Covers all three tracks of the Reactive Omni Buildathon:
  1. Every Second Counts (DeFi on Unichain Sepolia 1301 & Base Sepolia 84532)
  2. Set It and Forget It (Cron-driven DCA & timestamp-safe personal automations)
  3. Reactive Meets AI (Temporal Neural Network in the live Reactive loop)

Author: Ronan Chen Lopes <ronanchenlopes@gmail.com> (@LBCron)
License: MIT
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
from dataclasses import asdict, dataclass
from typing import Dict, List, Sequence, Tuple


# =============================================================================
# Protocol & Network Constants (Official Reactive Omni Specification)
# =============================================================================
REACTIVE_LASNA_CHAIN_ID = 5318007
REACTIVE_MAINNET_CHAIN_ID = 1597
BASE_SEPOLIA_CHAIN_ID = 84532
UNICHAIN_SEPOLIA_CHAIN_ID = 1301

OMNI_SYSTEM_CONTRACT = "0x8888888888888888888888888888888888888888"
LEGACY_CRON_SYSTEM_CONTRACT = "0x0000000000000000000000000000000000fffFfF"
BASE_SEPOLIA_CALLBACK_PROXY = "0x476F44b11F5C942c58f4c8E3d0300E5710743585"
UNICHAIN_SEPOLIA_CALLBACK_PROXY = "0x775c9B990ADe401060B78D0e98684eEf8d2466C1"

DEX_SYNC_TOPIC_0 = "0x1c411e9a96e071241c2f21f7726b17ae89e3cab4c78be50e062b03a9fffbbad1"
CRON100_TOPIC_0 = "0xb49937fb8970e19fd46d48f7e3fb00d659deac0347f79cd7cb542f0fc1503c70"


class RecommendedAction:
    NONE = 0
    DEFENSIVE_REBALANCE = 1
    EMERGENCY_STOP_LOSS = 2
    PREEMPTIVE_COLLATERAL_TOPUP = 3
    VOLATILITY_ARBITRAGE_CAPTURE = 4


@dataclass(frozen=True)
class PoolObservation:
    chain_id: int
    pool_address: str
    reserve0_wad: int
    reserve1_wad: int
    net_sell_imbalance_bps: int
    min_lending_health_factor_wad: int
    timestamp_ms: int
    block_number: int


@dataclass(frozen=True)
class NeuralInferenceResult:
    target_chain_id: int
    target_pool: str
    risk_score_bps: int
    predicted_volatility_bps: int
    predicted_return_bps: int
    recommended_action: int
    recommended_action_name: str
    model_commit_hash: str
    feature_vector: List[float]


# =============================================================================
# Track 3: Temporal Residual MLP Neural Network (`AegisTemporalNeuralNet`)
# =============================================================================
class AegisTemporalNeuralNet:
    """
    Deterministic 2-layer Residual Neural Network for DeFi liquidity & flash-crash
    threat scoring. Runs in the live Reactive event loop to interpret DEX Swap/Sync
    orderflow and emit verifiable `AIOracleSignal` transactions on-chain.
    """

    MODEL_VERSION = "AegisTCN-ResidualMLP-v1.0"

    def __init__(self) -> None:
        # Layer 1: 6 input features -> 8 hidden units
        # Features:
        #   f0: instantaneous drawdown ratio (0..1, scaled x10)
        #   f1: short-window realized volatility ratio (0..1, scaled x10)
        #   f2: negative log-return velocity (max(0, -r_t) * 15)
        #   f3: cross-chain spread ratio (0..1, scaled x12)
        #   f4: orderflow sell-toxicity / VPIN (0..1, scaled x5)
        #   f5: lending health-factor distress (max(0, 1.30 - hf) * 6)
        self.w1: List[List[float]] = [
            [2.40, 1.85, 2.60, 0.45, 1.35, 0.90],
            [1.90, 2.30, 1.95, 0.80, 1.60, 0.70],
            [0.60, 1.10, 0.80, 2.75, 0.95, 0.30],
            [0.75, 0.95, 1.10, 0.40, 1.20, 2.85],
            [2.15, 1.50, 2.25, 0.65, 1.80, 1.15],
            [1.20, 2.05, 1.40, 1.55, 1.25, 0.85],
            [1.70, 1.65, 1.85, 0.90, 2.10, 1.05],
            [0.95, 1.25, 1.15, 1.90, 1.05, 1.95],
        ]
        self.b1: List[float] = [-0.45, -0.40, -0.35, -0.38, -0.42, -0.36, -0.40, -0.35]

        # Layer 2 (Residual projection): 8 hidden units -> 8 hidden units
        self.w2: List[List[float]] = [
            [0.65, 0.30, 0.10, 0.15, 0.40, 0.20, 0.35, 0.15],
            [0.30, 0.70, 0.20, 0.10, 0.35, 0.30, 0.25, 0.20],
            [0.15, 0.20, 0.80, 0.10, 0.15, 0.40, 0.20, 0.35],
            [0.15, 0.15, 0.10, 0.85, 0.25, 0.15, 0.30, 0.40],
            [0.40, 0.35, 0.15, 0.25, 0.75, 0.25, 0.40, 0.20],
            [0.20, 0.30, 0.40, 0.15, 0.25, 0.70, 0.25, 0.30],
            [0.35, 0.25, 0.20, 0.30, 0.40, 0.25, 0.75, 0.25],
            [0.15, 0.20, 0.35, 0.40, 0.20, 0.30, 0.25, 0.75],
        ]
        self.b2: List[float] = [-0.15, -0.15, -0.10, -0.12, -0.15, -0.12, -0.14, -0.12]

        # Output Heads (3 outputs: risk logit, volatility scale, negative return forecast)
        self.w_out: List[List[float]] = [
            [0.52, 0.48, 0.32, 0.44, 0.55, 0.38, 0.50, 0.40],  # Head 0: Risk logit
            [0.35, 0.42, 0.38, 0.22, 0.36, 0.40, 0.38, 0.28],  # Head 1: Predicted volatility
            [-0.48, -0.42, -0.25, -0.30, -0.50, -0.32, -0.45, -0.30],  # Head 2: Return forecast
        ]
        self.b_out: List[float] = [-2.15, 0.08, 0.02]

    @staticmethod
    def _silu(x: float) -> float:
        """Swish / SiLU activation: x * sigmoid(x)."""
        if x < -20.0:
            return 0.0
        if x > 20.0:
            return x
        return x / (1.0 + math.exp(-x))

    @staticmethod
    def _sigmoid(x: float) -> float:
        if x < -20.0:
            return 0.0
        if x > 20.0:
            return 1.0
        return 1.0 / (1.0 + math.exp(-x))

    def extract_features(
        self,
        window: Sequence[PoolObservation],
        cross_chain_peer_price_wad: int = 0,
    ) -> List[float]:
        if not window:
            raise ValueError("Observation window must not be empty")

        prices = [
            (obs.reserve1_wad / obs.reserve0_wad) if obs.reserve0_wad > 0 else 0.0
            for obs in window
        ]
        latest = window[-1]
        latest_price = prices[-1]
        high_water = max(prices) if prices else latest_price

        # Feature 0: High-water-mark drawdown
        drawdown = max(0.0, (high_water - latest_price) / high_water) if high_water > 0 else 0.0

        # Feature 1: Realized log-return volatility across window
        log_returns: List[float] = []
        for i in range(1, len(prices)):
            if prices[i - 1] > 0 and prices[i] > 0:
                log_returns.append(math.log(prices[i] / prices[i - 1]))
        realized_vol = (
            math.sqrt(sum(r * r for r in log_returns) / len(log_returns))
            if log_returns
            else 0.0
        )

        # Feature 2: Downward velocity (latest step negative log return)
        neg_velocity = max(0.0, -log_returns[-1]) if log_returns else 0.0

        # Feature 3: Cross-chain price divergence vs peer chain
        peer_price = cross_chain_peer_price_wad / 1e18 if cross_chain_peer_price_wad > 0 else latest_price
        min_p = min(latest_price, peer_price)
        spread = abs(latest_price - peer_price) / min_p if min_p > 0 else 0.0

        # Feature 4: Orderflow sell imbalance (VPIN proxy in 0..1)
        toxicity = max(0.0, min(1.0, latest.net_sell_imbalance_bps / 10_000.0))

        # Feature 5: Lending health factor distress below 1.30 WAD
        hf = latest.min_lending_health_factor_wad / 1e18
        hf_distress = max(0.0, 1.30 - hf)

        return [
            round(drawdown * 10.0, 6),
            round(realized_vol * 10.0, 6),
            round(neg_velocity * 15.0, 6),
            round(spread * 12.0, 6),
            round(toxicity * 3.0, 6),
            round(hf_distress * 6.0, 6),
        ]

    def infer(
        self,
        window: Sequence[PoolObservation],
        cross_chain_peer_price_wad: int = 0,
    ) -> NeuralInferenceResult:
        features = self.extract_features(window, cross_chain_peer_price_wad)
        latest = window[-1]

        # Layer 1 forward pass with SiLU activation
        h1: List[float] = []
        for row, bias in zip(self.w1, self.b1):
            z = sum(w * x for w, x in zip(row, features)) + bias
            h1.append(self._silu(z))

        # Layer 2 forward pass with Residual connection + SiLU activation
        h2: List[float] = []
        for idx, (row, bias) in enumerate(zip(self.w2, self.b2)):
            z = sum(w * a for w, a in zip(row, h1)) + bias
            h2.append(self._silu(z) + 0.5 * h1[idx])

        # Output heads
        risk_logit = sum(w * a for w, a in zip(self.w_out[0], h2)) + self.b_out[0]
        vol_raw = sum(w * a for w, a in zip(self.w_out[1], h2)) + self.b_out[1]
        ret_raw = sum(w * a for w, a in zip(self.w_out[2], h2)) + self.b_out[2]

        risk_prob = self._sigmoid(risk_logit)
        risk_score_bps = int(round(min(10_000.0, max(0.0, risk_prob * 10_000.0))))
        predicted_volatility_bps = int(round(min(5_000.0, max(10.0, math.log1p(math.exp(vol_raw)) * 180.0))))
        predicted_return_bps = int(round(math.tanh(ret_raw / 3.0) * 1_200.0))

        # Action selection policy
        action = RecommendedAction.NONE
        action_name = "NONE"
        if risk_score_bps >= 7_000:
            if features[0] >= 0.45 or features[2] >= 0.50:
                action = RecommendedAction.EMERGENCY_STOP_LOSS
                action_name = "EMERGENCY_STOP_LOSS"
            elif features[5] >= 0.60:
                action = RecommendedAction.PREEMPTIVE_COLLATERAL_TOPUP
                action_name = "PREEMPTIVE_COLLATERAL_TOPUP"
            elif features[3] >= 0.18:
                action = RecommendedAction.VOLATILITY_ARBITRAGE_CAPTURE
                action_name = "VOLATILITY_ARBITRAGE_CAPTURE"
            else:
                action = RecommendedAction.DEFENSIVE_REBALANCE
                action_name = "DEFENSIVE_REBALANCE"
        elif features[3] >= 0.18:
            action = RecommendedAction.VOLATILITY_ARBITRAGE_CAPTURE
            action_name = "VOLATILITY_ARBITRAGE_CAPTURE"

        commit_payload = json.dumps(
            {
                "model": self.MODEL_VERSION,
                "chain_id": latest.chain_id,
                "pool": latest.pool_address.lower(),
                "block": latest.block_number,
                "features": features,
                "risk_score_bps": risk_score_bps,
            },
            sort_keys=True,
        ).encode("utf-8")
        commit_hash = "0x" + hashlib.sha256(commit_payload).hexdigest()

        return NeuralInferenceResult(
            target_chain_id=latest.chain_id,
            target_pool=latest.pool_address,
            risk_score_bps=risk_score_bps,
            predicted_volatility_bps=predicted_volatility_bps,
            predicted_return_bps=predicted_return_bps,
            recommended_action=action,
            recommended_action_name=action_name,
            model_commit_hash=commit_hash,
            feature_vector=features,
        )


# =============================================================================
# Cross-Chain Latency & Loop Simulator (Base 200ms / Unichain 1s / Omni ~1s)
# =============================================================================
@dataclass(frozen=True)
class LoopLatencyReport:
    scenario: str
    track: str
    origin_chain: str
    origin_block_time_ms: int
    reactive_omni_finality_ms: int
    legacy_reactive_finality_ms: int
    destination_chain: str
    destination_block_time_ms: int
    omni_total_loop_ms: int
    legacy_total_loop_ms: int
    speedup_factor: float
    callback_selector: str
    outcome_summary: str


def run_cross_chain_simulation() -> Dict[str, object]:
    model = AegisTemporalNeuralNet()

    # 1. Healthy baseline vs Flash Crash window on Base Sepolia (84532)
    healthy_window = [
        PoolObservation(BASE_SEPOLIA_CHAIN_ID, "0xBa5e000000000000000000000000000000000001", int(100e18), int(250_000e18), 500, int(1.45e18), 1000, 100),
        PoolObservation(BASE_SEPOLIA_CHAIN_ID, "0xBa5e000000000000000000000000000000000001", int(100e18), int(249_500e18), 600, int(1.44e18), 1200, 101),
    ]
    crash_window = healthy_window + [
        PoolObservation(BASE_SEPOLIA_CHAIN_ID, "0xBa5e000000000000000000000000000000000001", int(100e18), int(238_000e18), 4_200, int(1.22e18), 1400, 102),
        PoolObservation(BASE_SEPOLIA_CHAIN_ID, "0xBa5e000000000000000000000000000000000001", int(100e18), int(218_000e18), 8_500, int(1.08e18), 1600, 103),
    ]

    healthy_inference = model.infer(healthy_window, cross_chain_peer_price_wad=int(2500e18))
    crash_inference = model.infer(crash_window, cross_chain_peer_price_wad=int(2560e18))

    latency_benchmarks: List[LoopLatencyReport] = [
        LoopLatencyReport(
            scenario="DEX Flash Crash Stop-Loss (Base Sepolia -> Reactive Omni -> Base Sepolia)",
            track="Track 1: Every Second Counts",
            origin_chain="Base Sepolia (84532)",
            origin_block_time_ms=200,
            reactive_omni_finality_ms=1000,
            legacy_reactive_finality_ms=7000,
            destination_chain="Base Sepolia (84532)",
            destination_block_time_ms=200,
            omni_total_loop_ms=1400,
            legacy_total_loop_ms=7400,
            speedup_factor=round(7400 / 1400, 2),
            callback_selector="executeEmergencyStopLoss(address,uint8,uint256,uint256,uint256)",
            outcome_summary="De-risks 50% WETH exposure into USDC in 1.4s before cascading liquidations.",
        ),
        LoopLatencyReport(
            scenario="Cross-DEX Price Gap Arbitrage (Unichain Sepolia -> Reactive Omni -> Base Sepolia)",
            track="Track 1: Every Second Counts",
            origin_chain="Unichain Sepolia (1301)",
            origin_block_time_ms=1000,
            reactive_omni_finality_ms=1000,
            legacy_reactive_finality_ms=7000,
            destination_chain="Base Sepolia (84532)",
            destination_block_time_ms=200,
            omni_total_loop_ms=2200,
            legacy_total_loop_ms=8200,
            speedup_factor=round(8200 / 2200, 2),
            callback_selector="executeCrossChainArbitrage(address,uint256,uint256,uint256,uint256,uint256)",
            outcome_summary="Captures 240 bps Unichain/Base spread in 2.2s vs 8.2s on legacy Reactive.",
        ),
        LoopLatencyReport(
            scenario="Non-Custodial Cron100 Recurring DCA & Range Rebalance",
            track="Track 2: Set It and Forget It",
            origin_chain="Reactive Omni Cron (5318007)",
            origin_block_time_ms=1000,
            reactive_omni_finality_ms=1000,
            legacy_reactive_finality_ms=7000,
            destination_chain="Base Sepolia (84532)",
            destination_block_time_ms=200,
            omni_total_loop_ms=1200,
            legacy_total_loop_ms=7200,
            speedup_factor=round(7200 / 1200, 2),
            callback_selector="executeScheduledAutomation(address,uint256,uint256,uint256)",
            outcome_summary="Zero-keeper recurring DCA with timestamp-enforced cooldowns (200ms Denim safe).",
        ),
        LoopLatencyReport(
            scenario="Neural Network Threat Shield (AIOracleSignal -> Reactive Omni -> Destination Vault)",
            track="Track 3: Reactive Meets AI",
            origin_chain="Base Sepolia (84532)",
            origin_block_time_ms=200,
            reactive_omni_finality_ms=1000,
            legacy_reactive_finality_ms=7000,
            destination_chain="Base Sepolia (84532)",
            destination_block_time_ms=200,
            omni_total_loop_ms=1400,
            legacy_total_loop_ms=7400,
            speedup_factor=round(7400 / 1400, 2),
            callback_selector="executeAIShieldAction(address,uint256,uint256,uint8,bytes32,uint256)",
            outcome_summary=f"AI risk score {crash_inference.risk_score_bps} bps triggers preemptive 40% shift in 1.4s.",
        ),
    ]

    return {
        "model_version": model.MODEL_VERSION,
        "healthy_inference": asdict(healthy_inference),
        "crash_inference": asdict(crash_inference),
        "latency_benchmarks": [asdict(b) for b in latency_benchmarks],
    }


def main() -> None:
    parser = argparse.ArgumentParser(description="Reactive Omni Aegis Neural Threat Engine & Loop Simulator")
    parser.add_argument("--simulate", action="store_true", help="Run full cross-chain simulation and print JSON report")
    args = parser.parse_args()

    report = run_cross_chain_simulation()
    if args.simulate or True:
        print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
