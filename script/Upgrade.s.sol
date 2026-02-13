// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {KoruEscrow} from "../src/KoruEscrow.sol";

/// @title UpgradeKoruEscrow
/// @notice Upgrade script for KoruEscrow UUPS proxy
/// @dev Deploys a new implementation and calls upgradeToAndCall on the existing proxy.
///      Run with: forge script script/Upgrade.s.sol:UpgradeKoruEscrow \
///               --rpc-url $BASE_SEPOLIA_RPC_URL --account KoruDeployerII --broadcast -vvvv
contract UpgradeKoruEscrow is Script {
    function run() external {
        // Load proxy address from environment
        address proxy = vm.envAddress("ESCROW_ADDRESS");
        require(proxy != address(0), "ESCROW_ADDRESS required");

        console2.log("===========================================");
        console2.log("Upgrading KoruEscrow proxy at:", proxy);
        console2.log("Chain ID:", block.chainid);
        console2.log("===========================================");

        // Verify current state before upgrade
        KoruEscrow current = KoruEscrow(payable(proxy));
        address currentOwner = current.owner();
        uint256 escrowCount = current.getEscrowCount();
        console2.log("Current owner:", currentOwner);
        console2.log("Existing escrows:", escrowCount);

        vm.startBroadcast();

        // 1. Deploy new implementation
        KoruEscrow newImplementation = new KoruEscrow();
        console2.log("New implementation deployed at:", address(newImplementation));

        // 2. Upgrade proxy to new implementation (no re-initialization needed)
        current.upgradeToAndCall(address(newImplementation), "");
        console2.log("Proxy upgraded successfully!");

        vm.stopBroadcast();

        // 3. Verify state is preserved
        console2.log("===========================================");
        console2.log("Post-upgrade verification:");
        console2.log("  Owner:", current.owner());
        console2.log("  Escrow count:", current.getEscrowCount());
        console2.log("  Fee BPS:", current.feeBps());
        console2.log("  Paused:", current.paused());
        console2.log("===========================================");

        require(current.owner() == currentOwner, "Owner changed after upgrade!");
        require(current.getEscrowCount() == escrowCount, "Escrow count changed after upgrade!");
    }
}
