// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {CryptoWill, WillPhase, WillStatus} from "../src/CryptoWill.sol";
import {IWorldID} from "../src/interfaces/IWorldID.sol";
import {ByteHasher} from "../src/helpers/ByteHasher.sol";

interface IWorldIDRouter {
    function routeFor(uint256 groupId) external view returns (address);
}

interface IWorldIDGroup {
    function latestRoot() external view returns (uint256);
}

/// @notice Runs CryptoWill against the real World Chain Sepolia WorldIDRouter (TD-006).
///
/// Skipped unless WORLDCHAIN_SEPOLIA_RPC_URL is set. The real-proof tests additionally need
/// OWNER_PROOF_FIXTURE / HEIR_PROOF_FIXTURE (see test/fixtures/README.md).
contract CryptoWillForkTest is Test {
    using ByteHasher for bytes;

    address constant ROUTER = 0x57f928158C3EE7CDad1e4D8642503c4D0201f611;
    string constant ALIVE_ACTION = "cryptowill-alive-check";
    string constant CLAIM_ACTION = "cryptowill-heir-claim";

    bytes4 constant NON_EXISTENT_ROOT = 0xddae3b71;
    bytes4 constant PROOF_INVALID = 0x7fcdd1f4;

    struct Fixture {
        string appId;
        address signalAddress;
        uint256 root;
        uint256 nullifierHash;
        uint256 signalHash;
        uint256[8] proof;
        uint256 blockNumber;
    }

    uint256[8] zeroProof;

    function _fork(uint256 blockNumber) internal {
        string memory rpc = vm.envOr("WORLDCHAIN_SEPOLIA_RPC_URL", string(""));
        vm.skip(bytes(rpc).length == 0);
        if (blockNumber == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, blockNumber);
    }

    function _deploy(string memory appId) internal returns (CryptoWill) {
        return new CryptoWill(IWorldID(ROUTER), appId, ALIVE_ACTION, CLAIM_ACTION);
    }

    function _load(string memory envName) internal view returns (Fixture memory f, bool ok) {
        string memory path = vm.envOr(envName, string(""));
        if (bytes(path).length == 0) return (f, false);
        string memory json = vm.readFile(path);
        f.appId = vm.parseJsonString(json, ".app_id");
        f.signalAddress = vm.parseJsonAddress(json, ".signal_address");
        f.root = vm.parseJsonUint(json, ".merkle_root");
        f.nullifierHash = vm.parseJsonUint(json, ".nullifier_hash");
        f.signalHash = vm.parseJsonUint(json, ".signal_hash");
        f.proof = abi.decode(vm.parseJsonBytes(json, ".proof"), (uint256[8]));
        f.blockNumber = vm.parseJsonUint(json, ".block");
        ok = true;
    }

    // ---------------------------------------------------------------------
    // Wiring — no real proof needed
    // ---------------------------------------------------------------------

    function test_fork_routerServesOrbGroup() public {
        _fork(0);
        address group = IWorldIDRouter(ROUTER).routeFor(1);
        assertTrue(group != address(0));
        assertGt(IWorldIDGroup(group).latestRoot(), 0);
    }

    function test_fork_unknownRootReverts() public {
        _fork(0);
        CryptoWill will = _deploy("app_staging_wiring_check");
        vm.deal(address(this), 1 ether);
        vm.expectRevert(NON_EXISTENT_ROOT);
        will.createWill{value: 1 ether}(1, 111, zeroProof, 222, 1, 1, 1);
    }

    function test_fork_garbageProofOnLiveRootReverts() public {
        _fork(0);
        CryptoWill will = _deploy("app_staging_wiring_check");
        uint256 root = IWorldIDGroup(IWorldIDRouter(ROUTER).routeFor(1)).latestRoot();
        vm.deal(address(this), 1 ether);
        vm.expectRevert(PROOF_INVALID);
        will.createWill{value: 1 ether}(root, 111, zeroProof, 222, 1, 1, 1);
    }

    // ---------------------------------------------------------------------
    // Real proofs from the staging simulator
    // ---------------------------------------------------------------------

    /// Owner proof: createWill, repeated checkIn with the same proof (TD-001), then cancel.
    function test_fork_ownerLifecycleWithRealProof() public {
        (Fixture memory o, bool ok) = _load("OWNER_PROOF_FIXTURE");
        vm.skip(!ok);
        _fork(o.blockNumber);

        // Frontend/contract signal parity: IDKit's signal_hash must equal hashToField(abi.encodePacked(owner)).
        assertEq(o.signalHash, abi.encodePacked(o.signalAddress).hashToField(), "signal encoding mismatch");

        CryptoWill will = _deploy(o.appId);
        address owner = o.signalAddress;
        vm.deal(owner, 1 ether);

        vm.startPrank(owner);
        uint256 id = will.createWill{value: 1 ether}(o.root, o.nullifierHash, o.proof, 12345, 60, 60, 60);
        will.checkIn(id, o.root, o.nullifierHash, o.proof);
        vm.warp(block.timestamp + 30);
        will.checkIn(id, o.root, o.nullifierHash, o.proof);
        will.cancel(id, o.root, o.nullifierHash, o.proof);
        vm.stopPrank();

        assertEq(uint8(will.currentPhase(id)), uint8(WillPhase.Cancelled));
        assertEq(owner.balance, 1 ether);
    }

    /// Owner + heir proofs: full claim path with short periods.
    function test_fork_claimLifecycleWithRealProofs() public {
        (Fixture memory o, bool okOwner) = _load("OWNER_PROOF_FIXTURE");
        (Fixture memory h, bool okHeir) = _load("HEIR_PROOF_FIXTURE");
        vm.skip(!okOwner || !okHeir);
        _fork(o.blockNumber > h.blockNumber ? o.blockNumber : h.blockNumber);

        assertEq(keccak256(bytes(o.appId)), keccak256(bytes(h.appId)), "fixtures from different apps");
        assertEq(h.signalHash, abi.encodePacked(h.signalAddress).hashToField(), "heir signal encoding mismatch");
        assertTrue(o.nullifierHash != h.nullifierHash, "owner and heir fixtures are the same identity");

        CryptoWill will = _deploy(o.appId);
        vm.deal(o.signalAddress, 1 ether);
        vm.prank(o.signalAddress);
        uint256 id = will.createWill{value: 1 ether}(o.root, o.nullifierHash, o.proof, h.nullifierHash, 1, 1, 1);

        vm.warp(block.timestamp + 2);
        // Relayed by an arbitrary sender (TD-007).
        vm.prank(makeAddr("relayer"));
        will.initiateClaim(id, h.signalAddress, h.root, h.nullifierHash, h.proof);
        assertEq(uint8(will.currentPhase(id)), uint8(WillPhase.Challenge));

        vm.warp(block.timestamp + 1);
        uint256 before = h.signalAddress.balance;
        will.finalizeClaim(id);
        assertEq(h.signalAddress.balance - before, 1 ether);
        (,,,,,,,,,, WillStatus s) = will.wills(id);
        assertEq(uint8(s), uint8(WillStatus.Claimed));
    }
}
