// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Flaunch} from '@flaunch/Flaunch.sol';
import {SingleTokenManager} from '@flaunch/treasury/managers/SingleTokenManager.sol';


/**
 * Acts as a middleware for revenue claims, allowing external protocols to build on top of Flaunch
 * and be able to have more granular control over the revenue yielded.
 */
contract RevenueManager is SingleTokenManager {

    error InvalidCreatorAddress();
    error InvalidProtocolFee();

    event CreatorUpdated(address _creator);
    event ProtocolRecipientUpdated(address _protocolRecipient);
    event ProtocolFeeUpdated(uint _protocolFee);
    event ManagerInitialized(address indexed _flaunch, uint indexed _tokenId, InitializeParams _params);
    event RevenueClaimed(address _creator, uint _creatorAmount, bool _creatorSuccess, address _protocol, uint _protocolAmount, bool _protocolSuccess);

    /**
     * Parameters passed during manager initialization.
     *
     * @member creator The end-owner creator of the ERC721
     * @member protocolRecipient The recipient of protocol fees
     * @member protocolFee The fee that the external protocol will take (2dp)
     */
    struct InitializeParams {
        address payable creator;
        address payable protocolRecipient;
        uint protocolFee;
    }

    /// The maximum value of a protocol fee
    uint internal constant MAX_PROTOCOL_FEE = 100_00;

    /// The end-owner creator of the token
    address payable public creator;

    /// The recipient of the protocol revenue split
    address payable public protocolRecipient;

    /// The fee that the external protocol will take (2dp)
    uint public protocolFee;

    /// Keep a track of the running totals of claimed fees
    uint public creatorTotalClaim;
    uint public protocolTotalClaim;

    /**
     * Sets up the contract with the initial required contract addresses.
     *
     * @param _treasuryManagerFactory The {TreasuryManagerFactory} that will launch this implementation
     */
    constructor (address _treasuryManagerFactory) SingleTokenManager(_treasuryManagerFactory) {
        // ..
    }

    /**
     * Registers the tokenId passed by the initialization and ensures that it is the only one
     * registered to the manager. We also set our initial configurations, though the majority
     * of these can be updated by the owner at a later date.
     *
     * @param _flaunchToken The Flaunch token that is being deposited
     * @param _data Onboarding variables
     */
    function _initialize(FlaunchToken calldata _flaunchToken, bytes calldata _data) internal override depositSingleToken(_flaunchToken) {
        // Unpack our initial manager settings
        (InitializeParams memory params) = abi.decode(_data, (InitializeParams));

        // Set the end-owner creator, ensuring that it is not a zero address
        if (params.creator == address(0)) revert InvalidCreatorAddress();
        creator = params.creator;

        // Update our protocol related variables. These will also emit relevant events and
        // validate the values passed.
        if (params.protocolRecipient != address(0)) {
            protocolRecipient = params.protocolRecipient;
        }

        if (params.protocolFee > MAX_PROTOCOL_FEE) revert InvalidProtocolFee();
        protocolFee = params.protocolFee;

        emit ManagerInitialized(address(flaunchToken.flaunch), flaunchToken.tokenId, params);
    }

    /**
     * Calls `withdrawFees` against the {PositionManager} to claim any fees allocated to this
     * escrow contract. If a protocol recipient has been set, then the revenue is split first
     * before being sent to the end-owner.
     *
     * @return creatorAmount_ The amount received by the end-owner
     * @return protocolAmount_ The amount received by the protocol
     */
    function claim() public tokenExists returns (uint creatorAmount_, uint protocolAmount_) {
        // Withdraw fees earned from the ERC721, unwrapping into ETH
        flaunchToken.flaunch.positionManager().withdrawFees(address(this), true);

        // Discover the balance held following our fee withdrawal. We don't just want to include
        // the fees withdrawn, but also any other ETH resting in the manager.
        uint balance = payable(address(this)).balance;

        // If no ETH balance has been withdrawn, just return zero values early
        if (balance == 0) {
            return (creatorAmount_, protocolAmount_);
        }

        // If we have a protocol recipient, then we need to split the revenue. If no protocol
        // recipient is set, then the creator receives the full amount.
        creatorAmount_ = balance;
        if (protocolRecipient != address(0)) {
            // Split the amount of revenue between protocol and end-owner creator, avoiding dust
            protocolAmount_ = balance * protocolFee / MAX_PROTOCOL_FEE;
            creatorAmount_ -= protocolAmount_;
        }

        // Disperse our revenue between the two parties, without validating receipt as we
        // don't want either call to prevent the other receiving fees.
        (bool creatorSuccess,) = payable(creator).call{value: creatorAmount_}('');
        if (creatorSuccess) { creatorTotalClaim += creatorAmount_; }

        bool protocolSuccess;
        if (protocolAmount_ != 0) {
            (protocolSuccess,) = payable(protocolRecipient).call{value: protocolAmount_}('');
            if (protocolSuccess) { protocolTotalClaim += protocolAmount_; }
        }

        emit RevenueClaimed(
            creator, creatorAmount_, creatorSuccess,
            protocolRecipient, protocolAmount_, protocolSuccess
        );
    }

    /**
     * Allows the protocol recipient to be updated. This can allow a zero value that will
     * bypass the protocol recipient taking a protocol fee during the claim.
     *
     * @dev This can only be called by the contract owner
     *
     * @param _protocolRecipient The new protocol recipient address
     */
    function setProtocolRecipient(address payable _protocolRecipient) public onlyManagerOwner {
        protocolRecipient = _protocolRecipient;
        emit ProtocolRecipientUpdated(_protocolRecipient);
    }

    /**
     * Allows the end-owner creator of the ERC721 to be updated by the intermediary.
     *
     * @dev This can only be called by the contract owner
     *
     * @param _creator The new end-owner creator address
     */
    function setCreator(address payable _creator) public onlyManagerOwner {
        if (_creator == address(0)) {
            revert InvalidCreatorAddress();
        }

        creator = _creator;
        emit CreatorUpdated(_creator);
    }

    /**
     * Allows the protocol recipient to be updated. This percentage value is accurate to 2dp
     * and must be less than, or equal to, 100% (10000).
     *
     * @dev This can only be called by the contract owner
     *
     * @param _protocolFee The new protocol fee
     */
    function setProtocolFee(uint _protocolFee) public onlyManagerOwner {
        // Ensure that the protocol fee is not greater than 100%
        if (_protocolFee > MAX_PROTOCOL_FEE) {
            revert InvalidProtocolFee();
        }

        protocolFee = _protocolFee;
        emit ProtocolFeeUpdated(_protocolFee);
    }

}
