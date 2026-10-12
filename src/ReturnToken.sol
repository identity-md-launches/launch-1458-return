// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title Return (RETURN)
/// @notice A fixed supply of one billion tokens with 18 decimals, minted once to the deployer.
/// @dev The constructor caller receives every token, including when deployment is through a factory.
///      There are no external mint, burn, administrative, or upgrade functions.
contract ReturnToken is ERC20 {
    /// @notice The initial and permanent total supply, expressed in the token's smallest units.
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000 * 10 ** 18;

    constructor() ERC20("Return", "RETURN") {
        _mint(msg.sender, INITIAL_SUPPLY);
    }
}
