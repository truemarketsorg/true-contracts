// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./libraries/Roles.sol";

contract TrueToken is ERC20, ERC20Votes, AccessControl, Ownable {
    uint256 public maxSupply = 100_000_000 * 10**18;

    constructor() ERC20("True", "TRUE") ERC20Permit("True") {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    /// @notice Mints new tokens to a specified address
    /// @param to The address to mint tokens to
    /// @param amount The amount of tokens to mint
    /// @dev Only callable by the owner. Reverts if it would exceed maxSupply
    function mint(address to, uint256 amount) public onlyOwner {
        if (totalSupply() + amount > maxSupply) {
            revert ExceedsMaxSupply();
        }
        _mint(to, amount);
    }

    /// @notice Delegates voting power from the owner to a specified address
    /// @param to The address to delegate voting power to
    /// @dev Only callable by the owner
    function delegateByOwner(address to) public onlyOwner {
        _delegate(to, to);
    }

    /// @notice Sets a new maximum supply for the token
    /// @param newMaxSupply The new maximum supply value
    /// @dev Only callable by addresses with the TIMELOCK_ROLE
    function setMaxSupply(uint256 newMaxSupply) external onlyRole(Roles.TIMELOCK_ROLE) {
        maxSupply = newMaxSupply;
    }

    function _afterTokenTransfer(address from, address to, uint256 amount) internal override(ERC20, ERC20Votes) {
        super._afterTokenTransfer(from, to, amount);
    }

    function _mint(address to, uint256 amount) internal override(ERC20, ERC20Votes) {
        super._mint(to, amount);
    }

    function _burn(address account, uint256 amount) internal override(ERC20, ERC20Votes) {
        super._burn(account, amount);
    }

    error ExceedsMaxSupply();
}
