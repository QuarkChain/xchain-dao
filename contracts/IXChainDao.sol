//SPDX-License-Identifier: Unlicense
pragma solidity >=0.6.0 <0.8.0;

/**
 * @dev Interface of XChainDao
 */
interface IXChainDao {
    function updateValidatorState(
        address validatorId,
        int256 amount,
        address delegator,
        address _prevId,
        address _nextId
    ) external;

    function epoch() external view returns (uint256);

    function getDaoToken() external view returns (address);

    function delegatedAmount(address validatorId) external view returns(uint256);

    function getValidatorSigner(address validatorId) external view returns(address);

    function isCurrentSigner(address signer) external view returns(bool);

    function isUnstakeTokensWithdrawable(uint256 unstakeEpoch) external view returns (bool);

    function isValidatorWithdrawable(address validatorId) external view returns (bool);

}
