// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Commands} from "@uniswap/universal-router/contracts/libraries/Commands.sol";
import {ActionConstants} from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";
import {BytesLib} from "@uniswap/universal-router/contracts/modules/uniswap/v3/BytesLib.sol";
import {V3Path} from "@uniswap/universal-router/contracts/modules/uniswap/v3/V3Path.sol";
import {CalldataDecoder} from "@uniswap/v4-periphery/src/libraries/CalldataDecoder.sol";
import {AdapterStrategy} from "./AdapterStrategy.sol";

contract V3SwapStrategy is AdapterStrategy {
    using BytesLib for bytes;
    using CalldataDecoder for bytes;
    using V3Path for bytes;
    using SafeERC20 for IERC20;

    error UnsupportedRecipient();
    error UnsupportedPayer();

    constructor(address _adapter) AdapterStrategy(_adapter) {}

    function beforeExecute(uint256 command, bytes calldata inputs, address msgSender)
        external
        override
        onlyAdapter
        returns (PackedApproval[] memory approvals, bytes memory modifiedInputs)
    {
        bool isExactInput;
        address recipient;
        uint256 amountIn;
        uint256 amountOut;
        bool payerIsUser;

        if (command == Commands.V3_SWAP_EXACT_IN) {
            isExactInput = true;
            (recipient, amountIn, amountOut, payerIsUser) = _parseExactInInputs(inputs);
        } else {
            isExactInput = false;
            (recipient, amountOut, amountIn, payerIsUser) = _parseExactOutInputs(inputs);
        }

        if (
            recipient != msgSender && recipient != ActionConstants.MSG_SENDER
                && recipient != ActionConstants.ADDRESS_THIS
        ) {
            revert UnsupportedRecipient();
        }

        if (!payerIsUser) revert UnsupportedPayer();

        bytes calldata path = inputs.toBytes(3);

        (address tokenIn,, address tokenOut) = path.decodeFirstPool();

        address tokenToApprove = isExactInput ? tokenIn : tokenOut;

        amountIn = adapter.permit2TransferFrom(command, msgSender, amountIn, address(tokenToApprove));

        approvals = new PackedApproval[](1);
        approvals[0] = PackedApproval(tokenToApprove, amountIn);

        // @note Under normal circumstances, using address this as the recipient is paired with the sweep command.
        // Using address this as the recipient can also be paired with the pay portion command,
        // but the user needs to end with a sweep command to reclaim the assets.
        // - When the recipient is msgSender, this strategy will change the recipient to the adapter.
        //   The asset will be returned directly to msgSender from the adapter after afterExecute.
        // - When the recipient is address(this), the asset will have its recipient changed to the adapter in
        //   the sweep command strategy’s beforeExecute, and will be returned from the adapter in afterExecute.
        if (recipient == ActionConstants.ADDRESS_THIS) {
            // do nothing
        } else if (command == Commands.V3_SWAP_EXACT_IN) {
            modifiedInputs = abi.encode(address(adapter), amountIn, amountOut, path, true);
        } else {
            modifiedInputs = abi.encode(address(adapter), amountOut, amountIn, path, true);
        }
    }

    function afterExecute(uint256 command, bytes calldata inputs, address msgSender) external override onlyAdapter {
        bool isExactInput;

        if (command == Commands.V3_SWAP_EXACT_IN) {
            isExactInput = true;
        } else {
            isExactInput = false;
        }

        bytes calldata path = inputs.toBytes(3);

        (address tokenIn,, address tokenOut) = path.decodeFirstPool();

        if (!isExactInput) {
            (tokenIn, tokenOut) = (tokenOut, tokenIn);
        }

        uint256 remainingTokenIn = IERC20(tokenIn).balanceOf(address(adapter));

        if (remainingTokenIn > 0) {
            // return all remaining tokenIn to the msg sender
            adapter.transferTo(command, msgSender, remainingTokenIn, address(tokenIn));
        }

        uint256 amountTokenOut = IERC20(tokenOut).balanceOf(address(adapter));

        if (amountTokenOut > 0) {
            // return all token out to the msg sender
            adapter.transferTo(command, msgSender, amountTokenOut, address(tokenOut));
        }
    }

    function _parseExactInInputs(bytes calldata inputs)
        internal
        pure
        returns (address recipient, uint256 amountIn, uint256 amountOutMin, bool payerIsUser)
    {
        // equivalent: abi.decode(inputs, (address, uint256, uint256, bytes, bool))
        assembly {
            recipient := calldataload(inputs.offset)
            amountIn := calldataload(add(inputs.offset, 0x20))
            amountOutMin := calldataload(add(inputs.offset, 0x40))
            payerIsUser := calldataload(add(inputs.offset, 0x80))
        }
    }

    function _parseExactOutInputs(bytes calldata inputs)
        internal
        pure
        returns (address recipient, uint256 amountOut, uint256 amountInMax, bool payerIsUser)
    {
        // equivalent: abi.decode(inputs, (address, uint256, uint256, bytes, bool))
        assembly {
            recipient := calldataload(inputs.offset)
            amountOut := calldataload(add(inputs.offset, 0x20))
            amountInMax := calldataload(add(inputs.offset, 0x40))
            payerIsUser := calldataload(add(inputs.offset, 0x80))
        }
    }
}
