import subprocess
import unittest
from pathlib import Path

from ai_agent.reactive_ai_engine import (
    AegisTemporalNeuralNet,
     BASE_SEPOLIA_CHAIN_ID,
    PoolObservation,
    RecommendedAction,
    UNICHAIN_SEPOLIA_CHAIN_ID,
    run_cross_chain_simulation,
)


class TestAegisNeuralEngineAndContracts(unittest.TestCase):
    def setUp(self) -> None:
        self.model = AegisTemporalNeuralNet()
        self.pool_addr = "0xBa5e000000000000000000000000000000000001"

    def test_01_healthy_pool_produces_low_risk_score(self) -> None:
        window = [
            PoolObservation(BASE_SEPOLIA_CHAIN_ID, self.pool_addr, int(100e18), int(250_000e18), 300, int(1.50e18), 1000, 10),
            PoolObservation(BASE_SEPOLIA_CHAIN_ID, self.pool_addr, int(100e18), int(250_100e18), 250, int(1.51e18), 1200, 11),
        ]
        res = self.model.infer(window, cross_chain_peer_price_wad=int(2501e18))
        self.assertLess(res.risk_score_bps, 3_500)
        self.assertEqual(res.recommended_action, RecommendedAction.NONE)
        self.assertTrue(res.model_commit_hash.startswith("0x"))
        self.assertEqual(len(res.model_commit_hash), 66)

    def test_02_flash_crash_triggers_high_risk_and_emergency_stop_loss(self) -> None:
        window = [
            PoolObservation(BASE_SEPOLIA_CHAIN_ID, self.pool_addr, int(100e18), int(250_000e18), 400, int(1.45e18), 1000, 10),
            PoolObservation(BASE_SEPOLIA_CHAIN_ID, self.pool_addr, int(100e18), int(235_000e18), 5_000, int(1.20e18), 1200, 11),
            PoolObservation(BASE_SEPOLIA_CHAIN_ID, self.pool_addr, int(100e18), int(215_000e18), 9_000, int(1.05e18), 1400, 12),
        ]
        res = self.model.infer(window, cross_chain_peer_price_wad=int(2500e18))
        self.assertGreaterEqual(res.risk_score_bps, 7_000)
        self.assertEqual(res.recommended_action, RecommendedAction.EMERGENCY_STOP_LOSS)
        self.assertLess(res.predicted_return_bps, 0)

    def test_03_lending_distress_recommends_collateral_topup(self) -> None:
        window = [
            PoolObservation(BASE_SEPOLIA_CHAIN_ID, self.pool_addr, int(100e18), int(250_000e18), 2_000, int(1.25e18), 1000, 10),
            PoolObservation(BASE_SEPOLIA_CHAIN_ID, self.pool_addr, int(100e18), int(245_000e18), 6_500, int(1.02e18), 1200, 11),
        ]
        res = self.model.infer(window, cross_chain_peer_price_wad=int(2450e18))
        self.assertGreaterEqual(res.risk_score_bps, 7_000)
        self.assertEqual(res.recommended_action, RecommendedAction.PREEMPTIVE_COLLATERAL_TOPUP)

    def test_04_cross_chain_spread_recommends_volatility_arbitrage(self) -> None:
        window = [
            PoolObservation(UNICHAIN_SEPOLIA_CHAIN_ID, self.pool_addr, int(100e18), int(250_000e18), 500, int(1.50e18), 1000, 20),
            PoolObservation(UNICHAIN_SEPOLIA_CHAIN_ID, self.pool_addr, int(100e18), int(256_000e18), 600, int(1.50e18), 2000, 21),
        ]
        res = self.model.infer(window, cross_chain_peer_price_wad=int(2500e18))
        self.assertEqual(res.recommended_action, RecommendedAction.VOLATILITY_ARBITRAGE_CAPTURE)

    def test_05_cross_chain_simulation_latency_benchmarks(self) -> None:
        report = run_cross_chain_simulation()
        benchmarks = report["latency_benchmarks"]
        self.assertEqual(len(benchmarks), 4)
        for b in benchmarks:
            self.assertLess(b["omni_total_loop_ms"], 2_500)
            self.assertGreater(b["speedup_factor"], 3.5)

    def test_06_solidity_contracts_compile_cleanly_with_solcjs(self) -> None:
        root = Path(__file__).resolve().parent.parent
        solcjs = root / "node_modules" / ".bin" / "solcjs"
        if not solcjs.exists():
            self.skipTest("solcjs not installed yet")

        cmd = [
            str(solcjs),
            "--optimize",
            "--bin",
            "--abi",
            "--base-path",
            str(root),
            "--include-path",
            str(root / "lib"),
            "-o",
            str(root / "out" / "solc"),
            str(root / "contracts" / "OmniAegisReactiveGuard.sol"),
            str(root / "contracts" / "AegisVaultCallbackReceiver.sol"),
            str(root / "contracts" / "AIThreatSignalEmitter.sol"),
            str(root / "contracts" / "mocks" / "MockOmniSystemContract.sol"),
            str(root / "contracts" / "mocks" / "MockCallbackProxy.sol"),
            str(root / "contracts" / "mocks" / "MockDEXPool.sol"),
            str(root / "contracts" / "mocks" / "MockLendingMarket.sol"),
            str(root / "test" / "OmniAegis.t.sol"),
        ]
        proc = subprocess.run(cmd, cwd=str(root), capture_output=True, text=True, check=False)
        self.assertEqual(proc.returncode, 0, f"Solidity compilation failed:\n{proc.stderr}\n{proc.stdout}")


if __name__ == "__main__":
    unittest.main()
