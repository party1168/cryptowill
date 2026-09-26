// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {CryptoWill} from "../src/CryptoWill.sol";
import {IWorldID} from "../src/interfaces/IWorldID.sol";

/// @dev Deploys to World Chain Sepolia (TD-006). env: WORLD_APP_ID (staging app id, locked).
contract CryptoWillScript is Script {
    address constant WORLDCHAIN_SEPOLIA_ROUTER = 0x57f928158C3EE7CDad1e4D8642503c4D0201f611;
    string constant ALIVE_ACTION = "cryptowill-alive-check";
    string constant CLAIM_ACTION = "cryptowill-heir-claim";

    function run() public returns (CryptoWill will) {
        require(block.chainid == 4801, "expected World Chain Sepolia (4801)");
        string memory appId = vm.envString("WORLD_APP_ID");

        vm.startBroadcast();
        will = new CryptoWill(IWorldID(WORLDCHAIN_SEPOLIA_ROUTER), appId, ALIVE_ACTION, CLAIM_ACTION);
        vm.stopBroadcast();

        console.log("CryptoWill:", address(will));
        console.log("aliveCheckExternalNullifier:", will.aliveCheckExternalNullifier());
        console.log("heirClaimExternalNullifier:", will.heirClaimExternalNullifier());
    }
}
