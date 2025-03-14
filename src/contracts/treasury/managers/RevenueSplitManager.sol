// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FullMath} from '@uniswap/v4-core/src/libraries/FullMath.sol';

import {Flaunch} from '@flaunch/Flaunch.sol';
import {SingleTokenManager} from '@flaunch/treasury/managers/SingleTokenManager.sol';


/**
 * Allows a token to be escrowed to allow multiple recipients to receive a share of the
 * revenue earned from the token. This can allow for complex revenue distributions.
 */
contract RevenueSplitManager is SingleTokenManager {

    error InvalidRecipient();
    error InvalidRecipientShareTotal(uint _invalidTotal, uint _expectedValue);
    error UnableToSendRevenue(bytes _reason);

    event ManagerInitialized(address indexed _flaunch, uint indexed _tokenId, InitializeParams _params);
    event RevenueClaimed(address _recipient, uint _amountClaimed, uint _totalClaimed);

    /**
     * Defines a revenue recipient and the share that they will receive.
     *
     * @member recipients The share recipient of revenue
     * @member shares The 2dp percentage that the recipient will receive
     */
    struct RecipientShare {
        address recipient;
        uint16 share;
    }

    /**
     * Parameters passed during manager initialization.
     *
     * @member recipientShares Revenue recipients and their share
     */
    struct InitializeParams {
        RecipientShare[] recipientShares;
    }

    /// The amount that the `RevenueShare.share` values must sum to equal
    uint public constant VALID_SHARE_TOTAL = 100_00;

    /// The total revenue that has been claimed from the contract
    uint public totalClaimed;

    /// Track the amount claimed for each recipient
    mapping (address _recipient => uint _claimed) public amountClaimed;

    /// Stores the share initialized for each recipient
    mapping (address _recipient => uint _share) public recipientShares;

    /**
     * Sets up the contract with the initial required contract addresses.
     *
     * @param _treasuryManagerFactory The {TreasuryManagerFactory} that will launch this implementation
     */
    constructor (address _treasuryManagerFactory) SingleTokenManager(_treasuryManagerFactory) {
        // ..
    }

    /**
     * Registers the tokenId passed by the initialization and ensures that it is the
     * only one registered to the manager. We also set our revenue recipients and their
     * respective shares.
     *
     * @param _flaunchToken The Flaunch token that is being deposited
     * @param _data Onboarding variables
     */
    function _initialize(FlaunchToken calldata _flaunchToken, bytes calldata _data) internal override depositSingleToken(_flaunchToken) {
        // Unpack our initial manager settings
        (InitializeParams memory params) = abi.decode(_data, (InitializeParams));

        // Iterate over all recipient shares to ensure that it equals a valid amount, as well
        // as ensuring we have no zero addresses.
        uint16 totalShare;
        for (uint i; i < params.recipientShares.length; ++i) {
            // Reference the `RecipientShare`
            RecipientShare memory recipientShare = params.recipientShares[i];

            // Ensure that the recipient is not a zero address
            if (recipientShare.recipient == address(0)) {
                revert InvalidRecipient();
            }

            // Map the share value to the recipient
            recipientShares[recipientShare.recipient] = recipientShare.share;

            // Increase our total share to validate against after the loop
            totalShare += recipientShare.share;
        }

        // Ensure that the sum of the recipient shares equals the valid value
        if (totalShare != VALID_SHARE_TOTAL) {
            revert InvalidRecipientShareTotal(totalShare, VALID_SHARE_TOTAL);
        }

        emit ManagerInitialized(address(flaunchToken.flaunch), flaunchToken.tokenId, params);
    }

    /**
     * We need to calculate the share of the fees that the calling recipient is allocated. This
     * means that even though one recipient claims, the other's aren't forced to do so.
     *
     * To do this, we need to find the total amount of ETH that has been claimed from all time and
     * find the caller's allocation, then reducing this by the amount already claimed. The remaining
     * value should be claimable.
     */
    function claim() public tokenExists {
        // Ensure that only a valid recipient can call this
        uint recipientShare = recipientShares[msg.sender];
        if (recipientShare == 0) revert InvalidRecipient();

        // Find the balance held in the manager before claiming fees
        uint startBalance = payable(address(this)).balance;

        // Withdraw fees earned from the ERC721, unwrapping into ETH
        flaunchToken.flaunch.positionManager().withdrawFees(address(this), true);

        // We can now determine the ETH claimed in fees
        uint newBalance = payable(address(this)).balance;

        // Increase our total amount claimed with new fees
        totalClaimed += newBalance - startBalance;

        // Calculate the allocation for the caller, based on their individual lifetime claims and
        // the total amount that the manager has claimed. This will prevent recipients for claiming
        // more than their share.
        uint allocation = FullMath.mulDiv(totalClaimed, recipientShare, VALID_SHARE_TOTAL);
        allocation -= amountClaimed[msg.sender];

        // If the user has no allocation available, then we can exit early
        if (allocation == 0) {
            return ;
        }

        // Increase the amount that the caller has claimed
        amountClaimed[msg.sender] += allocation;

        // Send the ETH fees to the recipient
        (bool success, bytes memory data) = payable(msg.sender).call{value: allocation}('');
        if (!success) {
            revert UnableToSendRevenue(data);
        }

        emit RevenueClaimed(msg.sender, allocation, amountClaimed[msg.sender]);
    }

}
