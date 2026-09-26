// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

library ByteHasher {
    /// @dev Creates a keccak256 hash of a bytestring, shifted right 8 bits so it fits in the SNARK scalar field.
    function hashToField(bytes memory value) internal pure returns (uint256) {
        return uint256(keccak256(value)) >> 8;
    }
}
