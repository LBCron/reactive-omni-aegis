// SPDX-License-Identifier: MIT

pragma solidity >=0.8.20;

/**
 * @title AIThreatSignalEmitter
 * @notice On-chain bridge for the Reactive Omni Aegis neural network risk-scoring engine ("Reactive Meets AI").
 * @dev Receives real-time inference outputs from authorized off-chain neural network agents and emits
 *      normalized `AIOracleSignal` logs that `OmniAegisReactiveGuard` subscribes to on Reactive Omni.
 */
contract AIThreatSignalEmitter {
    enum RecommendedAction {
        NONE,
        DEFENSIVE_REBALANCE,
        EMERGENCY_STOP_LOSS,
        PREEMPTIVE_COLLATERAL_TOPUP,
        VOLATILITY_ARBITRAGE_CAPTURE
    }

    struct ThreatSignal {
        uint256 sequenceId;
        uint256 targetChainId;
        address targetPool;
        uint256 riskScoreBps;           // 0 - 10,000 bps (e.g., 8200 = 82.00% threat probability)
        uint256 predictedVolatilityBps; // Predicted 60s volatility in bps
        int256 predictedReturnBps;      // Signed short-horizon return forecast in bps
        uint8 recommendedAction;        // RecommendedAction enum value
        bytes32 modelCommitHash;        // SHA-256 / Keccak-256 commitment of neural network weights + input window
        uint256 timestamp;
        address reporter;
    }

    error UnauthorizedAgent(address caller);
    error InvalidRiskScore(uint256 riskScoreBps);
    error ZeroTargetPool();

    /// @notice Emitted whenever the AI Risk Engine publishes a new inference result on-chain.
    /// @dev `topic0` = keccak256("AIOracleSignal(uint256,address,uint256,uint256,int256,uint8,bytes32,uint256)")
    event AIOracleSignal(
        uint256 indexed targetChainId,
        address indexed targetPool,
        uint256 riskScoreBps,
        uint256 predictedVolatilityBps,
        int256 predictedReturnBps,
        uint8 recommendedAction,
        bytes32 modelCommitHash,
        uint256 timestamp
    );

    event AgentAuthorizationUpdated(address indexed agent, bool authorized);

    address public immutable owner;
    uint256 public totalSignalsPublished;

    mapping(address => bool) public authorizedAgents;
    mapping(uint256 => mapping(address => ThreatSignal)) public latestSignals;

    constructor(address initialAgent_) {
        owner = msg.sender;
        authorizedAgents[msg.sender] = true;
        if (initialAgent_ != address(0)) {
            authorizedAgents[initialAgent_] = true;
            emit AgentAuthorizationUpdated(initialAgent_, true);
        }
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert UnauthorizedAgent(msg.sender);
        _;
    }

    modifier onlyAuthorizedAgent() {
        if (!authorizedAgents[msg.sender]) revert UnauthorizedAgent(msg.sender);
        _;
    }

    function setAuthorizedAgent(address agent_, bool authorized_) external onlyOwner {
        authorizedAgents[agent_] = authorized_;
        emit AgentAuthorizationUpdated(agent_, authorized_);
    }

    /**
     * @notice Publishes a new neural network threat and volatility inference signal on-chain.
     * @param targetChainId_ Destination chain ID (e.g., 84532 for Base Sepolia, 1301 for Unichain Sepolia).
     * @param targetPool_ Target DEX pool or lending market address.
     * @param riskScoreBps_ Composite neural risk score in basis points (0..10000).
     * @param predictedVolatilityBps_ Short-horizon predicted volatility in basis points.
     * @param predictedReturnBps_ Short-horizon signed price return forecast in basis points.
     * @param recommendedAction_ Recommended mitigation action (RecommendedAction enum).
     * @param modelCommitHash_ Cryptographic commitment to model weights and input feature vector.
     */
    function publishSignal(
        uint256 targetChainId_,
        address targetPool_,
        uint256 riskScoreBps_,
        uint256 predictedVolatilityBps_,
        int256 predictedReturnBps_,
        uint8 recommendedAction_,
        bytes32 modelCommitHash_
    ) external onlyAuthorizedAgent returns (uint256 sequenceId) {
        if (targetPool_ == address(0)) revert ZeroTargetPool();
        if (riskScoreBps_ > 10_000) revert InvalidRiskScore(riskScoreBps_);

        sequenceId = ++totalSignalsPublished;
        uint256 currentTimestamp = block.timestamp;

        latestSignals[targetChainId_][targetPool_] = ThreatSignal({
            sequenceId: sequenceId,
            targetChainId: targetChainId_,
            targetPool: targetPool_,
            riskScoreBps: riskScoreBps_,
            predictedVolatilityBps: predictedVolatilityBps_,
            predictedReturnBps: predictedReturnBps_,
            recommendedAction: recommendedAction_,
            modelCommitHash: modelCommitHash_,
            timestamp: currentTimestamp,
            reporter: msg.sender
        });

        emit AIOracleSignal(
            targetChainId_,
            targetPool_,
            riskScoreBps_,
            predictedVolatilityBps_,
            predictedReturnBps_,
            recommendedAction_,
            modelCommitHash_,
            currentTimestamp
        );
    }

    function getLatestSignal(uint256 targetChainId_, address targetPool_)
        external
        view
        returns (ThreatSignal memory)
    {
        return latestSignals[targetChainId_][targetPool_];
    }
}
