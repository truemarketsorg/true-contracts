pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {ISwapValidator} from "../interfaces/ISwapValidator.sol";
import {Roles} from "../libraries/Roles.sol";

contract TruthMarketSwapValidator is ISwapValidator, AccessControl {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    // State variables
    IPoolManager public immutable poolManager;

    struct PoolBoundaries {
        int24 tickLowerBoundary;
        int24 tickUpperBoundary;
        bool isSet;
    }

    mapping(PoolId => PoolBoundaries) public poolBoundaries;

    // Errors
    error TickOutOfBounds(int24 currentTick, int24 lowerBound, int24 upperBound);
    error InvalidBoundaries();

    // Events
    event BoundariesUpdated(PoolId indexed poolId, int24 newLower, int24 newUpper);

    constructor(IPoolManager _poolManager, address _admin) {
        poolManager = _poolManager;
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
    }

    function validateAfterSwap(address, PoolKey calldata poolKey, SwapParams calldata, BalanceDelta, bytes calldata)
        external
        view
        override
    {
        PoolId poolId = poolKey.toId();
        PoolBoundaries memory boundaries = poolBoundaries[poolId];

        // If boundaries haven't been set for this pool, use TickMath min/max
        int24 lowerBound;
        int24 upperBound;

        if (!boundaries.isSet) {
            lowerBound = TickMath.MIN_TICK;
            upperBound = TickMath.MAX_TICK;
        } else {
            lowerBound = boundaries.tickLowerBoundary;
            upperBound = boundaries.tickUpperBoundary;
        }

        // Get current tick after swap
        (, int24 currentTick,,) = poolManager.getSlot0(poolId);

        // Check boundaries
        if (currentTick < lowerBound || currentTick > upperBound) {
            revert TickOutOfBounds(currentTick, lowerBound, upperBound);
        }
    }

    function setBoundaries(PoolId poolId, int24 _tickLowerBoundary, int24 _tickUpperBoundary)
        external
        onlyRole(Roles.OPERATOR_ROLE)
    {
        if (_tickLowerBoundary >= _tickUpperBoundary) revert InvalidBoundaries();

        poolBoundaries[poolId] = PoolBoundaries({
            tickLowerBoundary: _tickLowerBoundary,
            tickUpperBoundary: _tickUpperBoundary,
            isSet: true
        });

        emit BoundariesUpdated(poolId, _tickLowerBoundary, _tickUpperBoundary);
    }
}
