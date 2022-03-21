//SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.6.0 <0.8.0;

/**
 * @dev Interface of ValidatorDelegation
 */
interface IValidatorDelegation {
   function lock() external;

   function slash(
       uint256 validatorStake,
       uint256 delegatedAmount,
       uint256 totalAmountToSlash,
       address _prevId,
       address _nextId
   ) external returns(uint256);
}
