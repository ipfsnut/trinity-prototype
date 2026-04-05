// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Finds a CREATE2 salt that produces a token address below a ceiling.
///         Ensures token is always currency0 (lower address) in V4 pool keys.
library TokenMiner {
    function find(address deployer, address ceiling, bytes32 initCodeHash)
        internal
        pure
        returns (uint256 salt, address tokenAddress)
    {
        for (salt = 0; salt < 10_000_000; salt++) {
            tokenAddress = computeAddress(deployer, salt, initCodeHash);
            if (tokenAddress < ceiling) {
                return (salt, tokenAddress);
            }
        }
        revert("TokenMiner: no valid salt found in 10M iterations");
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
