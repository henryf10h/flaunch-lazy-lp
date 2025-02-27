// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PositionManager} from '@flaunch/PositionManager.sol';
import {Memecoin} from '@flaunch/Memecoin.sol';

import {FullMath} from '@uniswap/v4-core/src/libraries/FullMath.sol';

import {BaseAirdrop} from '@flaunch/creator-tools/BaseAirdrop.sol';
import {ISnapshotAirdrop} from '@flaunch-interfaces/ISnapshotAirdrop.sol';

/**
 * A contract that allows the creator to add an airdrop in any ERC20 token or ETH
 * for their memecoin holders, based on snapshot of their votes.
 */
contract SnapshotAirdrop is BaseAirdrop, ISnapshotAirdrop {

    /// The {PositionManager} contract address
    PositionManager public immutable positionManager;

    /// Holds a count of airdrops for each memecoin
    mapping (address _memecoin => uint _airdropsCount) public airdropsCount;

    /// Maps airdrop data for each memecoin's index to the airdrop
    mapping (address _memecoin => mapping(uint _index => AirdropData _airdrop)) internal _airdropData;

    /// Maps the airdrops that a user has claimed
    mapping (address _memecoin => mapping(uint _index => mapping(address _user => bool _isAirdropClaimed))) public isAirdropClaimed;

    /**
     * Sets our Ownable owner to the caller and maps our contract addresses.
     *
     * @param _fleth The {FLETH} contract address
     * @param _treasuryManagerFactory The {ITreasuryManagerFactory} contract address
     */
    constructor(address _fleth, address _treasuryManagerFactory, address _positionManager) BaseAirdrop(_fleth, _treasuryManagerFactory) {
        positionManager = PositionManager(payable(_positionManager));
    }

    /**
     * Allows the approved contracts to add a new token or ETH airdrop for the memecoin holders at this instance.
     * 
     * @dev If the airdrop is in ETH, the caller can send ETH to this contract which gets converted
     * into FLETH internally.
     * 
     * @param _memecoin The memecoin for which the airdrop is being added
     * @param _creator The creator of the airdrop
     * @param _token The token to be airdropped. address(0) for ETH
     * @param _amount The amount of tokens to be airdropped
     * @param _airdropEndTime The timestamp at which the airdrop ends
     */
    function addAirdrop(
        address _memecoin,
        address _creator,
        address _token,
        uint _amount,
        uint _airdropEndTime
    ) external payable override(ISnapshotAirdrop) onlyApprovedAirdropCreators returns (uint airdropIndex) {
        // only support memecoins flaunched by our {PositionManager}
        if (positionManager.poolKey(_memecoin).tickSpacing == 0) revert InvalidMemecoin();

        // Pull in the tokens from the sender
        uint amount = _pullTokens(_token, _amount);

        // Take snapshot of the balances
        uint totalSupply = Memecoin(_memecoin).totalSupply();  // not using 100e27 so as to account for token burns
        uint notEligibleSupply = Memecoin(_memecoin).balanceOf(address(positionManager)) + 
                Memecoin(_memecoin).balanceOf(address(positionManager.poolManager()));
        
        // Create our airdrop struct
        airdropIndex = airdropsCount[_memecoin];
        _airdropData[_memecoin][airdropIndex] = AirdropData({
            creator: _creator,
            token: _token,
            totalTokensToAirdrop: amount,
            memecoinHoldersTimestamp: block.timestamp,
            eligibleSupplySnapshot: totalSupply - notEligibleSupply,
            airdropEndTime: _airdropEndTime,
            amountLeft: amount
        });

        unchecked {
            ++airdropsCount[_memecoin];
        }

        emit NewAirdrop(_memecoin, airdropIndex, _airdropData[_memecoin][airdropIndex]);
    }

    /**
     * Allows a user to claim their airdrop amount
     * 
     * @param _memecoin The memecoin for which the airdrop is being claimed
     * @param _airdropIndex The index of the airdrop
     */
    function claim(address _memecoin, uint _airdropIndex) external override(ISnapshotAirdrop) {
        _claim(msg.sender, _memecoin, _airdropIndex);
    }

    /**
     * Allows a user to claim their airdrop amount for multiple airdrops
     * 
     * @param _memecoins The memecoins for which the airdrops are being claimed
     * @param _airdropIndices The indices of the airdrops
     */
    function claimMultiple(address[] calldata _memecoins, uint[] calldata _airdropIndices) external override(ISnapshotAirdrop) {
        if (_memecoins.length != _airdropIndices.length) revert IndexLengthMismatch();

        for (uint i = 0; i < _memecoins.length; i++) {
            _claim(msg.sender, _memecoins[i], _airdropIndices[i]);
        }
    }

    /**
     * Allows a user to claim their airdrop amount on behalf of another user
     * 
     * @param _claimant The recipient we are claiming on behalf of
     * @param _memecoin The memecoin for which the airdrop is being claimed
     * @param _airdropIndex The index of the airdrop
     */
    function proxyClaim(
        address _claimant,
        address _memecoin,
        uint _airdropIndex
    ) external override(ISnapshotAirdrop) onlyApprovedAirdropCreators {
        _claim(_claimant, _memecoin, _airdropIndex);
    }

    /**
     * Allows the creator to withdraw the tokens from the airdrop
     * 
     * @param _memecoin The memecoin for which the airdrop is being withdrawn
     * @param _airdropIndex The index of the airdrop
     */
    function creatorWithdraw(address _memecoin, uint _airdropIndex) external override(ISnapshotAirdrop) returns (uint tokensWithdrawn) {
        // Ensure that the airdrop specified is not currently active
        if (isAirdropActive(_memecoin, _airdropIndex)) revert AirdropInProgress();

        // Updates our airdrop to remove the number of tokens available
        AirdropData storage airdrop = _airdropData[_memecoin][_airdropIndex];

        // Ensure that the caller is the creator of the airdrop. This also checks that the airdrop existed.
        if (airdrop.creator != msg.sender) revert CallerIsNotCreator();

        tokensWithdrawn = airdrop.amountLeft;
        airdrop.amountLeft = 0;

        // Only withdraw tokens if we have an allocation
        if (tokensWithdrawn != 0) {
            _withdraw(airdrop.token, tokensWithdrawn);
            emit CreatorWithdraw(_memecoin, _airdropIndex, airdrop.creator, airdrop.token, tokensWithdrawn);
        }
    }

    /**
     * Returns the airdrop data for the given creator and index.
     *
     * @param _memecoin The memecoin for which the airdrop data is being requested
     * @param _airdropIndex The index of the airdrop
     *
     * @return AirdropData The airdrop data
     */
    function airdropData(address _memecoin, uint _airdropIndex) external view override(ISnapshotAirdrop) returns (AirdropData memory) {
        return _airdropData[_memecoin][_airdropIndex];
    }

    /**
     * Checks if the airdrop is active.
     *
     * @param _memecoin The memecoin for which the airdrop is being checked
     * @param _airdropIndex The index of the airdrop
     *
     * @return bool If the airdrop is currently active
     */
    function isAirdropActive(address _memecoin, uint _airdropIndex) public view override(ISnapshotAirdrop) returns (bool) {
        return _airdropData[_memecoin][_airdropIndex].airdropEndTime >= block.timestamp;
    }
    
    /**
     * Checks if the user is eligible for the airdrop and returns the claimable amount.
     *
     * @param _memecoin The memecoin for which the airdrop is being checked
     * @param _airdropIndex The index of the airdrop
     * @param _user The user for which the eligibility is being checked
     *
     * @return claimableAmount The claimable amount
     */
    function checkAirdropEligibility(address _memecoin, uint _airdropIndex, address _user) external view override(ISnapshotAirdrop) returns (uint claimableAmount) {
        AirdropData storage airdrop = _airdropData[_memecoin][_airdropIndex];
        uint claimantBalanceSnapshot = Memecoin(_memecoin).getPastVotes(_user, airdrop.memecoinHoldersTimestamp);

        claimableAmount = FullMath.mulDiv(airdrop.totalTokensToAirdrop, claimantBalanceSnapshot, airdrop.eligibleSupplySnapshot);
    }

    /**
     * Calculates the claimable amount for the `_claimant` based on their votes at the time of the snapshot, and
     * withdraws to the `msg.sender`
     * 
     * @param _claimant The recipient we are claiming on behalf of
     * @param _memecoin The memecoin for which the airdrop is being claimed
     * @param _airdropIndex The index of the airdrop
     */
    function _claim(address _claimant, address _memecoin, uint _airdropIndex) internal {
        // Ensure that the airdrop we have referenced is valid to be claimed against
        if (!isAirdropActive(_memecoin, _airdropIndex)) revert AirdropEnded();
        if (isAirdropClaimed[_memecoin][_airdropIndex][_claimant]) revert AirdropAlreadyClaimed();
        
        // Load our airdrop data
        AirdropData storage airdrop = _airdropData[_memecoin][_airdropIndex];

        uint claimantBalanceSnapshot = Memecoin(_memecoin).getPastVotes(_claimant, airdrop.memecoinHoldersTimestamp);
        if (claimantBalanceSnapshot == 0) revert NotEligible();

        // Calculate the amount of tokens to claim
        uint claimableAmount = FullMath.mulDiv(airdrop.totalTokensToAirdrop, claimantBalanceSnapshot, airdrop.eligibleSupplySnapshot);

        // Update our airdrop to mark is as claimed
        isAirdropClaimed[_memecoin][_airdropIndex][_claimant] = true;

        // Reduce the amount of tokens left in the airdrop
        airdrop.amountLeft -= claimableAmount;

        // Withdraw the tokens to the caller
        _withdraw(airdrop.token, claimableAmount);
        emit AirdropClaimed(_claimant, _memecoin, _airdropIndex, airdrop.token, claimableAmount);
    }
}
