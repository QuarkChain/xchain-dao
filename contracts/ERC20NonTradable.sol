//SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.6.0 <0.8.0;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";


abstract contract ERC20NonTradable is ERC20 {
    function _approve(
        address owner,
        address spender,
        uint256 value
    )
        internal
        override
    {
        revert("disabled");
    }
}
