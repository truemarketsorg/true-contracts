// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ActionConstants} from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";
import {AdapterStrategy} from "./AdapterStrategy.sol";

contract SweepStrategy is AdapterStrategy {
    error UnsupportedRecipient();

    constructor(address _adapter) AdapterStrategy(_adapter) {}

    function beforeExecute(uint256, bytes calldata inputs, address msgSender)
        external
        view
        override
        onlyAdapter
        returns (PackedApproval[] memory approvals, bytes memory modifiedInputs)
    {
        (address token, address recipient, uint256 amountMin) = _parseInputs(inputs);

        if (recipient != msgSender && recipient != ActionConstants.MSG_SENDER) {
            revert UnsupportedRecipient();
        }

        approvals = new PackedApproval[](0);

        modifiedInputs = abi.encode(token, address(adapter), amountMin);
    }

    function afterExecute(uint256 command, bytes calldata inputs, address msgSender) external override onlyAdapter {
        (address token,,) = _parseInputs(inputs);

        uint256 amount = IERC20(token).balanceOf(address(adapter));

        if (amount > 0) {
            adapter.transferTo(command, msgSender, amount, address(token));
        }
    }

    function _parseInputs(bytes calldata inputs)
        internal
        pure
        returns (address token, address recipient, uint256 amountMin)
    {
        assembly {
            token := calldataload(inputs.offset)
            recipient := calldataload(add(inputs.offset, 0x20))
            amountMin := calldataload(add(inputs.offset, 0x40))
        }
    }
}
