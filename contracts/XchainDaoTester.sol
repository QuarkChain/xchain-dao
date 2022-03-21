// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "./XchainDao.sol";


contract XchainDaoTester is XchainDao {
    function startNewEpochTest(uint16[] calldata orders) external {
        _startNewEpoch(orders, false);
    }
}
