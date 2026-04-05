// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title TrinityToken
/// @notice 1B supply ERC-20. Minted entirely to deployer on construction.
contract TrinityToken is ERC20 {
    constructor(address _recipient) ERC20("Trinity", "TRIN") {
        _mint(_recipient, 1_000_000_000 * 10 ** 18);
    }
}
