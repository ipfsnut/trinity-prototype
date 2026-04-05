// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Finds a CREATE2 salt that produces a hook address with exact permission bits
library HookMiner {
    uint160 internal constant ALL_HOOK_MASK = uint160((1 << 14) - 1); // lower 14 bits
    function find(address deployer, uint160 requiredFlags, bytes32 initCodeHash)
        internal
        pure
        returns (uint256 salt, address hookAddress)
    {
        for (salt = 0; salt < 1_000_000; salt++) {
            hookAddress = computeAddress(deployer, salt, initCodeHash);
            if (uint160(hookAddress) & ALL_HOOK_MASK == requiredFlags) {
                return (salt, hookAddress);
            }
        }
        revert("HookMiner: no valid salt found in 1M iterations");
    }

    function computeAddress(address deployer, uint256 salt, bytes32 initCodeHash)
        internal
        pure
        returns (address)
    {
        return address(uint160(uint256(keccak256(abi.encodePacked(
            bytes1(0xff),
            deployer,
            bytes32(salt),
            initCodeHash
        )))));
    }
}
