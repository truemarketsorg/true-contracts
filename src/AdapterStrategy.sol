// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import {IAdapterCallbacks} from "./interfaces/IAdapterCallbacks.sol";
import {IUniversalRouterAdapterStrategy} from "./interfaces/IUniversalRouterAdapterStrategy.sol";

abstract contract AdapterStrategy is IUniversalRouterAdapterStrategy {
    error NotAdapter();

    modifier onlyAdapter() {
        if (msg.sender != address(adapter)) revert NotAdapter();
        _;
    }

    IAdapterCallbacks public immutable adapter;

    constructor(address _adapter) {
        adapter = IAdapterCallbacks(_adapter);
    }
}
