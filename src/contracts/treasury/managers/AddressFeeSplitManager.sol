// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {EnumerableSet} from '@openzeppelin/contracts/utils/structs/EnumerableSet.sol';

import {FullMath} from '@uniswap/v4-core/src/libraries/FullMath.sol';

import {FeeSplitManager} from '@flaunch/treasury/managers/FeeSplitManager.sol';


/**
 * Allows multiple recipient addresses to be allocated a share of the revenue earned from
 * memestreams held within the manager.
 */
contract AddressFeeSplitManager is FeeSplitManager {

    using EnumerableSet for EnumerableSet.UintSet;

    error InsufficientSharesToTransfer();
    error InvalidShareTransferRecipient();

    event ManagerInitialized(address _owner, InitializeParams _params);
    event RecipientAdded(address indexed _recipient, uint _share);
    event RecipientShareTransferred(address indexed _oldRecipient, address indexed _newRecipient, uint _share);
    event RevenueClaimed(address indexed _recipient, uint _amountClaimed);

    /**
     * Defines a revenue recipient and the share that they will receive.
     *
     * @member recipient The share recipient of revenue
     * @member share The 5dp percentage that the recipient will receive
     */
    struct RecipientShare {
        address recipient;
        uint share;
    }

    /**
     * Parameters passed during manager initialization.
     *
     * @member creatorShare The share that a creator will earn from their token
     * @member recipientShares Revenue recipients and their share
     */
    struct InitializeParams {
        uint creatorShare;
        RecipientShare[] recipientShares;
    }

    /// Track the amount claimed for each recipient
    mapping (address _recipient => uint _claimed) public amountClaimed;

    /// Stores the share initialized for each recipient
    mapping (address _recipient => uint _share) internal _recipientShares;

    /**
     * Sets up the contract with the initial required contract addresses.
     *
     * @param _treasuryManagerFactory The {TreasuryManagerFactory} that will launch this implementation
     */
    constructor (address _treasuryManagerFactory) FeeSplitManager(_treasuryManagerFactory) {
        // ..
    }

    /**
     * Registers the owner of the manager and assigns the recipients and their respective
     * shares.
     *
     * @dev The recipients and their shares are immutable.
     *
     * @param _owner Owner of the manager
     * @param _data Initialization variables
     */
    function _initialize(address _owner, bytes calldata _data) internal override {
        // Unpack our initial manager settings
        (InitializeParams memory params) = abi.decode(_data, (InitializeParams));

        // Check that we have at least one recipient
        if (params.recipientShares.length == 0) {
            revert InvalidRecipient();
        }

        // Validate and set our creator share
        _setCreatorShare(params.creatorShare);

        // We emit our initialization event first, as the subgraph may need this information
        // indexed before we emit recipient share events.
        emit ManagerInitialized(_owner, params);

        // Iterate over all recipient shares to ensure that it equals a valid amount, as well
        // as ensuring we have no zero addresses.
        uint totalShare;
        RecipientShare memory _recipientShare;

        for (uint i; i < params.recipientShares.length; ++i) {
            // Reference the `RecipientShare`
            _recipientShare = params.recipientShares[i];

            // Ensure that the recipient is not a zero address
            if (_recipientShare.recipient == address(0)) {
                revert InvalidRecipient();
            }

            // Ensure that the recipient is not already added to the shares, as this would
            // overwrite their previous allocation and throw off our calculations.
            if (_recipientShares[_recipientShare.recipient] != 0) {
                revert InvalidRecipient();
            }

            // Map the share value to the recipient
            _recipientShares[_recipientShare.recipient] = _recipientShare.share;
            emit RecipientAdded(_recipientShare.recipient, _recipientShare.share);

            // Increase our total share to validate against after the loop
            totalShare += _recipientShare.share;
        }

        // Ensure that the sum of the recipient shares equals the valid value
        if (totalShare != VALID_SHARE_TOTAL) {
            revert InvalidRecipientShareTotal(totalShare, VALID_SHARE_TOTAL);
        }
    }

    /**
     * Finds the ETH balance that is claimable by the `_recipient`.
     *
     * @param _recipient The account to find the balance of
     *
     * @return balance_ The amount of ETH available to claim by the `_recipient`
     */
    function balances(address _recipient) public view override returns (uint balance_) {
        (uint shareBalance, uint creatorBalance) = _balances(_recipient);
        balance_ = shareBalance + creatorBalance;
    }

    /**
     * Finds a breakdown of balances available to the recipient for both their share and also
     * the allocation from any tokens that they are the creator of.
     *
     * @param _recipient The account to find the balances of
     *
     * @return shareBalance_ The balance available from the `recipientShare`
     * @return creatorBalance_ The balance available from creator fees
     */
    function _balances(address _recipient) internal view returns (uint shareBalance_, uint creatorBalance_) {
        // If the `_recipient` has been allocated a share, then we find the balance that
        // is available for them to claim.
        if (_recipientShares[_recipient] != 0) {
            // Get the total balance that is owed to the user
            shareBalance_ = FullMath.mulDiv(managerFees(), _recipientShares[_recipient], VALID_SHARE_TOTAL);

            // Reduce this amount by the amount already claimed by the recipient
            shareBalance_ -= amountClaimed[_recipient];
        }

        // We then need to check if the `_recipient` is the creator of any tokens, and if they
        // are then we need to find out the available amounts to claim.
        creatorBalance_ = pendingCreatorFees(_recipient);
    }

    /**
     * Allows for a claim call to be made without requiring any additional requirements for
     * bytes to be passed, as these would always be unused for this FeeSplit Manager.
     *
     * @return uint The amount claimed from the call
     */
    function claim() public returns (uint) {
        return _claim(abi.encode(''));
    }

    /**
     * Gets the percentage share that a recipient address is allocated from the whole of the
     * revenue fees.
     *
     * @dev We need this function separate to the mapping definition as contract inheritence
     * requires us to override with the `_data` parameter too.
     *
     * @param _recipient The recipient address to check against
     * @param _data No additional data is required
     *
     * @return uint The percentage (to 5dp) that the recipient is allocated
     */
    function recipientShare(address _recipient, bytes memory _data) public view override returns (uint) {
        return _recipientShares[_recipient];
    }

    /**
     * Checks if the recipient has either been given a share at initialization or has any tokens
     * that they created held in the manager.
     *
     * @param _recipient The recipient address to check against
     * @param _data No additional data is required
     *
     * @return bool If the recipient is valid to receive an allocation
     */
    function isValidRecipient(address _recipient, bytes memory _data) public view override returns (bool) {
        return _recipientShares[_recipient] != 0 || _creatorTokens[_recipient].length() != 0;
    }

    /**
     * This function calculates the allocation that the recipient is owed, and also registers the
     * claim within the manager to offset against future claims. This captures both recipient shares
     * and creator shares.
     *
     * @dev The `_recipient` is set to be the initial `msg.sender`
     *
     * @param _recipient The recipient address to claim against
     * @param _data No additional data is required
     *
     * @return allocation_ The allocation claimed by the user
     */
    function _captureClaim(address _recipient, bytes memory _data) internal override returns (uint allocation_) {
        // Get our share balance
        (uint shareBalance, uint creatorBalance) = _balances(_recipient);

        // If the recipient has a share allocation, then increase the amount that the recipient
        // has claimed against their share and register this against their allocation
        if (shareBalance != 0) {
            amountClaimed[_recipient] += shareBalance;
            allocation_ += shareBalance;
        }

        // If the recipient has a creator balance to claim, then action the claim against their
        // tokens and then increase their allocation by the balance.
        if (creatorBalance != 0) {
            // Iterate over the tokens that the user created to register the claim
            for (uint i; i < _creatorTokens[_recipient].length(); ++i) {
                _creatorClaim(internalIds[_creatorTokens[_recipient].at(i)]);
            }

            allocation_ += creatorBalance;
        }

        emit RevenueClaimed(_recipient, allocation_);
    }

    /**
     * Allows the user to transfer their recipient share to another user.
     *
     * @dev The recipient share can only be transferred by the address that owns the recipient
     * share. If the new recipient already has a recipient share, then these will be merged.
     *
     * @param _newRecipient The new owner of the recipient share
     */
    function transferRecipientShare(address _newRecipient) public {
        // Don't allow the sender to transfer to themselves
        if (msg.sender == _newRecipient || _newRecipient == address(0)) {
            revert InvalidShareTransferRecipient();
        }

        // Check that the sender actually has shares to transfer
        if (_recipientShares[msg.sender] == 0) {
            revert InsufficientSharesToTransfer();
        }

        // Capture the number of shares that we are migrating over
        uint oldRecipientShare = _recipientShares[msg.sender];

        // Migrate the recipient shares from the sender to the new recipient
        _recipientShares[_newRecipient] += oldRecipientShare;
        amountClaimed[_newRecipient] += amountClaimed[msg.sender];

        // Delete the senders current data
        _recipientShares[msg.sender] = 0;
        amountClaimed[msg.sender] = 0;

        emit RecipientShareTransferred(msg.sender, _newRecipient, oldRecipientShare);
    }

    /**
     * Transfers the revenue fee allocation (ETH) to the recipient.
     *
     * @param _recipient The recipient address to claim against
     * @param _allocation The total fees allocated to the recipient
     * @param _data No additional data is required
     */
    function _dispatchRevenue(address _recipient, uint _allocation, bytes memory _data) internal override {
        // Send the ETH fees to the recipient
        (bool success, bytes memory data) = payable(_recipient).call{value: _allocation}('');
        if (!success) {
            revert UnableToSendRevenue(data);
        }
    }

}
