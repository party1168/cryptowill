// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {CryptoWill, WillStatus} from "../src/CryptoWill.sol";
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

    function _allowCreate() internal {
        worldId.allow(ROOT, abi.encodePacked(owner).hashToField(), OWNER_N, will.EXTERNAL_NULLIFIER_ALIVE());
    }

    function _create() internal returns (uint256 id) {
        _allowCreate();
        vm.prank(owner);
        id = will.createWill{value: 1 ether}(ROOT, OWNER_N, proof, HEIR_N, INTERVAL, GRACE, CHALLENGE);
    }

    function _allowCheckIn(uint256 id) internal {
        worldId.allow(ROOT, will.checkInSignal(id).hashToField(), OWNER_N, will.EXTERNAL_NULLIFIER_ALIVE());
    }

    function _allowCancel(uint256 id) internal {
        worldId.allow(ROOT, will.cancelSignal(id).hashToField(), OWNER_N, will.EXTERNAL_NULLIFIER_ALIVE());
    }

    function _allowClaim(uint256 id, address to) internal {
        worldId.allow(ROOT, will.claimSignal(id, to).hashToField(), HEIR_N, will.EXTERNAL_NULLIFIER_CLAIM());
    }

    function _status(uint256 id) internal view returns (WillStatus s) {
        (,,,,,,,,,, s) = will.wills(id);
    }

    function _initiate(uint256 id) internal {
        vm.warp(will.claimableAt(id));
        _allowClaim(id, payout);
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
        _allowCreate();
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
        _allowCreate(); // proof generated for `owner`
        address other = makeAddr("other");
        vm.deal(other, 1 ether);
        vm.prank(other);
        vm.expectRevert("bad proof");
        will.createWill{value: 1 ether}(ROOT, OWNER_N, proof, HEIR_N, INTERVAL, GRACE, CHALLENGE);
    }

    function test_createWill_maxPeriodsDoNotOverflow() public {
        _allowCreate();
        vm.prank(owner);
        uint64 max = type(uint64).max;
        uint256 id = will.createWill{value: 1 ether}(ROOT, OWNER_N, proof, HEIR_N, max, max, max);
        assertGt(will.claimableAt(id), max);
    }

    // ---- checkIn ----

    function test_checkIn_resetsDeadline() public {
        uint256 id = _create();
        vm.warp(block.timestamp + INTERVAL);
        _allowCheckIn(id);
        vm.prank(owner);
        will.checkIn(id, ROOT, OWNER_N, proof);
        assertEq(will.claimableAt(id), block.timestamp + INTERVAL + GRACE);
    }

    function test_checkIn_oldProofNotReplayable() public {
        uint256 id = _create();
        _allowCheckIn(id);
        vm.warp(block.timestamp + 1);
        vm.prank(owner);
        will.checkIn(id, ROOT, OWNER_N, proof);

        // Same proof, next check-in: lastCheckIn moved, signal changed.
        vm.warp(block.timestamp + 1);
        vm.prank(owner);
        vm.expectRevert("bad proof");
        will.checkIn(id, ROOT, OWNER_N, proof);
    }

    function test_createProofNotReusableForCheckInOrCancel() public {
        uint256 id = _create(); // only the createWill signal is registered
        vm.startPrank(owner);
        vm.expectRevert("bad proof");
        will.checkIn(id, ROOT, OWNER_N, proof);
        vm.expectRevert("bad proof");
        will.cancelWill(id, ROOT, OWNER_N, proof);
    }

    function test_checkInProofNotUsableAsCancel() public {
        uint256 id = _create();
        _allowCheckIn(id);
        vm.prank(owner);
        vm.expectRevert("bad proof");
        will.cancelWill(id, ROOT, OWNER_N, proof);
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
        _allowClaim(id, payout);
        vm.expectRevert(CryptoWill.NotClaimableYet.selector);
        will.initiateClaim(id, payout, ROOT, HEIR_N, proof);
    }

    function test_initiateClaim_frontRunCannotSwapPayout() public {
        uint256 id = _create();
        vm.warp(will.claimableAt(id));
        _allowClaim(id, payout);
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
        _allowCheckIn(id);
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
        _allowCheckIn(id);
        vm.prank(owner);
        vm.expectRevert(CryptoWill.ChallengeWindowClosed.selector);
        will.checkIn(id, ROOT, OWNER_N, proof);
    }

    function test_finalize_revertingPayoutBlocks() public {
        uint256 id = _create();
        address bad = address(new Rejecter());
        vm.warp(will.claimableAt(id));
        _allowClaim(id, bad);
        will.initiateClaim(id, bad, ROOT, HEIR_N, proof);
        vm.warp(block.timestamp + CHALLENGE);
        vm.expectRevert(CryptoWill.TransferFailed.selector);
        will.finalizeClaim(id);
    }

    // ---- cancel ----

    function test_cancel_refundsAndAllowsNewWill() public {
        uint256 id = _create();
        _allowCancel(id);
        vm.prank(owner);
        will.cancelWill(id, ROOT, OWNER_N, proof);
        assertEq(owner.balance, 10 ether);
        assertEq(uint8(_status(id)), uint8(WillStatus.Cancelled));
        assertEq(will.activeWillOf(owner), 0);

        uint256 id2 = _create();
        assertEq(id2, 2);
    }

    function test_cancel_duringChallengeWindow() public {
        uint256 id = _create();
        _initiate(id);
        _allowCancel(id);
        vm.prank(owner);
        will.cancelWill(id, ROOT, OWNER_N, proof);
        assertEq(owner.balance, 10 ether);
    }

    function test_constructor_rejectsSameAction() public {
        vm.expectRevert(CryptoWill.SameAction.selector);
        new CryptoWill(worldId, "app_test", "x", "x");
    }
}
