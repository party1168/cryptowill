// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {CryptoWill, WillStatus, WillPhase} from "../src/CryptoWill.sol";
import {IWorldID} from "../src/interfaces/IWorldID.sol";
import {ByteHasher} from "../src/helpers/ByteHasher.sol";

/// @dev Accepts a proof only if the exact (root, group, signal, nullifier, externalNullifier) tuple was registered.
contract MockWorldID is IWorldID {
    mapping(bytes32 => bool) public valid;

    function allow(uint256 root, uint256 signalHash, uint256 nullifierHash, uint256 externalNullifierHash) external {
        valid[keccak256(abi.encode(root, uint256(1), signalHash, nullifierHash, externalNullifierHash))] = true;
    }

    function verifyProof(
        uint256 root,
        uint256 groupId,
        uint256 signalHash,
        uint256 nullifierHash,
        uint256 externalNullifierHash,
        uint256[8] calldata
    ) external view {
        require(
            valid[keccak256(abi.encode(root, groupId, signalHash, nullifierHash, externalNullifierHash))], "bad proof"
        );
    }
}

contract Rejecter {
    receive() external payable {
        revert();
    }
}

contract CryptoWillTest is Test {
    using ByteHasher for bytes;

    MockWorldID worldId;
    CryptoWill will;

    address owner = makeAddr("owner");
    address payout = makeAddr("payout");
    uint256 constant ROOT = 42;
    uint256 constant OWNER_N = 111;
    uint256 constant HEIR_N = 222;
    uint64 constant INTERVAL = 30 days;
    uint64 constant GRACE = 7 days;
    uint64 constant CHALLENGE = 3 days;
    uint256[8] proof;

    function setUp() public {
        worldId = new MockWorldID();
        will = new CryptoWill(worldId, "app_test", "alive", "claim");
        vm.deal(owner, 10 ether);
    }

    function _allowOwner() internal {
        worldId.allow(ROOT, abi.encodePacked(owner).hashToField(), OWNER_N, will.aliveCheckExternalNullifier());
    }

    function _create() internal returns (uint256 id) {
        _allowOwner();
        vm.prank(owner);
        id = will.createWill{value: 1 ether}(ROOT, OWNER_N, proof, HEIR_N, INTERVAL, GRACE, CHALLENGE);
    }

    function _allowClaim(address to) internal {
        worldId.allow(ROOT, abi.encodePacked(to).hashToField(), HEIR_N, will.heirClaimExternalNullifier());
    }

    function _status(uint256 id) internal view returns (WillStatus s) {
        (,,,,,,,,,, s) = will.wills(id);
    }

    function _initiate(uint256 id) internal {
        vm.warp(will.claimableAt(id));
        _allowClaim(payout);
        will.initiateClaim(id, payout, ROOT, HEIR_N, proof);
    }

    // ---- createWill ----

    function test_createWill() public {
        uint256 id = _create();
        assertEq(id, 1);
        assertEq(will.activeWillOf(owner), 1);
        assertEq(address(will).balance, 1 ether);
        assertEq(uint8(_status(id)), uint8(WillStatus.Active));
    }

    function test_createWill_revertsWhenAlreadyActive() public {
        _create();
        vm.prank(owner);
        vm.expectRevert(CryptoWill.WillAlreadyActive.selector);
        will.createWill{value: 1 ether}(ROOT, OWNER_N, proof, HEIR_N, INTERVAL, GRACE, CHALLENGE);
    }

    function test_createWill_revertsOnHeirEqualsOwner() public {
        _allowOwner();
        vm.prank(owner);
        vm.expectRevert(CryptoWill.HeirIsOwner.selector);
        will.createWill{value: 1 ether}(ROOT, OWNER_N, proof, OWNER_N, INTERVAL, GRACE, CHALLENGE);
    }

    function test_createWill_revertsOnZeroPeriods() public {
        vm.startPrank(owner);
        vm.expectRevert(CryptoWill.ZeroPeriod.selector);
        will.createWill{value: 1 ether}(ROOT, OWNER_N, proof, HEIR_N, 0, GRACE, CHALLENGE);
        vm.expectRevert(CryptoWill.ZeroPeriod.selector);
        will.createWill{value: 1 ether}(ROOT, OWNER_N, proof, HEIR_N, INTERVAL, 0, CHALLENGE);
        vm.expectRevert(CryptoWill.ZeroPeriod.selector);
        will.createWill{value: 1 ether}(ROOT, OWNER_N, proof, HEIR_N, INTERVAL, GRACE, 0);
    }

    function test_createWill_revertsOnBadHeirNullifier() public {
        vm.startPrank(owner);
        vm.expectRevert(CryptoWill.InvalidHeirNullifier.selector);
        will.createWill{value: 1 ether}(ROOT, OWNER_N, proof, 0, INTERVAL, GRACE, CHALLENGE);
        vm.expectRevert(CryptoWill.InvalidHeirNullifier.selector);
        will.createWill{value: 1 ether}(ROOT, OWNER_N, proof, type(uint256).max, INTERVAL, GRACE, CHALLENGE);
    }

    function test_createWill_signalBoundToSender() public {
        _allowOwner(); // proof generated for `owner`
        address other = makeAddr("other");
        vm.deal(other, 1 ether);
        vm.prank(other);
        vm.expectRevert("bad proof");
        will.createWill{value: 1 ether}(ROOT, OWNER_N, proof, HEIR_N, INTERVAL, GRACE, CHALLENGE);
    }

    function test_createWill_maxPeriodsDoNotOverflow() public {
        _allowOwner();
        vm.prank(owner);
        uint64 max = type(uint64).max;
        uint256 id = will.createWill{value: 1 ether}(ROOT, OWNER_N, proof, HEIR_N, max, max, max);
        assertGt(will.claimableAt(id), max);
    }

    // ---- checkIn ----

    function test_checkIn_resetsDeadline() public {
        uint256 id = _create();
        vm.warp(block.timestamp + INTERVAL);
        vm.prank(owner);
        will.checkIn(id, ROOT, OWNER_N, proof);
        assertEq(will.claimableAt(id), block.timestamp + INTERVAL + GRACE);
    }

    /// TD-001: ownerNullifier is never consumed, so the same nullifier checks in repeatedly.
    function test_checkIn_repeatsWithSameNullifier() public {
        uint256 id = _create();
        for (uint256 i = 0; i < 12; i++) {
            vm.warp(block.timestamp + INTERVAL);
            vm.prank(owner);
            will.checkIn(id, ROOT, OWNER_N, proof);
        }
        assertEq(uint8(will.currentPhase(id)), uint8(WillPhase.Active));
    }

    /// Accepted demo risk (TD-007): owner signal is just the owner address, so one alive-check proof
    /// is valid for createWill, checkIn and cancel alike (until its root expires).
    function test_ownerProofSharedAcrossOps_acceptedRisk() public {
        uint256 id = _create();
        vm.startPrank(owner);
        will.checkIn(id, ROOT, OWNER_N, proof);
        will.cancel(id, ROOT, OWNER_N, proof);
        vm.stopPrank();
        assertEq(uint8(_status(id)), uint8(WillStatus.Cancelled));
    }

    function test_checkIn_signalBoundToOwner() public {
        uint256 id = _create();
        // Proof registered for `owner`; a different sender can't pass NotOwner, and the signal is msg.sender anyway.
        vm.prank(makeAddr("other"));
        vm.expectRevert(CryptoWill.NotOwner.selector);
        will.checkIn(id, ROOT, OWNER_N, proof);
    }

    function test_currentPhase_walksThroughAllPhases() public {
        uint256 id = _create();
        uint256 t0 = block.timestamp;
        assertEq(uint8(will.currentPhase(id)), uint8(WillPhase.Active));
        vm.warp(t0 + INTERVAL);
        assertEq(uint8(will.currentPhase(id)), uint8(WillPhase.Grace));
        vm.warp(t0 + INTERVAL + GRACE);
        assertEq(uint8(will.currentPhase(id)), uint8(WillPhase.Claimable));

        _allowClaim(payout);
        will.initiateClaim(id, payout, ROOT, HEIR_N, proof);
        assertEq(uint8(will.currentPhase(id)), uint8(WillPhase.Challenge));
        vm.warp(block.timestamp + CHALLENGE);
        assertEq(uint8(will.currentPhase(id)), uint8(WillPhase.Finalizable));
        will.finalizeClaim(id);
        assertEq(uint8(will.currentPhase(id)), uint8(WillPhase.Claimed));

        assertEq(uint8(will.currentPhase(999)), uint8(WillPhase.None));
    }

    function test_checkIn_duringGraceAndClaimable() public {
        uint256 id = _create();
        vm.warp(will.claimableAt(id) + 100); // Claimable, but nobody initiated
        vm.prank(owner);
        will.checkIn(id, ROOT, OWNER_N, proof);
        assertEq(uint8(will.currentPhase(id)), uint8(WillPhase.Active));
    }

    /// TD-007: one-time claim is enforced per will by the state machine, not a global nullifier mapping,
    /// so the same heir can inherit from two different owners.
    function test_sameHeirCanClaimTwoWills() public {
        uint256 id1 = _create();
        address owner2 = makeAddr("owner2");
        vm.deal(owner2, 1 ether);
        worldId.allow(ROOT, abi.encodePacked(owner2).hashToField(), 777, will.aliveCheckExternalNullifier());
        vm.prank(owner2);
        uint256 id2 = will.createWill{value: 1 ether}(ROOT, 777, proof, HEIR_N, INTERVAL, GRACE, CHALLENGE);

        vm.warp(will.claimableAt(id1));
        _allowClaim(payout);
        will.initiateClaim(id1, payout, ROOT, HEIR_N, proof);
        will.initiateClaim(id2, payout, ROOT, HEIR_N, proof);
        vm.warp(block.timestamp + CHALLENGE);
        will.finalizeClaim(id1);
        will.finalizeClaim(id2);
        assertEq(payout.balance, 2 ether);
    }

    function test_willIdsOfHeir_listsEveryWillNamingTheHeir() public {
        assertEq(will.willIdsOfHeir(HEIR_N).length, 0);

        uint256 id1 = _create();
        address owner2 = makeAddr("owner2");
        vm.deal(owner2, 1 ether);
        worldId.allow(ROOT, abi.encodePacked(owner2).hashToField(), 777, will.aliveCheckExternalNullifier());
        vm.prank(owner2);
        uint256 id2 = will.createWill{value: 1 ether}(ROOT, 777, proof, HEIR_N, INTERVAL, GRACE, CHALLENGE);

        uint256[] memory ids = will.willIdsOfHeir(HEIR_N);
        assertEq(ids.length, 2);
        assertEq(ids[0], id1);
        assertEq(ids[1], id2);
        assertEq(will.willIdsOfHeir(999).length, 0, "other heirs see nothing");
    }

    /// History is kept: a cancelled will stays in the index (the frontend shows its phase).
    function test_willIdsOfHeir_keepsEndedWills() public {
        uint256 id = _create();
        vm.prank(owner);
        will.cancel(id, ROOT, OWNER_N, proof);

        uint256 id2 = _create(); // same owner re-creates, same heir
        uint256[] memory ids = will.willIdsOfHeir(HEIR_N);
        assertEq(ids.length, 2);
        assertEq(ids[0], id);
        assertEq(ids[1], id2);
    }

    function test_checkIn_onlyOwner() public {
        uint256 id = _create();
        vm.expectRevert(CryptoWill.NotOwner.selector);
        will.checkIn(id, ROOT, OWNER_N, proof);
    }

    function test_checkIn_wrongNullifier() public {
        uint256 id = _create();
        vm.prank(owner);
        vm.expectRevert(CryptoWill.NullifierMismatch.selector);
        will.checkIn(id, ROOT, 999, proof);
    }

    // ---- claim ----

    function test_initiateClaim_tooEarly() public {
        uint256 id = _create();
        vm.warp(will.claimableAt(id) - 1);
        _allowClaim(payout);
        vm.expectRevert(CryptoWill.NotClaimableYet.selector);
        will.initiateClaim(id, payout, ROOT, HEIR_N, proof);
    }

    function test_initiateClaim_frontRunCannotSwapPayout() public {
        uint256 id = _create();
        vm.warp(will.claimableAt(id));
        _allowClaim(payout);
        vm.expectRevert("bad proof");
        will.initiateClaim(id, makeAddr("attacker"), ROOT, HEIR_N, proof);
    }

    function test_initiateClaim_wrongHeir() public {
        uint256 id = _create();
        vm.warp(will.claimableAt(id));
        vm.expectRevert(CryptoWill.NullifierMismatch.selector);
        will.initiateClaim(id, payout, ROOT, 333, proof);
    }

    function test_fullClaimFlow() public {
        uint256 id = _create();
        _initiate(id);
        assertEq(uint8(_status(id)), uint8(WillStatus.ClaimPending));

        vm.warp(block.timestamp + CHALLENGE - 1);
        vm.expectRevert(CryptoWill.ChallengeWindowOpen.selector);
        will.finalizeClaim(id);

        vm.warp(block.timestamp + 1);
        will.finalizeClaim(id);
        assertEq(payout.balance, 1 ether);
        assertEq(uint8(_status(id)), uint8(WillStatus.Claimed));
        assertEq(will.activeWillOf(owner), 0);

        vm.expectRevert(CryptoWill.InvalidStatus.selector);
        will.finalizeClaim(id);
    }

    function test_challenge_revertsClaim() public {
        uint256 id = _create();
        _initiate(id);
        vm.warp(block.timestamp + CHALLENGE - 1);
        vm.prank(owner);
        will.checkIn(id, ROOT, OWNER_N, proof);

        assertEq(uint8(_status(id)), uint8(WillStatus.Active));
        vm.expectRevert(CryptoWill.InvalidStatus.selector);
        will.finalizeClaim(id);
        assertEq(will.claimableAt(id), block.timestamp + INTERVAL + GRACE);
    }

    function test_challenge_afterWindowFails() public {
        uint256 id = _create();
        _initiate(id);
        vm.warp(block.timestamp + CHALLENGE);
        vm.prank(owner);
        vm.expectRevert(CryptoWill.ChallengeWindowClosed.selector);
        will.checkIn(id, ROOT, OWNER_N, proof);
    }

    function test_finalize_revertingPayoutBlocks() public {
        uint256 id = _create();
        address bad = address(new Rejecter());
        vm.warp(will.claimableAt(id));
        _allowClaim(bad);
        will.initiateClaim(id, bad, ROOT, HEIR_N, proof);
        vm.warp(block.timestamp + CHALLENGE);
        vm.expectRevert(CryptoWill.TransferFailed.selector);
        will.finalizeClaim(id);
    }

    // ---- cancel ----

    function test_cancel_refundsAndAllowsNewWill() public {
        uint256 id = _create();
        vm.prank(owner);
        will.cancel(id, ROOT, OWNER_N, proof);
        assertEq(owner.balance, 10 ether);
        assertEq(uint8(_status(id)), uint8(WillStatus.Cancelled));
        assertEq(will.activeWillOf(owner), 0);

        uint256 id2 = _create();
        assertEq(id2, 2);
    }

    function test_cancel_duringChallengeWindow() public {
        uint256 id = _create();
        _initiate(id);
        vm.prank(owner);
        will.cancel(id, ROOT, OWNER_N, proof);
        assertEq(owner.balance, 10 ether);
    }

    function test_constructor_rejectsSameAction() public {
        vm.expectRevert(CryptoWill.SameAction.selector);
        new CryptoWill(worldId, "app_test", "x", "x");
    }
}
