// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

contract YesNoToken is ERC20, Ownable, ERC20Burnable {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    /// @notice Mints new tokens to a specified address
    /// @param to The address to mint tokens to
    /// @param amount The amount of tokens to mint
    /// @dev Only callable by the owner of the contract
    function mint(address to, uint256 amount) public onlyOwner {
        _mint(to, amount);
    }
}