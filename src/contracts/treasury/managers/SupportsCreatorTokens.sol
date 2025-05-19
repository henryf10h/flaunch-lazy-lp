// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {EnumerableSet} from '@openzeppelin/contracts/utils/structs/EnumerableSet.sol';

import {PoolId} from '@uniswap/v4-core/src/types/PoolId.sol';

import {TreasuryManagerFactory} from '@flaunch/treasury/managers/TreasuryManagerFactory.sol';

import {ITreasuryManager} from '@flaunch-interfaces/ITreasuryManager.sol';


/**
 * Extends functionality to allow the manager to allocate fees to creators that provide their
 * memestreams into the manager.
 */
abstract contract SupportsCreatorTokens {

    using EnumerableSet for EnumerableSet.UintSet;

    error CreatorShareAlreadyInitialized();
    error InvalidClaimer();
    error InvalidCreatorAddress();
    error InvalidCreatorShare();
    error UnknownPoolId();

    event CreatorShareInitialized(uint _creatorShare);

    /// The valid share that the split must equal
    uint public constant MAX_CREATOR_SHARE = 100_00000;

    /// Holds an internal ID counter
    uint internal _nextInternalId;

    /// The amount that a creator will receive before other recipients
    uint public creatorShare;

    /// Whether the creator share has been initialized
    bool internal _creatorShareInitialized;

    /// The {TreasuryManagerFactory} contract
    TreasuryManagerFactory internal immutable _treasuryManagerFactory;

    /// Stores an enumerable set of all creator's tokens
    mapping (address _creator => EnumerableSet.UintSet _creatorTokens) internal _creatorTokens;

    /// Maps a flaunch contract and tokenId to an internal ID
    mapping (uint _internalId => ITreasuryManager.FlaunchToken _flaunchToken) public internalIds;
    mapping (address _flaunch => mapping (uint _tokenId => uint _internalId)) public flaunchTokenInternalIds;

    /// Maps a flaunch contract and tokenId to the creator
    mapping (address _flaunch => mapping (uint _tokenId => address _creator)) public creator;

    /// Tracks the total claims for creators and tokens
    mapping (address _creator => uint _claimed) public creatorTotalClaimed;
    mapping (address _flaunch => mapping (uint _tokenId => uint _claimed)) public tokenTotalClaimed;

    /// Internally caches the totalFeeAllocation claim checkpoints for pools
    mapping (PoolId _poolId => uint _amount) internal _totalFeeAllocation;

    /// Maps a FlaunchToken to a PoolId for simple lookups
    mapping (uint _internalId => PoolId _poolId) public tokenPoolId;

    /**
     * Sets up the contract with the initial required contract addresses.
     *
     * @param treasuryManagerFactory The {TreasuryManagerFactory} that will launch this implementation
     */
    constructor (address treasuryManagerFactory) {
        _treasuryManagerFactory = TreasuryManagerFactory(treasuryManagerFactory);
    }

    /**
     * Validates and sets the creator share being set.
     *
     * @param _creatorShare The percentage that creators will receive from their fees (5dp)
     */
    function _setCreatorShare(uint _creatorShare) internal {
        // Ensure that the creator share has not already been initialized
        if (_creatorShareInitialized) {
            revert CreatorShareAlreadyInitialized();
        }

        // Ensure that the creator share is valid
        if (_creatorShare > MAX_CREATOR_SHARE) {
            revert InvalidCreatorShare();
        }

        // Set the creator share and mark it as initialized
        creatorShare = _creatorShare;
        _creatorShareInitialized = true;

        // Emit the event that the creator share has been initialized
        emit CreatorShareInitialized(_creatorShare);
    }

    /**
     * Handles a token being depositted into the manager.
     *
     * @param _flaunchToken The FlaunchToken being depositted
     * @param _creator The creator of the FlaunchToken
     * @param _data Additional deposit data for the manager
     */
    function _setCreatorToken(ITreasuryManager.FlaunchToken calldata _flaunchToken, address _creator, bytes calldata _data) internal {
        // Set the end-owner creator, ensuring that it is not a zero address
        if (_creator == address(0)) revert InvalidCreatorAddress();
        creator[address(_flaunchToken.flaunch)][_flaunchToken.tokenId] = _creator;

        // Capture the current `totalFeeAllocation` of the provided token
        PoolId poolId = _flaunchToken.flaunch.poolId(_flaunchToken.tokenId);
        _totalFeeAllocation[poolId] = _treasuryManagerFactory.feeEscrow().totalFeesAllocated(poolId);

        // Increment our internalId counter and set up our internal mappings
        ++_nextInternalId;

        internalIds[_nextInternalId] = _flaunchToken;
        flaunchTokenInternalIds[address(_flaunchToken.flaunch)][_flaunchToken.tokenId] = _nextInternalId;
        _creatorTokens[_creator].add(_nextInternalId);

        // Map our PoolId for simple lookups
        tokenPoolId[_nextInternalId] = poolId;
    }

    /**
     * Helper function to show the next internalId that will be generated.
     *
     * @return The next internalId that will be assigned
     */
    function nextInternalId() public view returns (uint) {
        return _nextInternalId + 1;
    }

    /**
     * Returns an array of all FlaunchToken data assigned to the creator.
     *
     * @param _creator The creator to retrieve the FlaunchTokens for
     *
     * @return flaunchTokens_ The FlaunchTokens belonging to the _creator
     */
    function tokens(address _creator) public view returns (ITreasuryManager.FlaunchToken[] memory flaunchTokens_) {
        uint creatorTokensLength = _creatorTokens[_creator].length();
        flaunchTokens_ = new ITreasuryManager.FlaunchToken[](creatorTokensLength);
        for (uint i; i < creatorTokensLength; ++i) {
            // Convert the internalId to the FlaunchToken and pass to the claim function
            flaunchTokens_[i] = internalIds[_creatorTokens[_creator].at(i)];
        }
    }

    /**
     * Allows the caller to check the balance of their position. This will check all of the
     * creator's tokens.
     *
     * @param _recipient The account to find the balance of
     *
     * @return balance_ The amount of ETH available to claim by the `_recipient`
     */
    function pendingCreatorFees(address _recipient) public view returns (uint balance_) {
        if (creatorShare == 0) {
            return 0;
        }

        for (uint i; i < _creatorTokens[_recipient].length(); ++i) {
            // Get the PoolId from the FlaunchToken, mapped from the internalId
            PoolId poolId = getPoolId(internalIds[_creatorTokens[_recipient].at(i)]);

            // Get the difference that the user can claim by finding the total fee allocation made
            // to this pool and reducing it by the cached internal total fee allocation.
            uint newTotalFeeAllocation = _treasuryManagerFactory.feeEscrow().totalFeesAllocated(poolId) - _totalFeeAllocation[poolId];
            balance_ += getCreatorFee(newTotalFeeAllocation);
        }
    }

    /**
     * Makes a claim as the creator to withdraw fees to their address.
     *
     * @param _flaunchToken The FlaunchToken being claimed against
     *
     * @return creatorAvailableClaim_ The amount claimed by the creator
     */
    function _creatorClaim(ITreasuryManager.FlaunchToken memory _flaunchToken) internal returns (uint creatorAvailableClaim_) {
        // Validate that the `msg.sender` is the stored creator for the claim
        if (msg.sender != creator[address(_flaunchToken.flaunch)][_flaunchToken.tokenId]) {
            revert InvalidClaimer();
        }

        if (creatorShare == 0) {
            return 0;
        }

        // Get the PoolId from the FlaunchToken
        PoolId poolId = getPoolId(_flaunchToken);

        // Get the difference that the user can claim by finding the total fee allocation made
        // to this pool and reducing it by the cached internal total fee allocation.
        uint newTotalFeeAllocation = _treasuryManagerFactory.feeEscrow().totalFeesAllocated(poolId);
        creatorAvailableClaim_ = getCreatorFee(newTotalFeeAllocation - _totalFeeAllocation[poolId]);

        // Update the cached total fee allocation
        _totalFeeAllocation[poolId] = newTotalFeeAllocation;

        // If we have nothing available to claim, exit early
        if (creatorAvailableClaim_ == 0) {
            return 0;
        }

        // Increase the total amount that the creator has claimed
        creatorTotalClaimed[msg.sender] += creatorAvailableClaim_;
        tokenTotalClaimed[address(_flaunchToken.flaunch)][_flaunchToken.tokenId] += creatorAvailableClaim_;
    }

    /**
     * Calculates the protocol fee that will be taken from the amount passed in.
     *
     * @param _amount The amount to calculate the protocol fee from
     *
     * @return creatorFee_ The creator fee to be taken from the amount
     */
    function getCreatorFee(uint _amount) public view returns (uint creatorFee_) {
        // If the creator has no share, then we can exit early
        if (creatorShare == 0) {
            return 0;
        }

        return (_amount * creatorShare + MAX_CREATOR_SHARE - 1) / MAX_CREATOR_SHARE;
    }

    /**
     * Maps a FlaunchToken to a PoolId.
     *
     * @param _flaunchToken The FlaunchToken to lookup
     *
     * @return poolId_ The corresponding PoolId
     */
    function getPoolId(ITreasuryManager.FlaunchToken memory _flaunchToken) public view returns (PoolId poolId_) {
        // Find our internalId. If this cannot be found then we revert as it's an unknown token
        uint internalId = flaunchTokenInternalIds[address(_flaunchToken.flaunch)][_flaunchToken.tokenId];
        if (internalId == 0) {
            revert UnknownPoolId();
        }

        poolId_ = tokenPoolId[internalId];
    }

}
