// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IWorldID} from "./interfaces/IWorldID.sol";
import {ByteHasher} from "./helpers/ByteHasher.sol";

enum WillStatus {
    None,
    Active,
    ClaimPending,
    Claimed,
    Cancelled
}

struct Will {
    address owner;
    uint256 ownerNullifier;
    uint256 heirNullifier;
    uint256 amount;
    uint64 lastCheckIn;
    uint64 checkInInterval;
    uint64 gracePeriod;
    uint64 challengePeriod;
    uint64 claimInitiatedAt;
    address payoutAddress;
    WillStatus status;
}

contract CryptoWill {
    using ByteHasher for bytes;

    error WillAlreadyActive();
    error ZeroAmount();
    error ZeroPeriod();
    error InvalidHeirNullifier();
    error HeirIsOwner();
    error NotOwner();
    error NullifierMismatch();
    error InvalidStatus();
    error ChallengeWindowClosed();
    error ChallengeWindowOpen();
    error NotClaimableYet();
    error ZeroPayoutAddress();
    error TransferFailed();
    error SameAction();

    event WillCreated(
        uint256 indexed willId,
        address indexed owner,
        uint256 amount,
        uint256 heirNullifier,
        uint64 checkInInterval,
        uint64 gracePeriod,
        uint64 challengePeriod
    );
    event CheckedIn(uint256 indexed willId, uint64 timestamp);
    event ClaimChallenged(uint256 indexed willId, uint64 timestamp);
    event ClaimInitiated(uint256 indexed willId, address indexed payoutAddress, uint64 timestamp);
    event ClaimFinalized(uint256 indexed willId, address indexed payoutAddress, uint256 amount);
    event WillCancelled(uint256 indexed willId, uint256 amount);

    /// @dev Orb-verified group.
    uint256 internal constant GROUP_ID = 1;

    /// @dev World ID nullifiers are field elements; anything >= this can never match a real proof.
    uint256 internal constant SNARK_SCALAR_FIELD =
        21888242871839275222246405745257275088548364400416034343698204186575808495617;

    /// @dev Operation tags mixed into owner signals so a proof for one operation can't be replayed as another.
    uint8 internal constant OP_CHECK_IN = 1;
    uint8 internal constant OP_CANCEL = 2;

    IWorldID public immutable worldId;
    uint256 public immutable EXTERNAL_NULLIFIER_ALIVE;
    uint256 public immutable EXTERNAL_NULLIFIER_CLAIM;

    mapping(uint256 => Will) public wills; // willId => Will
    mapping(address => uint256) public activeWillOf; // owner => willId（0 表示無進行中）
    uint256 public nextWillId = 1;

    constructor(IWorldID _worldId, string memory _appId, string memory _actionAlive, string memory _actionClaim) {
        require(keccak256(bytes(_actionAlive)) != keccak256(bytes(_actionClaim)), SameAction());
        worldId = _worldId;
        uint256 appIdHash = abi.encodePacked(_appId).hashToField();
        EXTERNAL_NULLIFIER_ALIVE = abi.encodePacked(appIdHash, _actionAlive).hashToField();
        EXTERNAL_NULLIFIER_CLAIM = abi.encodePacked(appIdHash, _actionClaim).hashToField();
    }

    // ---------------------------------------------------------------------
    // Owner
    // ---------------------------------------------------------------------

    /// @notice Lock msg.value into a new will. Proof signal must be abi.encodePacked(msg.sender).
    function createWill(
        uint256 root,
        uint256 nullifierHash,
        uint256[8] calldata proof,
        uint256 heirNullifier,
        uint64 checkInInterval,
        uint64 gracePeriod,
        uint64 challengePeriod
    ) external payable returns (uint256 willId) {
        require(activeWillOf[msg.sender] == 0, WillAlreadyActive());
        require(msg.value > 0, ZeroAmount());
        require(checkInInterval > 0 && gracePeriod > 0 && challengePeriod > 0, ZeroPeriod());
        require(heirNullifier != 0 && heirNullifier < SNARK_SCALAR_FIELD, InvalidHeirNullifier());
        require(heirNullifier != nullifierHash, HeirIsOwner());

        worldId.verifyProof(
            root, GROUP_ID, abi.encodePacked(msg.sender).hashToField(), nullifierHash, EXTERNAL_NULLIFIER_ALIVE, proof
        );

        willId = nextWillId++;
        wills[willId] = Will({
            owner: msg.sender,
            ownerNullifier: nullifierHash,
            heirNullifier: heirNullifier,
            amount: msg.value,
            lastCheckIn: uint64(block.timestamp),
            checkInInterval: checkInInterval,
            gracePeriod: gracePeriod,
            challengePeriod: challengePeriod,
            claimInitiatedAt: 0,
            payoutAddress: address(0),
            status: WillStatus.Active
        });
        activeWillOf[msg.sender] = willId;

        emit WillCreated(willId, msg.sender, msg.value, heirNullifier, checkInInterval, gracePeriod, challengePeriod);
    }

    /// @notice Prove liveness. While a claim is pending (and its challenge window is open) this also cancels the claim.
    /// Proof signal must be checkInSignal(willId).
    function checkIn(uint256 willId, uint256 root, uint256 nullifierHash, uint256[8] calldata proof) external {
        Will storage w = wills[willId];
        _requireOwnerProof(w, willId, OP_CHECK_IN, root, nullifierHash, proof);

        bool challenged = w.status == WillStatus.ClaimPending;
        w.lastCheckIn = uint64(block.timestamp);
        if (challenged) {
            w.status = WillStatus.Active;
            w.claimInitiatedAt = 0;
            w.payoutAddress = address(0);
            emit ClaimChallenged(willId, uint64(block.timestamp));
        }
        emit CheckedIn(willId, uint64(block.timestamp));
    }

    /// @notice Withdraw everything back to the owner. Proof signal must be cancelSignal(willId).
    function cancelWill(uint256 willId, uint256 root, uint256 nullifierHash, uint256[8] calldata proof) external {
        Will storage w = wills[willId];
        _requireOwnerProof(w, willId, OP_CANCEL, root, nullifierHash, proof);

        uint256 amount = w.amount;
        w.amount = 0;
        w.status = WillStatus.Cancelled;
        delete activeWillOf[w.owner];

        emit WillCancelled(willId, amount);
        _send(w.owner, amount);
    }

    // ---------------------------------------------------------------------
    // Heir
    // ---------------------------------------------------------------------

    /// @notice Start the challenge period after the owner missed the check-in deadline.
    /// Callable by anyone holding the heir's proof; signal must be claimSignal(willId, payoutAddress)
    /// so a front-runner can't swap in their own payout address.
    function initiateClaim(
        uint256 willId,
        address payoutAddress,
        uint256 root,
        uint256 nullifierHash,
        uint256[8] calldata proof
    ) external {
        Will storage w = wills[willId];
        require(w.status == WillStatus.Active, InvalidStatus());
        require(block.timestamp >= claimableAt(willId), NotClaimableYet());
        require(payoutAddress != address(0), ZeroPayoutAddress());
        require(nullifierHash == w.heirNullifier, NullifierMismatch());

        worldId.verifyProof(
            root,
            GROUP_ID,
            claimSignal(willId, payoutAddress).hashToField(),
            nullifierHash,
            EXTERNAL_NULLIFIER_CLAIM,
            proof
        );

        w.status = WillStatus.ClaimPending;
        w.claimInitiatedAt = uint64(block.timestamp);
        w.payoutAddress = payoutAddress;

        emit ClaimInitiated(willId, payoutAddress, uint64(block.timestamp));
    }

    /// @notice Pay out to the heir once the challenge period has passed. Callable by anyone.
    function finalizeClaim(uint256 willId) external {
        Will storage w = wills[willId];
        require(w.status == WillStatus.ClaimPending, InvalidStatus());
        require(block.timestamp >= _challengeEnd(w), ChallengeWindowOpen());

        uint256 amount = w.amount;
        address payoutAddress = w.payoutAddress;
        w.amount = 0;
        w.status = WillStatus.Claimed;
        delete activeWillOf[w.owner];

        emit ClaimFinalized(willId, payoutAddress, amount);
        _send(payoutAddress, amount);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    /// @notice Earliest timestamp at which the heir may initiate a claim.
    function claimableAt(uint256 willId) public view returns (uint256) {
        Will storage w = wills[willId];
        // uint256 math: user-supplied uint64 periods must not be able to overflow and brick the claim path.
        return uint256(w.lastCheckIn) + w.checkInInterval + w.gracePeriod;
    }

    /// @notice Raw signal (pre-hashToField) the owner must use for checkIn.
    function checkInSignal(uint256 willId) external view returns (bytes memory) {
        return _ownerSignal(wills[willId], willId, OP_CHECK_IN);
    }

    /// @notice Raw signal (pre-hashToField) the owner must use for cancelWill.
    function cancelSignal(uint256 willId) external view returns (bytes memory) {
        return _ownerSignal(wills[willId], willId, OP_CANCEL);
    }

    /// @notice Raw signal (pre-hashToField) the heir must use for initiateClaim.
    function claimSignal(uint256 willId, address payoutAddress) public pure returns (bytes memory) {
        return abi.encodePacked(willId, payoutAddress);
    }

    // ---------------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------------

    /// @dev Shared gate for checkIn / cancelWill: caller is owner, will is live, and a fresh ALIVE proof.
    function _requireOwnerProof(
        Will storage w,
        uint256 willId,
        uint8 op,
        uint256 root,
        uint256 nullifierHash,
        uint256[8] calldata proof
    ) internal view {
        require(w.owner == msg.sender, NotOwner());
        if (w.status == WillStatus.ClaimPending) {
            require(block.timestamp < _challengeEnd(w), ChallengeWindowClosed());
        } else {
            require(w.status == WillStatus.Active, InvalidStatus());
        }
        require(nullifierHash == w.ownerNullifier, NullifierMismatch());

        worldId.verifyProof(
            root, GROUP_ID, _ownerSignal(w, willId, op).hashToField(), nullifierHash, EXTERNAL_NULLIFIER_ALIVE, proof
        );
    }

    /// @dev lastCheckIn acts as a nonce: every successful check-in invalidates all previously published proofs.
    function _ownerSignal(Will storage w, uint256 willId, uint8 op) internal view returns (bytes memory) {
        return abi.encodePacked(w.owner, willId, w.lastCheckIn, op);
    }

    function _challengeEnd(Will storage w) internal view returns (uint256) {
        return uint256(w.claimInitiatedAt) + w.challengePeriod;
    }

    function _send(address to, uint256 amount) internal {
        (bool ok,) = to.call{value: amount}("");
        require(ok, TransferFailed());
    }
}
