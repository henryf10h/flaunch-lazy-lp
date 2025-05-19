// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {EnumerableSet} from '@openzeppelin/contracts/utils/structs/EnumerableSet.sol';
import {ReentrancyGuard} from '@solady/utils/ReentrancyGuard.sol';

import {TreasuryManager, ITreasuryManager} from '@flaunch/treasury/managers/TreasuryManager.sol';
import {SupportsCreatorTokens} from '@flaunch/treasury/managers/SupportsCreatorTokens.sol';


/**
 * Allows tokens to be escrowed to allow multiple recipients to receive a share of the
 * revenue earned from them. This can allow for complex revenue distributions.
 *
 * This contract has been built in an approach that should allow other contracts to inherit
 * it and determine how fees are split and spent.
 */
abstract contract FeeSplitManager is TreasuryManager, SupportsCreatorTokens, ReentrancyGuard  {

    using EnumerableSet for EnumerableSet.UintSet;

    error InvalidRecipient();
    error InvalidRecipientShareTotal(uint _share, uint _validShare);
    error UnableToSendRevenue(bytes _reason);

    event CreatorUpdated(address indexed _flaunch, uint indexed _tokenId, address _creator);

    /// The valid share that the split must equal
    uint public constant VALID_SHARE_TOTAL = 100_00000;

    /// The total fees that have been claimed for creators. We have a public getter for this
    /// that also includes pending fees.
    uint internal _creatorFees;

    /// The total fees that have been claimed for the split recipients
    uint public splitFees;

    /**
     * Sets up the contract with the initial required contract addresses.
     *
     * @param _treasuryManagerFactory The {TreasuryManagerFactory} that will launch this implementation
     */
    constructor (address _treasuryManagerFactory) TreasuryManager(_treasuryManagerFactory) SupportsCreatorTokens(_treasuryManagerFactory) {
        // ..
    }

    /**
     * Captures the creator of the token so that they can earn ongoing fees from their
     * contribution to the manager.
     *
     * @param _flaunchToken The FlaunchToken being depositted
     * @param _creator The creator of the FlaunchToken
     * @param _data Additional deposit data for the manager
     */
    function _deposit(FlaunchToken calldata _flaunchToken, address _creator, bytes calldata _data) internal override {
        _setCreatorToken(_flaunchToken, _creator, _data);
    }

    /**
     * Determines the balance available to claim by the recipient.
     *
     * @dev If this needs additional context, such as `_data`, then this function can be bypassed
     * and a new `balances` function created. This is just the recommended / standardised view
     * function.
     *
     * @param _recipient The account to find the balance of
     *
     * @return uint The amount of ETH available to claim by the `_recipient`
     */
    function balances(address _recipient) public view virtual returns (uint) {
        return 0;
    }

    /**
     * Determines the percentage share that a recipient address is allocated from the whole
     * of the revenue fees.
     *
     * @param _recipient The recipient address to check against
     * @param _data Any additional data required by the manager to calculate
     *
     * @return uint The percentage (to 5dp) that the recipient is allocated
     */
    function recipientShare(address _recipient, bytes memory _data) public view virtual returns (uint) {
        return 0;
    }

    /**
     * Checks if the recipient is valid to receive the allocation with the data that has been
     * provided.
     *
     * @param _recipient The recipient address to check against
     * @param _data Any additional data required by the manager to calculate
     *
     * @return bool If the recipient is valid to receive an allocation
     */
    function isValidRecipient(address _recipient, bytes memory _data) public view virtual returns (bool) {
        return false;
    }

    /**
     * Takes the total fee amount that a user is calculated to receive over all time. This must then
     * be reduced by any previously claimed fees, by any indexes that are required to be checked.
     *
     * @dev This, in nearly all cases, requires that the recipient list is immutable from the
     * point of initialization.
     *
     * @param _recipient The recipient address to claim against
     * @param _data Any additional data required by the manager to calculate
     *
     * @return uint The allocation claimed by the user
     */
    function _captureClaim(address _recipient, bytes memory _data) internal virtual returns (uint) {
        return 0;
    }

    /**
     * Handles the processing of the revenue fee allocation to the recipient.
     *
     * @param _recipient The recipient address to claim against
     * @param _allocation The total fees allocated to the recipient
     * @param _data Any additional data required by the manager to calculate
     */
    function _dispatchRevenue(address _recipient, uint _allocation, bytes memory _data) internal virtual {
        // ..
    }

    /**
     * Gets the total amount of fees held by the manager, including any fees that are pending
     * against the manager. These pending fees will be claimed during the recipient claim flow.
     *
     * @return uint The fees pending for the manager
     */
    function managerFees() public view returns (uint) {
        // Get the pending fees for the manager and add them to the already claimed manager
        // split fees (`splitFees`). If we have a creator fee, then we reduce our manager fees
        // by the creator share.
        uint pendingBalance = treasuryManagerFactory.feeEscrow().balances(address(this));
        return splitFees + pendingBalance - getCreatorFee(pendingBalance);
    }

    /**
     * Gets the total amount of fees allocated to creators, including any fees that are pending
     * against the manager. These pending fees will be claimed during the recipient claim flow.
     *
     * @dev This amount is split across all creators, not just an individual creator
     *
     * @return uint The fees pending for creators
     */
    function creatorFees() public view returns (uint) {
        // If we have no creator share allocated, then there will be no fees so we can exit early
        if (creatorShare == 0) {
            return 0;
        }

        // Get the pending fees for the manager and add the creator share of those to the already
        // claimed creator fees (`creatorFees`).
        uint pendingBalance = treasuryManagerFactory.feeEscrow().balances(address(this));
        return _creatorFees + getCreatorFee(pendingBalance);
    }

    /**
     * We need to calculate the share of the fees that the calling recipient is allocated. This
     * means that even though one recipient claims, the other's aren't forced to do so.
     *
     * To do this, we need to find the total amount of ETH that has been claimed from all time and
     * find the caller's allocation, then reducing this by the amount already claimed. The remaining
     * value should be claimable.
     *
     * @param _data Any additional data required by the manager to calculate
     *
     * @return allocation_ The amount claimed from the call
     */
    function _claim(bytes memory _data) internal nonReentrant returns (uint allocation_) {
        // Ensure that only a valid recipient can call this
        if (!isValidRecipient(msg.sender, _data)) {
            return 0;
        }

        // Withdraw fees earned from the held tokens, unwrapping into ETH, which will increment our
        // fee values in the `receive` function.
        treasuryManagerFactory.feeEscrow().withdrawFees(address(this), true);

        // Calculate the allocation for the caller, based on their individual lifetime claims and
        // the total amount that the manager has claimed. This will prevent recipients for claiming
        // more than their share.
        allocation_ = _captureClaim(msg.sender, _data);

        // If the user has an allocation, then we can dispatch this allocation
        if (allocation_ != 0) {
            _dispatchRevenue(msg.sender, allocation_, _data);
        }
    }

    /**
     * Allows the end-owner creator of the ERC721 to be updated by the intermediary platform. This
     * will change the recipient of fees that are earned from the token externally and can be used
     * for external validation of permissioned calls.
     *
     * @dev This can only be called by the `managerOwner`
     *
     * @param _flaunchToken The flaunch token whose creator is being updated
     * @param _creator The new end-owner creator address
     */
    function setCreator(ITreasuryManager.FlaunchToken calldata _flaunchToken, address payable _creator) public virtual onlyManagerOwner {
        // Ensure that the creator is not a zero address
        if (_creator == address(0)) {
            revert InvalidCreatorAddress();
        }

        // Map our flaunch token to the internalId
        uint internalId = flaunchTokenInternalIds[address(_flaunchToken.flaunch)][_flaunchToken.tokenId];

        // If the internalId does not exist, then we cannot update the creator
        if (internalId == 0) {
            revert UnknownFlaunchToken();
        }

        // Find the old creator and update their enumerable set
        address currentCreator = creator[address(_flaunchToken.flaunch)][_flaunchToken.tokenId];
        _creatorTokens[currentCreator].remove(internalId);

        // Update the pool creator and move the token into their enumerable set
        creator[address(_flaunchToken.flaunch)][_flaunchToken.tokenId] = _creator;
        _creatorTokens[_creator].add(internalId);

        emit CreatorUpdated(address(_flaunchToken.flaunch), _flaunchToken.tokenId, _creator);
    }

    /**
     * When we receive ETH from a source other than fee withdrawal or flETH unwrapping, then
     * we need to add this to our claimable amounts. This allows us to receive ETH from external
     * sources that will also be distributed to our recipient split.
     */
    receive () external override payable {
        // If we have received fees from our FeeEscrow, then this should be handled as a claim
        // from the fee allocations of ERC721 tokens. This means that we allocate a portion of
        // this fee to the creators pool
        if (msg.sender == address(treasuryManagerFactory.feeEscrow())) {
            uint creatorFee = getCreatorFee(msg.value);

            if (creatorFee != 0) {
                _creatorFees += creatorFee;
            }

            splitFees += msg.value - creatorFee;
        }
        // Otherwise, we have received ETH from an unknown source and as such we cannot
        // allocate any portion of this to a creator as our system will not understand which
        // creator should receive a share of it.
        else {
            splitFees += msg.value;
        }
    }

}
