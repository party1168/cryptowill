// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IWorldID} from "./interfaces/IWorldID.sol";
import {ByteHasher} from "./helpers/ByteHasher.sol";

/// @dev Stored states only. "Overdue" is never stored; see WillPhase / currentPhase.
enum WillStatus {
    None,
    Active,
    ClaimPending,
    Claimed,
    Cancelled
}

/// @dev Phase derived on read from the stored status + timestamps.
enum WillPhase {
    None,
    Active, // before lastCheckIn + checkInInterval
    Grace, // owner can still check in, heir can't initiate yet
    Claimable, // heir may initiateClaim; owner can still check in
    Challenge, // claim pending, owner can still check in / cancel
    Finalizable, // challenge period over, anyone may finalizeClaim
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

    /// @dev Orb-verified group (v3 legacy on-chain path).
    uint256 internal constant GROUP_ID = 1;

    /// @dev World ID nullifiers are field elements; anything >= this can never match a real proof.
    uint256 internal constant SNARK_SCALAR_FIELD =
        21888242871839275222246405745257275088548364400416034343698204186575808495617;

    IWorldID public immutable worldId;
    /// @dev From action "cryptowill-alive-check": createWill, checkIn, cancel.
    uint256 public immutable aliveCheckExternalNullifier;
    /// @dev From action "cryptowill-heir-claim": initiateClaim.
    uint256 public immutable heirClaimExternalNullifier;

    mapping(uint256 => Will) public wills; // willId => Will
    mapping(address => uint256) public activeWillOf; // owner => willId（0 表示無進行中）
    uint256 public nextWillId = 1;
    /// @dev Lookup index only, so an heir (known only by nullifier, never by address) can find their wills.
    /// Not used for claim enforcement: one-time claim is enforced per will by the state machine (TD-007).
    mapping(uint256 => uint256[]) internal _willIdsOfHeir; // heirNullifier => willIds

    constructor(IWorldID _worldId, string memory _appId, string memory _aliveAction, string memory _claimAction) {
        require(keccak256(bytes(_aliveAction)) != keccak256(bytes(_claimAction)), SameAction());
        worldId = _worldId;
        uint256 appIdHash = abi.encodePacked(_appId).hashToField();
        aliveCheckExternalNullifier = abi.encodePacked(appIdHash, _aliveAction).hashToField();
        heirClaimExternalNullifier = abi.encodePacked(appIdHash, _claimAction).hashToField();
    }

    // ---------------------------------------------------------------------
    // Owner — proof signal is always the owner address (msg.sender)
    // ---------------------------------------------------------------------

    /// @notice Lock msg.value into a new will. heirNullifier is not verified here (TD-008).
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

        _verifyAlive(root, nullifierHash, proof);

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
        _willIdsOfHeir[heirNullifier].push(willId);

        emit WillCreated(willId, msg.sender, msg.value, heirNullifier, checkInInterval, gracePeriod, challengePeriod);
    }

    /// @notice Prove liveness. While a claim is pending (and its challenge window is open) this also voids the claim.
    function checkIn(uint256 willId, uint256 root, uint256 nullifierHash, uint256[8] calldata proof) external {
        Will storage w = wills[willId];
        _requireOwnerProof(w, root, nullifierHash, proof);

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

    /// @notice Withdraw everything back to the owner.
    function cancel(uint256 willId, uint256 root, uint256 nullifierHash, uint256[8] calldata proof) external {
        Will storage w = wills[willId];
        _requireOwnerProof(w, root, nullifierHash, proof);

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
    /// Callable by anyone holding the heir's proof; the proof signal is payoutAddress, so a relayer or
    /// front-runner can't swap in their own address (TD-007).
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
            abi.encodePacked(payoutAddress).hashToField(),
            nullifierHash,
            heirClaimExternalNullifier,
            proof
        );

        w.status = WillStatus.ClaimPending;
        w.claimInitiatedAt = uint64(block.timestamp);
        w.payoutAddress = payoutAddress;

        emit ClaimInitiated(willId, payoutAddress, uint64(block.timestamp));
    }

    /// @notice Pay out once the challenge period has passed. Callable by anyone; no proof needed (TD-009).
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

    /// @notice Every will ever created naming this heir, in creation order (including claimed / cancelled ones).
    function willIdsOfHeir(uint256 heirNullifier) external view returns (uint256[] memory) {
        return _willIdsOfHeir[heirNullifier];
    }

    /// @notice Earliest timestamp at which the heir may initiate a claim.
    function claimableAt(uint256 willId) public view returns (uint256) {
        Will storage w = wills[willId];
        // uint256 math: user-supplied uint64 periods must not be able to overflow and brick the claim path.
        return uint256(w.lastCheckIn) + w.checkInInterval + w.gracePeriod;
    }

    /// @notice Current phase, derived from stored status and block.timestamp.
    function currentPhase(uint256 willId) external view returns (WillPhase) {
        Will storage w = wills[willId];
        WillStatus s = w.status;
        if (s == WillStatus.Active) {
            if (block.timestamp < uint256(w.lastCheckIn) + w.checkInInterval) return WillPhase.Active;
            if (block.timestamp < claimableAt(willId)) return WillPhase.Grace;
            return WillPhase.Claimable;
        }
        if (s == WillStatus.ClaimPending) {
            return block.timestamp < _challengeEnd(w) ? WillPhase.Challenge : WillPhase.Finalizable;
        }
        if (s == WillStatus.Claimed) return WillPhase.Claimed;
        if (s == WillStatus.Cancelled) return WillPhase.Cancelled;
        return WillPhase.None;
    }

    // ---------------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------------

    /// @dev Shared gate for checkIn / cancel: caller is owner, will is live, and a valid alive-check proof.
    /// ownerNullifier is intentionally never marked as used — check-ins repeat forever (TD-001).
    function _requireOwnerProof(Will storage w, uint256 root, uint256 nullifierHash, uint256[8] calldata proof)
        internal
        view
    {
        require(w.owner == msg.sender, NotOwner());
        if (w.status == WillStatus.ClaimPending) {
            require(block.timestamp < _challengeEnd(w), ChallengeWindowClosed());
        } else {
            require(w.status == WillStatus.Active, InvalidStatus());
        }
        require(nullifierHash == w.ownerNullifier, NullifierMismatch());

        _verifyAlive(root, nullifierHash, proof);
    }

    function _verifyAlive(uint256 root, uint256 nullifierHash, uint256[8] calldata proof) internal view {
        worldId.verifyProof(
            root,
            GROUP_ID,
            abi.encodePacked(msg.sender).hashToField(),
            nullifierHash,
            aliveCheckExternalNullifier,
            proof
        );
    }

    function _challengeEnd(Will storage w) internal view returns (uint256) {
        return uint256(w.claimInitiatedAt) + w.challengePeriod;
    }

    function _send(address to, uint256 amount) internal {
        (bool ok,) = to.call{value: amount}("");
        require(ok, TransferFailed());
    }
}
