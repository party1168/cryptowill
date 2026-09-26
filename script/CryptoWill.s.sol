// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";
import {CryptoWill} from "../src/CryptoWill.sol";
import {IWorldID} from "../src/interfaces/IWorldID.sol";

/// @dev env: WORLD_ID_ROUTER, WORLD_APP_ID, ACTION_ALIVE, ACTION_CLAIM
contract CryptoWillScript is Script {
    function run() public returns (CryptoWill will) {
        vm.startBroadcast();
        will = new CryptoWill(
            IWorldID(vm.envAddress("WORLD_ID_ROUTER")),
            vm.envString("WORLD_APP_ID"),
            vm.envString("ACTION_ALIVE"),
            vm.envString("ACTION_CLAIM")
        );
        vm.stopBroadcast();
    }
}
