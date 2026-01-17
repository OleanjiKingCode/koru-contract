// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {KoruEscrow} from "../src/KoruEscrow.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title SetFee
/// @notice Script to update platform fee
contract SetFee is Script {
    function run(address payable escrowAddress, uint256 newFeeBps) external {
        uint256 privateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        KoruEscrow escrow = KoruEscrow(escrowAddress);

        console2.log("Current fee:", escrow.feeBps());
        console2.log("New fee:", newFeeBps);

        vm.startBroadcast(privateKey);
        escrow.setFee(newFeeBps);
        vm.stopBroadcast();

        console2.log("Fee updated to:", escrow.feeBps());
    }
}

/// @title SetFeeRecipient
/// @notice Script to update fee recipient
contract SetFeeRecipient is Script {
    function run(address payable escrowAddress, address newRecipient) external {
        uint256 privateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        KoruEscrow escrow = KoruEscrow(escrowAddress);

        console2.log("Current fee recipient:", escrow.feeRecipient());
        console2.log("New fee recipient:", newRecipient);

        vm.startBroadcast(privateKey);
        escrow.setFeeRecipient(newRecipient);
        vm.stopBroadcast();

        console2.log("Fee recipient updated");
    }
}

/// @title TransferOwnership
/// @notice Script to initiate contract ownership transfer (step 1 of 2)
contract TransferOwnership is Script {
    function run(address payable escrowAddress, address newOwner) external {
        uint256 privateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        KoruEscrow escrow = KoruEscrow(escrowAddress);

        console2.log("Current owner:", escrow.owner());
        console2.log("Pending owner:", newOwner);

        vm.startBroadcast(privateKey);
        escrow.transferOwnership(newOwner);
        vm.stopBroadcast();

        console2.log("Ownership transfer initiated. New owner must call acceptOwnership().");
    }
}

/// @title AcceptOwnership
/// @notice Script to accept contract ownership (step 2 of 2)
contract AcceptOwnership is Script {
    function run(address payable escrowAddress) external {
        uint256 privateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        KoruEscrow escrow = KoruEscrow(escrowAddress);

        console2.log("Current owner:", escrow.owner());
        console2.log("Pending owner:", escrow.pendingOwner());

        vm.startBroadcast(privateKey);
        escrow.acceptOwnership();
        vm.stopBroadcast();

        console2.log("Ownership accepted. New owner:", escrow.owner());
    }
}

/// @title PauseContract
/// @notice Script to pause the contract
contract PauseContract is Script {
    function run(address payable escrowAddress) external {
        uint256 privateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        KoruEscrow escrow = KoruEscrow(escrowAddress);

        require(!escrow.paused(), "Already paused");

        vm.startBroadcast(privateKey);
        escrow.pause();
        vm.stopBroadcast();

        console2.log("Contract paused");
    }
}

/// @title UnpauseContract
/// @notice Script to unpause the contract
contract UnpauseContract is Script {
    function run(address payable escrowAddress) external {
        uint256 privateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        KoruEscrow escrow = KoruEscrow(escrowAddress);

        require(escrow.paused(), "Not paused");

        vm.startBroadcast(privateKey);
        escrow.unpause();
        vm.stopBroadcast();

        console2.log("Contract unpaused");
    }
}

/// @title ResolveDispute
/// @notice Script to resolve a disputed escrow
contract ResolveDispute is Script {
    function run(address payable escrowAddress, uint256 escrowId, address winner) external {
        uint256 privateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        KoruEscrow escrow = KoruEscrow(escrowAddress);

        console2.log("Resolving dispute for escrow:", escrowId);
        console2.log("Winner:", winner);

        vm.startBroadcast(privateKey);
        escrow.resolveDispute(escrowId, winner);
        vm.stopBroadcast();

        console2.log("Dispute resolved");
    }
}

/// @title GetEscrowInfo
/// @notice Script to get escrow information (read-only)
contract GetEscrowInfo is Script {
    function run(address payable escrowAddress, uint256 escrowId) external view {
        KoruEscrow escrow = KoruEscrow(escrowAddress);
        KoruEscrow.Escrow memory e = escrow.getEscrow(escrowId);

        console2.log("=== Escrow Info ===");
        console2.log("ID:", escrowId);
        console2.log("Depositor:", e.depositor);
        console2.log("Recipient:", e.recipient);
        console2.log("Amount:", e.amount);
        console2.log("Created At:", e.createdAt);
        console2.log("Accepted At:", e.acceptedAt);
        console2.log("Status:", uint8(e.status));
        console2.log("Fee BPS:", e.feeBps);
        console2.log("Fee Recipient:", e.feeRecipient);

        KoruEscrow.Deadlines memory d = escrow.getDeadlines(escrowId);
        console2.log("Accept Deadline:", d.acceptDeadline);
        console2.log("Dispute Deadline:", d.disputeDeadline);

        console2.log("Can Accept:", escrow.canAccept(escrowId));
        console2.log("Can Depositor Withdraw:", escrow.canDepositorWithdraw(escrowId));
        console2.log("Can Recipient Withdraw:", escrow.canRecipientWithdraw(escrowId));
        console2.log("Can Dispute:", escrow.canDispute(escrowId));
    }
}
