//SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.6.0 <0.8.0;

import "hardhat/console.sol";
import {UpgradeableOwnableProxy} from "./UpgradeableOwnableProxy.sol";
import {ValidatorDelegation} from "./ValidatorDelegation.sol";

contract ValidatorDelegationFactory {
    /**
       - factory to create new validatorDelegation contracts
    */
    function create(address validatorId) public returns (address) {
        ValidatorDelegation delegation = new ValidatorDelegation();
        UpgradeableOwnableProxy proxy = new UpgradeableOwnableProxy(address(delegation), "");

        address proxyAddr = address(proxy);

        (bool success, bytes memory data) = proxyAddr.call{ gas: gasleft() }(
            abi.encodeWithSelector(
                ValidatorDelegation(proxyAddr).initialize.selector,
                validatorId,
                msg.sender
            )
        );
        require(success, string(data));

        return proxyAddr;
    }
}
