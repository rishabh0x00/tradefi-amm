// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {MinimalDEX} from "../src/MinimalDEX.sol";

contract DeployMinimalDEX is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        uint256 fee = vm.envUint("FEE");
        
        MinimalDEX dex = new MinimalDEX(fee);
        
        vm.stopBroadcast();
    }
}