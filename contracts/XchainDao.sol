//SPDX-License-Identifier: Unlicense
pragma solidity >=0.6.0 <0.8.0;

import "hardhat/console.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/proxy/Initializable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "./UpgradeableOwnable.sol";
import "./ReentrancyGuardPausable.sol";
import "./IValidatorDelegation.sol";
import "./ValidatorDelegationFactory.sol";
import "solidity-rlp/contracts/RLPReader.sol";


contract XchainDao is UpgradeableOwnable, Initializable, ReentrancyGuardPausable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    using RLPReader for bytes;
    using RLPReader for RLPReader.RLPItem;

    /*
    * A sorted doubly linked list with validators sorted in descending order.
    *
    * The list is a modification of the following audited SortedDoublyLinkedList:
    * https://github.com/livepeer/protocol/blob/master/contracts/libraries/SortedDoublyLL.sol
    *
    * - Public functions with parameters have been made internal to save gas, and given an external wrapper function for external access
    */

    IERC20 public daoToken;

    // Information for a Validator in the list
    struct Validator {
        address signer;                  // signer of the Validator
        uint256 amount;                  // Validator's amount + delegatedAmount used for sorting
        address nextId;                  // Id of next Validator (smaller amount) in the list
        address prevId;                  // Id of previous Validator (larger amount) in the list
        uint256 delegatedAmount;
        address delegation;
    }

    struct Unbond {
        uint256 amount;
        uint256 unstakeEpoch;
    }

    // Information for the list
    // Head of the list. Also the Validator in the list with the largest amount
    address public head;
    // Tail of the list. Also the Validator in the list with the smallest amount
    address public tail;
    uint256 public maxSize;                            // Maximum size of the list
    uint256 public size;                               // Current size of the list
    mapping (address => Validator) public validators;  // Track the corresponding ids for each validator in the list
    mapping(address => Unbond) public unbonds;
    mapping(address => uint256) public lastActiveEpochs;

    uint256 public withdrawalDelay;

    function initialize(
        address[] calldata _initialSigners,
        address _validatorDelegationFactory,
        IERC20 _daoToken,
        uint256 _withdrawalDelay
    )
        external
        initializer
        onlyOwner
    {
        epochs[0].currentSigners = _initialSigners;
        validatorDelegationFactory = ValidatorDelegationFactory(_validatorDelegationFactory);
        daoToken = _daoToken;
        withdrawalDelay = _withdrawalDelay;
    }

    /*
     * @dev Set the maximum size of the list
     * @param _size Maximum size
     */
    function setMaxSize(uint256 _size) public onlyOwner {
        maxSize = _size;
    }

    /*
     * @dev Add a validator to the list
     * @param _id Validator's id
     * @param _amount Validator's amount
     * @param _prevId Id of previous validator for the insert position
     * @param _nextId Id of next validator for the insert position
     */
    function _insert(
        address _id,
        address signer,
        uint256 _amount,
        uint256 _delegatedAmount,
        address _delegation,
        address _prevId,
        address _nextId
    ) internal
    {
        // List must not already contain validator
        require(!contains(_id), "validator exsits");
        // Validator id must not be null
        require(_id != address(0), "unavailable id");
        // amount must be non-zero
        require(_amount > 0, "amount must be non-zero");

        address prevId = _prevId;
        address nextId = _nextId;

        if (!_validInsertPosition(_amount, prevId, nextId)) {
            // Sender's hint was not a valid insert position
            // Use sender's hint to find a valid insert position
            (prevId, nextId) = _findInsertPosition(_amount, prevId, nextId);
        }

        validators[_id].amount = _amount;
        validators[_id].signer = signer;
        validators[_id].delegatedAmount = _delegatedAmount;
        if (_delegation == address(0)) {
            validators[_id].delegation = validatorDelegationFactory.create(_id);
        } else {
            validators[_id].delegation = _delegation;
        }

        if (prevId == address(0) && nextId == address(0)) {
            // Insert as head and tail
            head = _id;
            tail = _id;
        } else if (prevId == address(0)) {
            // Insert before `prevId` as the head
            validators[_id].nextId = head;
            validators[head].prevId = _id;
            head = _id;
        } else if (nextId == address(0)) {
            // Insert after `nextId` as the tail
            validators[_id].prevId = tail;
            validators[tail].nextId = _id;
            tail = _id;
        } else {
            // Insert at insert position between `prevId` and `nextId`
            validators[_id].nextId = nextId;
            validators[_id].prevId = prevId;
            validators[prevId].nextId = _id;
            validators[nextId].prevId = _id;
        }

        size = size.add(1);
    }

    /*
     * @dev Remove a validator from the list
     * @param _id Validator's id
     */
    function _remove(address _id) internal {
        // List must contain the Validator
        require(contains(_id), "validator not exsit");

        if (size > 1) {
            // List contains more than a single Validator
            if (_id == head) {
                // The removed Validator is the head
                // Set head to next Validator
                head = validators[_id].nextId;
                // Set prev pointer of new head to null
                validators[head].prevId = address(0);
            } else if (_id == tail) {
                // The removed Validator is the tail
                // Set tail to previous Validator
                tail = validators[_id].prevId;
                // Set next pointer of new tail to null
                validators[tail].nextId = address(0);
            } else {
                // The removed Validator is neither the head nor the tail
                // Set next pointer of previous Validator to the next Validator
                validators[validators[_id].prevId].nextId = validators[_id].nextId;
                // Set prev pointer of next Validator to the previous Validator
                validators[validators[_id].nextId].prevId = validators[_id].prevId;
            }
        } else {
            // List contains a single Validator
            // Set the head and tail to null
            head = address(0);
            tail = address(0);
        }

        delete validators[_id];
        size = size.sub(1);
    }

    /*
     * @dev Update the amount of a validator in the list
     * @param _id Validator's id
     * @param _newAmount Validator's new amount
     * @param _prevId Id of previous validator for the new insert position
     * @param _nextId Id of next validator for the new insert position
     */
    function _updateAmount(address _id, uint256 _newAmount, address _prevId, address _nextId) internal {
        // List must contain the Validator
        require(contains(_id) && _newAmount > 0, "failed");
        address signer = validators[_id].signer;
        uint256 _delegatedAmount = validators[_id].delegatedAmount;
        address _delegation = validators[_id].delegation;

        // Remove Validator from the list
        _remove(_id);

        _insert(_id, signer, _newAmount, _delegatedAmount, _delegation, _prevId, _nextId);
    }

    /*
     * @dev Checks if the list contains a Validator
     * @param _id id of validator
     */
    function contains(address _id) public view returns (bool) {
        // Add prevId&nextId check because validator is still in the list just before it need be removed when amount+delegatedAmount = 0
        // Amounts check in case of only one validator
        return validators[_id].amount > 0 ||
            !(validators[_id].prevId == address(0) && validators[_id].nextId == address(0));
    }

    /*
     * @dev Checks if the list is empty
     */
    function isEmpty() public view returns (bool) {
        return size == 0;
    }

    /*
     * @dev Returns the current size of the list
     */
    function getSize() public view returns (uint256) {
        return size;
    }

    /*
     * @dev Returns the maximum size of the list
     */
    function getMaxSize() public view returns (uint256) {
        return maxSize;
    }

    /*
     * @dev Returns the amount of a validator in the list
     * @param _id Validator's id
     */
    function getAmount(address _id) public view returns (uint256) {
        return validators[_id].amount.sub(validators[_id].delegatedAmount);
    }

    /*
     * @dev Returns the first Validator in the list (Validator with the largest amount)
     */
    function getFirst() public view returns (address) {
        return head;
    }

    /*
     * @dev Returns the last Validator in the list (Validator with the smallest amount)
     */
    function getLast() public view returns (address) {
        return tail;
    }

    /*
     * @dev Returns the next validator (with a smaller amount) in the list for a given validator
     * @param _id Validator's id
     */
    function getNext(address _id) public view returns (address) {
        return validators[_id].nextId;
    }

    /*
     * @dev Returns the previous validator (with a larger amount) in the list for a given validator
     * @param _id Validator's id
     */
    function getPrev(address _id) public view returns (address) {
        return validators[_id].prevId;
    }

    /*
     * @dev Returns all validators
     */
    function getAll() public view returns (address[] memory) {
        uint256 i;
        address idx = head;
        address[] memory ret = new address[](size);
        while (idx != address(0)) {
            ret[i++] = idx;
            idx = validators[idx].nextId;
        }
        return ret;
    }

    /*
     * @dev Check if a pair of Validators is a valid insertion point for a new Validator with the given amount
     * @param _amount Validator's amount
     * @param _prevId Id of previous Validator for the insert position
     * @param _nextId Id of next Validator for the insert position
     */
    function validInsertPosition(uint256 _amount, address _prevId, address _nextId) external view returns (bool) {
        return _validInsertPosition(_amount, _prevId, _nextId);
    }

    function _validInsertPosition(uint256 _amount, address _prevId, address _nextId) internal view returns (bool) {
        if (_prevId == address(0) && _nextId == address(0)) {
            // `(null, null)` is a valid insert position if the list is empty
            return isEmpty();
        } else if (_prevId == address(0)) {
            // `(null, _nextId)` is a valid insert position if `_nextId` is the head of the list
            return head == _nextId && _amount >= validators[_nextId].amount;
        } else if (_nextId == address(0)) {
            // `(_prevId, null)` is a valid insert position if `_prevId` is the tail of the list
            return tail == _prevId && _amount <= validators[_prevId].amount;
        } else {
            // `(_prevId, _nextId)` is a valid insert position if they are adjacent validators and `_amount` falls between the two validators' amounts
            return validators[_prevId].nextId == _nextId && validators[_prevId].amount >= _amount && _amount >= validators[_nextId].amount;
        }
    }

    /*
     * @dev Descend the list (larger amounts to smaller amounts) to find a valid insert position
     * @param _amount Validator's amount
     * @param _startId Id of validator to start ascending the list from
     */
    function descendList(uint256 _amount, address _startId) internal view returns (address, address) {
        // If `_startId` is the head, check if the insert position is before the head
        if (head == _startId && _amount >= validators[_startId].amount) {
            return (address(0), _startId);
        }

        address prevId = _startId;
        address nextId = validators[prevId].nextId;

        // Descend the list until we reach the end or until we find a valid insert position
        while (prevId != address(0) && !_validInsertPosition(_amount, prevId, nextId)) {
            prevId = validators[prevId].nextId;
            nextId = validators[prevId].nextId;
        }

        return (prevId, nextId);
    }

    /*
     * @dev Ascend the list (smaller amounts to larger amounts) to find a valid insert position
     * @param _amount Validator's amount
     * @param _startId Id of validator to start descending the list from
     */
    function ascendList(uint256 _amount, address _startId) internal view returns (address, address) {
        // If `_startId` is the tail, check if the insert position is after the tail
        if (tail == _startId && _amount <= validators[_startId].amount) {
            return (_startId, address(0));
        }

        address nextId = _startId;
        address prevId = validators[nextId].prevId;

        // Ascend the list until we reach the end or until we find a valid insertion point
        while (nextId != address(0) && !_validInsertPosition(_amount, prevId, nextId)) {
            nextId = validators[nextId].prevId;
            prevId = validators[nextId].prevId;
        }

        return (prevId, nextId);
    }

    /*
     * @dev Find the insert position for a new validator with the given amount
     * @param _amount Validator's amount
     * @param _prevId Id of previous validator for the insert position
     * @param _nextId Id of next validator for the insert position
     */
    function findInsertPosition(
        uint256 _amount,
        address _prevId,
        address _nextId
    ) external view returns (address, address)
    {
        return _findInsertPosition(_amount, _prevId, _nextId);
    }

    function _findInsertPosition(
        uint256 _amount,
        address _prevId,
        address _nextId
    ) internal view returns (address, address)
    {
        address prevId = _prevId;
        address nextId = _nextId;

        if (prevId != address(0)) {
            if (!contains(prevId) || _amount > validators[prevId].amount) {
                // `prevId` does not exist anymore or now has a smaller amount than the given amount
                prevId = address(0);
            }
        }

        if (nextId != address(0)) {
            if (!contains(nextId) || _amount < validators[nextId].amount) {
                // `nextId` does not exist anymore or now has a larger amount than the given amount
                nextId = address(0);
            }
        }

        if (prevId == address(0) && nextId == address(0)) {
            // No hint - descend list starting from head
            return descendList(_amount, head);
        } else if (prevId == address(0)) {
            // No `prevId` for hint - ascend list starting from `nextId`
            return ascendList(_amount, nextId);
        } else if (nextId == address(0)) {
            // No `nextId` for hint - descend list starting from `prevId`
            return descendList(_amount, prevId);
        } else {
            // Descend list starting from `prevId`
            return descendList(_amount, prevId);
        }
    }

    // ============================================ Epoch =======================================================

    struct EpochInfo {
        address[] nextSigners;
        address[] currentSigners;
        mapping(address => SignInfo) signInfos;
        uint256 signedValidators;
        uint256 endAt;

        mapping(address => uint256) rewardData;  // Token => Amount reward for the epoch
        mapping(uint256 => bool) rewardClaimed;  // Cosigner index => whether reward is claimed
    }

    struct SignInfo {
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    uint256 public currentEpoch;
    uint256 public epochEndAt;
    mapping(uint256 => EpochInfo) public epochs;

    /*
     * Stake DAO token and become a validator
     */
    function stake(address signer, address _prevId, address _nextId, uint256 amount) external {
        require(unbonds[msg.sender].amount == 0 && amount > 0, "No staking");
        daoToken.safeTransferFrom(msg.sender, address(this), amount);
        _insert(msg.sender, signer, amount, 0, address(0), _prevId, _nextId);
    }

    function addStake(address _prevId, address _nextId, uint256 amount) external {
        require(unbonds[msg.sender].amount == 0, "No restaking");

        daoToken.safeTransferFrom(msg.sender, address(this), amount);
        _updateAmount(msg.sender, validators[msg.sender].amount.add(amount), _prevId, _nextId);
    }

    function unstake(address _prevId, address _nextId) external {
        require(unbonds[msg.sender].amount == 0, "No unstaking");

        if (!isSignerIn(validators[msg.sender].signer, epochs[currentEpoch].currentSigners)) {
            require(isValidatorWithdrawable(msg.sender), "Not withdrawable");
            daoToken.safeTransfer(
                msg.sender,
                validators[msg.sender].amount.sub(validators[msg.sender].delegatedAmount)
            );
        } else {
            unbonds[msg.sender].unstakeEpoch = currentEpoch;
            unbonds[msg.sender].amount = validators[msg.sender].amount.sub(validators[msg.sender].delegatedAmount);
        }

        if (validators[msg.sender].delegatedAmount > 0) {
            _updateAmount(msg.sender, validators[msg.sender].delegatedAmount, _prevId, _nextId);
        } else {
            _remove(msg.sender);
        }
    }

    function claimUnstake() external {
        require(unbonds[msg.sender].amount > 0, "unbond amount is zero");
        require(
            isUnstakeTokensWithdrawable(unbonds[msg.sender].unstakeEpoch),
            "unbond not expired"
        );
        daoToken.safeTransfer(msg.sender, unbonds[msg.sender].amount);
        unbonds[msg.sender].amount = 0;
        unbonds[msg.sender].unstakeEpoch = 0;
    }

    function isCurrentSigner(address signer) public view returns (bool) {
        return isSignerIn(signer, epochs[currentEpoch].currentSigners);
    }

    function startNewEpoch(uint16[] calldata orders) external {
        _startNewEpoch(orders, true);
    }

    function isSignerIn(address signer, address[] memory signerList) internal pure returns (bool) {
        uint256 totalSigners = signerList.length;

        for (uint256 i = 0; i < totalSigners; i++) {
            if (signerList[i] == signer)
                return true;
        }

        return false;
    }

    function _startNewEpoch(uint16[] memory orders, bool expireCheck) internal {
        if (expireCheck) {
            require(block.timestamp >= epochEndAt, "epoch not expired");
        }

        bool isValidatorSetChanged = false;
        if (epochs[currentEpoch].signedValidators >= (epochs[currentEpoch].currentSigners.length * 2 / 3) + 1) {
            isValidatorSetChanged = true;
        }

        epochs[currentEpoch].endAt = block.timestamp;
        currentEpoch = currentEpoch + 1;

        if (isValidatorSetChanged) {
            address[] memory lastSigners = epochs[currentEpoch].currentSigners;
            epochs[currentEpoch].currentSigners = epochs[currentEpoch - 1].nextSigners;
            address[] memory currentSigners = epochs[currentEpoch].currentSigners;
            for (uint256 i = 0; i < lastSigners.length; i++) {
                if (!isSignerIn(lastSigners[i], currentSigners)) {
                    lastActiveEpochs[lastSigners[i]] = currentEpoch - 1;
                }
            }
        } else {
            epochs[currentEpoch].currentSigners = epochs[currentEpoch - 1].currentSigners;
        }

        uint256 targetSize = size < maxSize ? size : maxSize;

        address[] memory selectedSigners = new address[](targetSize);
        address[] memory orderedSigners = new address[](targetSize);

        address validator = head;

        // Select validators
        for (uint256 i = 0; i < targetSize; i++) {
            selectedSigners[i] = validators[validator].signer;
            validator = validators[validator].nextId;
            if (validator == address(0)) {
                break;
            }
        }

        // Order validators by addresses
        for (uint256 i = 0; i < targetSize; i++) {
            require(selectedSigners[orders[i]] != address(0), "ORD_NOT_EXIST");
            orderedSigners[i] = selectedSigners[orders[i]];
            selectedSigners[orders[i]] = address(0);

            if (i != 0) {
                require(orderedSigners[i - 1] >= orderedSigners[i], "ORD_WRONG"); // signer may be dup
            }
        }

        epochs[currentEpoch].nextSigners = orderedSigners;
        epochEndAt = block.timestamp + 30 days;
    }

    function getValiatorsHash(address[] memory users) public view returns (bytes32 hash) {
        hash = bytes32(currentEpoch);
        for (uint256 i = 0; i < users.length; i++) {
            hash = keccak256(abi.encodePacked(hash, users[i]));
        }
    }

    function getSignerCount(uint256 epoch) external view returns (uint256) {
        return epochs[epoch].currentSigners.length;
    }

    function getSigner(uint256 epoch, uint256 idx) external view returns (address) {
        return epochs[epoch].currentSigners[idx];
    }

    function getCurrentSigners(uint256 epoch) external view returns (address[] memory) {
        return epochs[epoch].currentSigners;
    }

    function getNextSigners(uint256 epoch) external view returns (address[] memory) {
        return epochs[epoch].nextSigners;
    }

    function signForValidators(uint8 v, bytes32 r, bytes32 s, uint256 idx) external {
        bytes32 hash = getValiatorsHash(epochs[currentEpoch].nextSigners);
        address signer = ecrecover(keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hash)), v, r, s);
        require(signer == epochs[currentEpoch].currentSigners[idx], "SIGN_WRONG");
        require(epochs[currentEpoch].signInfos[signer].r == 0, "SIGN_R");
        require(epochs[currentEpoch].signInfos[signer].s == 0, "SIGN_S");

        epochs[currentEpoch].signInfos[signer] = SignInfo({
            v: v,
            r: r,
            s: s
        });
        epochs[currentEpoch].signedValidators ++;
    }

    // ============================================ Reward =======================================================

    function rewardValidators(address token, uint256 amount) public {
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        // for validator in all validators
        //    add equally splitted reward
        //    or add to pool for gas optimization
        uint256 epoch = currentEpoch - 1;
        if (epochs[epoch].signedValidators < (epochs[epoch].currentSigners.length * 2 / 3) + 1) {
            // no reward for failed validator change
            return;
        }

        epochs[epoch].rewardData[token] += amount;
    }

    function claimReward(
        address signer,
        address token,
        uint16[] calldata signerIdcs,
        uint16[] calldata epochList
    ) external
    {
        uint256 amount = 0;
        for (uint256 i = 0; i < epochList.length; i++) {
            require(epochList[i] < currentEpoch, "CR_EPOCH");
            EpochInfo storage info = epochs[epochList[i]];
            require(info.currentSigners[signerIdcs[i]] == signer, "CR_NOT_SIGNER");
            require(!info.rewardClaimed[signerIdcs[i]], "CR_CLAIMED");

            info.rewardClaimed[signerIdcs[i]] = true;
            // TODO need to change it after adding delegation
            amount += info.rewardData[token] / info.currentSigners.length;
        }

        IERC20(token).safeTransfer(signer, amount);
    }

    // ============================================ Delegators =======================================================
    ValidatorDelegationFactory validatorDelegationFactory;

    modifier onlyDelegation(address validatorId) {
        _assertDelegation(validatorId);
        _;
    }

    function epoch() public view returns (uint256) {
        return currentEpoch;
    }

    function getDaoToken() public view returns (address) {
        return address(daoToken);
    }

    function getValidatorSigner(address validatorId) public view returns (address) {
        return validators[validatorId].signer;
    }

    function isUnstakeTokensWithdrawable(uint unstakeEpoch) public view returns (bool) {
        return unstakeEpoch < currentEpoch &&
            block.timestamp >= epochs[unstakeEpoch].endAt.add(withdrawalDelay);
    }

    function isValidatorWithdrawable(address validatorId) public view returns (bool) {
        uint256 lastActiveEpoch = lastActiveEpochs[validators[validatorId].signer];
        return block.timestamp > epochs[lastActiveEpoch].endAt.add(withdrawalDelay);
    }

    function _assertDelegation(address validatorId) private view {
        require(validators[validatorId].delegation == msg.sender, "Invalid contract address");
    }

    function delegatedAmount(address validatorId) public view returns (uint256) {
        return validators[validatorId].delegatedAmount;
    }

    function getValidatorDelegationAddress(address validatorId) public view returns (address) {
        return validators[validatorId].delegation;
    }

    function getValidatorUnbond(address validatorId) public view returns (uint256, uint256) {
        return (unbonds[validatorId].unstakeEpoch, unbonds[validatorId].amount);
    }

    function updateValidatorState(
        address validatorId,
        int256 amount,
        address delegator,
        address _prevId,
        address _nextId
    ) public onlyDelegation(validatorId)
    {
        if (amount >= 0) {
            increaseValidatorDelegatedAmount(validatorId, uint256(amount), _prevId, _nextId);
            require(daoToken.transferFrom(delegator, address(this), uint256(amount)), "deposit failed");
        } else {
            decreaseValidatorDelegatedAmount(validatorId, uint256(amount * -1), _prevId, _nextId);
            require(daoToken.transfer(delegator, uint256(amount * -1)), "Insufficient amount");
        }
    }

    function increaseValidatorDelegatedAmount(
        address validatorId,
        uint256 amount,
        address _prevId,
        address _nextId
    ) private
    {

        validators[validatorId].amount = validators[validatorId].amount.add(amount);
        validators[validatorId].delegatedAmount = validators[validatorId].delegatedAmount.add(amount);
        _updateAmount(validatorId, validators[validatorId].amount, _prevId, _nextId);
    }

    function decreaseValidatorDelegatedAmount(
        address validatorId,
        uint256 amount,
        address _prevId,
        address _nextId
    ) public onlyDelegation(validatorId)
    {
        validators[validatorId].amount = validators[validatorId].amount.sub(amount);
        validators[validatorId].delegatedAmount = validators[validatorId].delegatedAmount.sub(amount);
        if (validators[validatorId].amount > 0) {
            _updateAmount(validatorId, validators[validatorId].amount, _prevId, _nextId);
        } else {
            _remove(validatorId);
        }
    }

}
