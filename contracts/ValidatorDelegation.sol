//SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.6.0 <0.8.0;

import "hardhat/console.sol";
import {ERC20NonTradable} from "./ERC20NonTradable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {UpgradeableOwnable} from "./UpgradeableOwnable.sol";
import {IXChainDao} from "./IXChainDao.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/Initializable.sol";


contract ValidatorDelegation is ERC20NonTradable, UpgradeableOwnable, Initializable {
    struct DelegatorUnbond {
        uint256 shares;
        uint256 unstakeEpoch;
    }

    uint256 constant EXCHANGE_RATE_PRECISION = 10**29;

    IXChainDao public xChainDao;
    address public validatorId;

    bool public locked;

    uint256 public withdrawPool;
    uint256 public withdrawShares;

    mapping(address => DelegatorUnbond) public unbonds;

    address[] delegators;
    mapping(address => uint256) delegatorsIdx;

    modifier onlyWhenUnlocked() {
        _assertUnlocked();
        _;
    }

    // solium-disable-next-line
    constructor () public ERC20("", "") {}

    function initialize(address _validatorId, address _xChainDao) external initializer {
        validatorId = _validatorId;
        xChainDao = IXChainDao(_xChainDao);
        transferOwnership(_xChainDao);

        locked = false;
    }

    function _assertUnlocked() private view {
        require(!locked, "locked");
    }

    function lock() external onlyOwner {
        locked = true;
    }

    /**
        Public Methods
     */

    function exchangeRate() public view returns (uint256) {
        uint256 totalShares = totalSupply();
        uint256 precision = _getRatePrecision();
        return totalShares == 0 ? precision : xChainDao.delegatedAmount(validatorId).mul(precision).div(totalShares);
    }

    /*
     * @dev Returns all delegators 
     */
    function getDelegators() public view returns (address[] memory) {
        return delegators;
    }

    function getTotalStake(address user) public view returns (uint256, uint256) {
        uint256 shares = balanceOf(user);
        uint256 rate = exchangeRate();
        if (shares == 0) {
            return (0, rate);
        }

        return (rate.mul(shares).div(_getRatePrecision()), rate);
    }

    function withdrawExchangeRate() public view returns (uint256) {
        uint256 precision = _getRatePrecision();
        uint256 _withdrawShares = withdrawShares;
        return _withdrawShares == 0 ? precision : withdrawPool.mul(precision).div(_withdrawShares);
    }

    function buyVoucher(
        uint256 _amount,
        uint256 _minSharesToMint,
        address _prevId,
        address _nextId
    ) external returns(uint256 amountToDeposit)
    {
        amountToDeposit = _buyShares(_amount, _minSharesToMint, msg.sender, _prevId, _nextId);
        if (delegatorsIdx[msg.sender] == 0) {
            _addDelegator();
        }

        return amountToDeposit;
    }

    function sellVoucher(uint256 claimAmount, uint256 maximumSharesToBurn, address _prevId, address _nextId) external {
        // first get how much staked in total and compare to target unstake amount
        (uint256 totalStaked, uint256 rate) = getTotalStake(msg.sender);
        require(totalStaked != 0 && totalStaked >= claimAmount, "Too much requested");

        // convert requested amount back to shares
        uint256 precision = _getRatePrecision();
        uint256 shares = claimAmount.mul(precision).div(rate);
        require(shares <= maximumSharesToBurn, "too much slippage");

        _burn(msg.sender, shares);

        {
        address signer = xChainDao.getValidatorSigner(validatorId);
        bool isCurrentSigner = xChainDao.isCurrentSigner(signer);

        // withdraw immediatelly
        if (!isCurrentSigner &&
            xChainDao.isValidatorWithdrawable(validatorId)
        ) {
            xChainDao.updateValidatorState(validatorId, -int256(claimAmount), msg.sender, _prevId, _nextId);
            if (balanceOf(msg.sender) == 0 && unbonds[msg.sender].shares == 0) {
                _removeDelegator();
            }
            return;
        }
        }

        // unbond
        xChainDao.updateValidatorState(validatorId, -int256(claimAmount), address(this), _prevId, _nextId);

        uint256 _withdrawPoolShare = claimAmount.mul(precision).div(withdrawExchangeRate());
        withdrawPool = withdrawPool.add(claimAmount);
        withdrawShares = withdrawShares.add(_withdrawPoolShare);

        DelegatorUnbond memory unbond = unbonds[msg.sender];
        unbond.shares = unbond.shares.add(_withdrawPoolShare);
        unbond.unstakeEpoch = xChainDao.epoch();
        unbonds[msg.sender] = unbond;
    }

    function unstakeClaimTokens() external {
        DelegatorUnbond memory unbond = unbonds[msg.sender];
        _unstakeClaimTokens(unbond);
        delete unbonds[msg.sender];
        if (balanceOf(msg.sender) == 0) {
            _removeDelegator();
        }
    }

    /**
        Private Methods
     */

    function _unstakeClaimTokens(DelegatorUnbond memory unbond) private returns(uint256) {
        uint256 shares = unbond.shares;
        require(shares > 0, "unbond amount is zero");
        require(xChainDao.isUnstakeTokensWithdrawable(unbond.unstakeEpoch), "unbond not expired");

        uint256 _amount = withdrawExchangeRate().mul(shares).div(_getRatePrecision());
        withdrawShares = withdrawShares.sub(shares);
        withdrawPool = withdrawPool.sub(_amount);

        ERC20(xChainDao.getDaoToken()).transfer(msg.sender, _amount);

        return _amount;
    }

    function _buyShares(
        uint256 _amount,
        uint256 _minSharesToMint,
        address user,
        address _prevId,
        address _nextId
    ) private onlyWhenUnlocked returns (uint256)
    {
        uint256 amount = _amount;
        uint256 rate = exchangeRate();
        uint256 precision = _getRatePrecision();
        uint256 shares = amount.mul(precision).div(rate);
        require(shares >= _minSharesToMint, "Too much slippage");
        require(unbonds[user].shares == 0, "Ongoing exit");

        _mint(user, shares);

        // clamp amount of tokens in case resulted shares requires less tokens than anticipated
        amount = rate.mul(shares).div(precision);

        xChainDao.updateValidatorState(validatorId, int256(amount), msg.sender, _prevId, _nextId);

        return amount;
    }

    function _addDelegator() private {
        require(delegatorsIdx[msg.sender] == 0, "The delegator exists");
        delegators.push(msg.sender);
        delegatorsIdx[msg.sender] = delegators.length;
    }

    function _removeDelegator() private {
        require(delegatorsIdx[msg.sender] > 0, "The delegator doesn't exist");
        uint256 len = delegators.length;
        if (len > 1) {
            uint256 idx = delegatorsIdx[msg.sender];
            delegators[idx.sub(1)] = delegators[len.sub(1)];
            delegatorsIdx[delegators[len.sub(1)]] = idx;
        }
        delete delegators[len.sub(1)];
        delete delegatorsIdx[msg.sender];
    }

    function _getRatePrecision() private view returns (uint256) {
        return EXCHANGE_RATE_PRECISION;
    }

}
