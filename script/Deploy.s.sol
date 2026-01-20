// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {KoruEscrow} from "../src/KoruEscrow.sol";

/// @title DeployKoruEscrow
/// @notice Deployment script for KoruEscrow contract
/// @dev Run with: forge script script/Deploy.s.sol:DeployKoruEscrow --rpc-url $RPC_URL --broadcast
contract DeployKoruEscrow is Script {
    // Base Mainnet USDC
    address constant USDC_BASE = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    // Base Sepolia USDC
    address constant USDC_BASE_SEPOLIA = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;

    function run() external returns (KoruEscrow escrow) {
        // Load config from environment
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        uint256 feeBps = vm.envOr("FEE_BPS", uint256(250)); // Default 2.5%
        address feeRecipient = vm.envAddress("FEE_RECIPIENT");

        // Determine USDC address based on chain
        address usdcAddress;
        if (block.chainid == 8453) {
            // Base Mainnet
            usdcAddress = USDC_BASE;
            console2.log("Deploying to Base Mainnet");
        } else if (block.chainid == 84532) {
            // Base Sepolia
            usdcAddress = USDC_BASE_SEPOLIA;
            console2.log("Deploying to Base Sepolia");
        } else {
            // For local testing, use env or revert
            usdcAddress = vm.envOr("USDC_ADDRESS", address(0));
            require(usdcAddress != address(0), "USDC_ADDRESS required for this chain");
            console2.log("Deploying to chain:", block.chainid);
        }

        console2.log("USDC Address:", usdcAddress);
        console2.log("Fee BPS:", feeBps);
        console2.log("Fee Recipient:", feeRecipient);

        vm.startBroadcast(deployerPrivateKey);

        escrow = new KoruEscrow();
        escrow.initialize(usdcAddress, feeBps, feeRecipient);

        vm.stopBroadcast();

        console2.log("KoruEscrow deployed at:", address(escrow));
        console2.log("Owner:", escrow.owner());

        return escrow;
    }
}

/// @title DeployKoruEscrowLocal
/// @notice Deployment script for local testing with mock USDC
contract DeployKoruEscrowLocal is Script {
    function run() external returns (KoruEscrow escrow, address mockUsdc) {
        vm.startBroadcast();

        // Deploy mock USDC for testing
        // Using CREATE2 for deterministic address
        bytes memory bytecode = abi.encodePacked(
            type(MockUSDCDeploy).creationCode
        );
        address deployed;
        assembly {
            deployed := create(0, add(bytecode, 0x20), mload(bytecode))
        }
        mockUsdc = deployed;

        // Deploy escrow
        escrow = new KoruEscrow();
        escrow.initialize(mockUsdc, 250, msg.sender);

        vm.stopBroadcast();

        console2.log("MockUSDC deployed at:", mockUsdc);
        console2.log("KoruEscrow deployed at:", address(escrow));

        return (escrow, mockUsdc);
    }
}

/// @notice Minimal mock USDC for deployment script
contract MockUSDCDeploy {
    string public name = "USD Coin";
    string public symbol = "USDC";
    uint8 public decimals = 6;
    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}
