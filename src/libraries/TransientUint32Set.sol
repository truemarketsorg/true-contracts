// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice In-memory (transaction scoped) uint32 set built on EIP-1153 transient storage.
library TransientUint32Set {
    type Set is bytes32;

    error IndexOutOfBounds(uint256 index, uint256 length);

    function wrap(bytes32 slot) internal pure returns (Set) {
        return Set.wrap(slot);
    }

    function length(Set set) internal view returns (uint256 result) {
        bytes32 slot = Set.unwrap(set);
        assembly ("memory-safe") {
            result := tload(slot)
        }
    }

    function contains(Set set, uint32 value) internal view returns (bool) {
        return _loadUint(_indexSlot(set, value)) != 0;
    }

    function at(Set set, uint256 index) internal view returns (uint32) {
        uint256 len = length(set);
        if (index >= len) revert IndexOutOfBounds(index, len);

        return uint32(_loadUint(_valueSlot(set, index)));
    }

    function values(Set set) internal view returns (uint32[] memory result) {
        uint256 len = length(set);
        result = new uint32[](len);

        for (uint256 i; i < len; ++i) {
            result[i] = at(set, i);
        }
    }

    function add(Set set, uint32 value) internal returns (bool) {
        bytes32 indexSlot = _indexSlot(set, value);

        if (_loadUint(indexSlot) != 0) return false;

        bytes32 lengthSlot = Set.unwrap(set);
        uint256 len = _loadUint(lengthSlot);
        uint256 newLen = len + 1;

        _storeUint(_valueSlot(set, len), value);
        _storeUint(indexSlot, newLen);
        _storeUint(lengthSlot, newLen);

        return true;
    }

    function remove(Set set, uint32 value) internal returns (bool) {
        bytes32 indexSlot = _indexSlot(set, value);
        uint256 indexPlusOne = _loadUint(indexSlot);

        if (indexPlusOne == 0) return false;

        bytes32 lengthSlot = Set.unwrap(set);
        uint256 len = _loadUint(lengthSlot);
        uint256 index = indexPlusOne - 1;
        uint256 lastIndex = len - 1;

        if (index != lastIndex) {
            bytes32 lastValueSlot = _valueSlot(set, lastIndex);
            uint256 lastValue = _loadUint(lastValueSlot);

            _storeUint(_valueSlot(set, index), lastValue);
            _storeUint(_indexSlot(set, uint32(lastValue)), index + 1);
        }

        _storeUint(_valueSlot(set, lastIndex), 0);
        _storeUint(indexSlot, 0);
        _storeUint(lengthSlot, len - 1);

        return true;
    }

    function _loadUint(bytes32 slot) private view returns (uint256 result) {
        assembly ("memory-safe") {
            result := tload(slot)
        }
    }

    function _storeUint(bytes32 slot, uint256 value) private {
        assembly ("memory-safe") {
            tstore(slot, value)
        }
    }

    function _valueBaseSlot(Set set) private pure returns (bytes32 result) {
        bytes32 slot = Set.unwrap(set);
        assembly ("memory-safe") {
            mstore(0x00, slot)
            result := keccak256(0x00, 0x20)
        }
    }

    function _valueSlot(Set set, uint256 index) private pure returns (bytes32 result) {
        bytes32 base = _valueBaseSlot(set);
        assembly ("memory-safe") {
            result := add(base, index)
        }
    }

    function _indexBaseSlot(Set set) private pure returns (bytes32) {
        return bytes32(uint256(Set.unwrap(set)) ^ uint256(1));
    }

    function _indexSlot(Set set, uint32 value) private pure returns (bytes32 result) {
        bytes32 base = _indexBaseSlot(set);
        assembly ("memory-safe") {
            mstore(0x00, value)
            mstore(0x20, base)
            result := keccak256(0x00, 0x40)
        }
    }
}
