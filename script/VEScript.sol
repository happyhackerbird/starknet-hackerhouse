// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import {VotingEscrow} from "src/VotingEscrow.sol";

contract VEScript is Script {
    VotingEscrow public ve;

    function setUp() public {}

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("POLYGON_PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);
        ve = new VotingEscrow(address(0));
        vm.stopBroadcast();
    }
}
