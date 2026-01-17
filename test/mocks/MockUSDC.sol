// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockUSDC
/// @notice Mock USDC token for testing purposes
/// @dev Mimics USDC with 6 decimals and public mint function
contract MockUSDC is ERC20 {
    uint8 private constant DECIMALS = 6;

    constructor() ERC20("USD Coin", "USDC") {}

    /// @notice Returns the number of decimals (6 for USDC)
    function decimals() public pure override returns (uint8) {
        return DECIMALS;
    }

    /// @notice Mint tokens to any address (for testing only)
    /// @param to Address to mint to
    /// @param amount Amount to mint (in 6 decimal units)
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @notice Burn tokens from any address (for testing only)
    /// @param from Address to burn from
    /// @param amount Amount to burn
    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}
