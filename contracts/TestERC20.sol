//SPDX-License-Identifier: MIT
pragma solidity ^0.6.0;

import "hardhat/console.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";


contract TestERC20 is ERC20 {
    constructor() ERC20("Test", "TEST") public {}

    function mint(address addr, uint256 amount) public {
        _mint(addr, amount);
    }
}
