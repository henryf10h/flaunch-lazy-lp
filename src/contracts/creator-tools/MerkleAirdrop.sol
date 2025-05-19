// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {MerkleProofLib} from '@solady/utils/MerkleProofLib.sol';

import {IMerkleAirdrop} from '@flaunch-interfaces/IMerkleAirdrop.sol';
import {BaseAirdrop} from './BaseAirdrop.sol';


/**
 * A contract that allows the creator to create a merkle airdrop in any ERC20 token or ETH.
 */
contract MerkleAirdrop is BaseAirdrop, IMerkleAirdrop {

    /// Holds a count of airdrops that each creator has added. This is used to validate the
    /// `_airdropIndex` that is passed in with calls.
    mapping (address _creator => uint _airdropsCount) public airdropsCount;

    /// Maps airdrop data for each creator's index to the airdrop
    mapping (address _creator => mapping(uint _index => AirdropData _airdrop)) internal _airdropData;

    /// Maps the airdrops that a user has claimed
    mapping (address _creator => mapping(uint _index => mapping(address _user => bool _isAirdropClaimed))) public isAirdropClaimed;

    /**
     * Sets our Ownable owner to the caller and maps our contract addresses.
     *
     * @param _fleth The {FLETH} contract address
     * @param _treasuryManagerFactory The {ITreasuryManagerFactory} contract address
     */
    constructor(address _fleth, address _treasuryManagerFactory) BaseAirdrop(_fleth, _treasuryManagerFactory) {
    }

    /**
     * Allows the approved contracts to add a new token or ETH airdrop.
     * 
     * @dev If the airdrop is in ETH, the caller can send ETH to this contract which gets converted
     * into FLETH internally.
     * 
     * @param _creator The creator of the airdrop
     * @param _airdropIndex The index of the airdrop
     * @param _token The token to be airdropped. address(0) for ETH
     * @param _amount The amount of tokens to be airdropped
     * @param _airdropEndTime The timestamp at which the airdrop ends
     * @param _merkleRoot The merkle root for the airdrop
     * @param _merkleDataIPFSHash The IPFS hash of the merkle data
     */
    function addAirdrop(
        address _creator,
        uint _airdropIndex,
        address _token,
        uint _amount,
        uint _airdropEndTime,
        bytes32 _merkleRoot,
        string calldata _merkleDataIPFSHash
    ) external payable override(IMerkleAirdrop) onlyApprovedAirdropCreators {
        // Validate that the airdrop is configurated as expected
        if (_airdropIndex != airdropsCount[_creator]) revert InvalidAirdropIndex();
        if (_airdropData[_creator][_airdropIndex].merkleRoot != bytes32(0)) revert AirdropAlreadyExists();
        if (_airdropEndTime <= block.timestamp) revert AirdropExpired();

        // Pull in the tokens from the sender
        uint amount = _pullTokens(_token, _amount);

        // Create our airdrop struct
        _airdropData[_creator][_airdropIndex] = AirdropData({
            token: _token,
            airdropEndTime: _airdropEndTime,
            amountLeft: amount,
            merkleRoot: _merkleRoot,
            merkleDataIPFSHash: _merkleDataIPFSHash
        });

        unchecked {
            ++airdropsCount[_creator];
        }

        emit NewAirdrop(_creator, _airdropIndex, _token, amount, _airdropEndTime);
    }

    /**
     * Allows a user to claim their airdrop amount, if they are part of the merkle tree.
     * 
     * @param _creator The creator of the airdrop
     * @param _airdropIndex The index of the airdrop
     * @param _amount The amount of tokens to claim. Must match the amount in the merkle proof.
     * @param _merkleProof The merkle proof for the airdrop
     */
    function claim(
        address _creator,
        uint _airdropIndex,
        uint _amount,
        bytes32[] calldata _merkleProof
    ) external override(IMerkleAirdrop) {
        _claim(msg.sender, _creator, _airdropIndex, _amount, _merkleProof);
    }

    /**
     * Allows a user to claim their airdrop amount, if they are part of the merkle tree.
     *
     * @dev Only contracts that are approved airdrop creators can proxy claim
     *
     * @param _claimant The recipient we are claiming on behalf of
     * @param _creator The creator of the airdrop
     * @param _airdropIndex The index of the airdrop
     * @param _amount The amount of tokens to claim. Must match the amount in the merkle proof.
     * @param _merkleProof The merkle proof for the airdrop
     */
    function proxyClaim(
        address _claimant,
        address _creator,
        uint _airdropIndex,
        uint _amount,
        bytes32[] calldata _merkleProof
    ) external override(IMerkleAirdrop) onlyApprovedAirdropCreators {
        _claim(_claimant, _creator, _airdropIndex, _amount, _merkleProof);
    }

    /**
     * Allows the creator to withdraw the remaining airdrop amount, after the airdrop has ended.
     * 
     * @param _airdropIndex The index of the airdrop
     *
     * @return tokensWithdrawn The amount of tokens withdrawn
     */
    function creatorWithdraw(uint _airdropIndex) external override(IMerkleAirdrop) returns (uint tokensWithdrawn) {
        // Ensure that the airdrop specified is not currently active
        if (isAirdropActive(msg.sender, _airdropIndex)) revert AirdropInProgress();

        // Update our airdrop to remove the number of tokens available
        AirdropData storage airdrop = _airdropData[msg.sender][_airdropIndex];

        // Ensure that the airdrop existed
        if (airdrop.merkleRoot == bytes32(0)) revert InvalidAirdrop();

        tokensWithdrawn = airdrop.amountLeft;
        airdrop.amountLeft = 0;

        // Only withdraw tokens if we have an allocation
        if (tokensWithdrawn != 0) {
            _withdraw(airdrop.token, tokensWithdrawn);
            emit CreatorWithdraw(msg.sender, _airdropIndex, airdrop.token, tokensWithdrawn);
        }
    }

    /**
     * Verifies that the user is part of the merkle tree for the airdrop. This will ensure that
     * their claim is valid so we can safely withdraw the token allocation to them.
     *
     * @param _creator The creator of the airdrop
     * @param _airdropIndex The index of the airdrop
     * @param _user The address that is making the claim
     * @param _amount The amount of tokens to claim
     * @param _merkleProof The merkle proof for the airdrop
     */
    function isPartOfMerkleTree(
        address _creator,
        uint _airdropIndex,
        address _user,
        uint _amount,
        bytes32[] calldata _merkleProof
    ) public view override(IMerkleAirdrop) returns (bool) {
        bytes32 leaf = keccak256(abi.encodePacked(_creator, _airdropIndex, _user, _amount));
        return MerkleProofLib.verifyCalldata(_merkleProof, _airdropData[_creator][_airdropIndex].merkleRoot, leaf);
    }

    /**
     * Returns the airdrop data for the given creator and index.
     *
     * @param _creator The creator of the airdrop
     * @param _airdropIndex The index of the airdrop
     *
     * @return AirdropData The airdrop data
     */
    function airdropData(address _creator, uint _airdropIndex) external view override(IMerkleAirdrop) returns (AirdropData memory) {
        return _airdropData[_creator][_airdropIndex];
    }

    /**
     * Checks if the airdrop is active.
     *
     * @param _creator The creator of the airdrop
     * @param _airdropIndex The index of the airdrop
     *
     * @return bool If the airdrop is currently active
     */
    function isAirdropActive(address _creator, uint _airdropIndex) public view override(IMerkleAirdrop) returns (bool) {
        return _airdropData[_creator][_airdropIndex].airdropEndTime >= block.timestamp;
    }

    /**
     * Validates a claim and withdraws the allocation to the `msg.sender` and processes the
     * claim flow.
     *
     * @param _claimant The recipient we are claiming on behalf of
     * @param _creator The creator of the airdrop
     * @param _airdropIndex The index of the airdrop
     * @param _amount The amount of tokens to claim. Must match the amount in the merkle proof.
     * @param _merkleProof The merkle proof for the airdrop
     */
    function _claim(
        address _claimant,
        address _creator,
        uint _airdropIndex,
        uint _amount,
        bytes32[] calldata _merkleProof
    ) internal {
        // Ensure that the airdrop we have referenced is valid to be claimed against
        if (!isAirdropActive(_creator, _airdropIndex)) revert AirdropEnded();
        if (isAirdropClaimed[_creator][_airdropIndex][_claimant]) revert AirdropAlreadyClaimed();
        if (!isPartOfMerkleTree(_creator, _airdropIndex, _claimant, _amount, _merkleProof)) revert MerkleVerificationFailed();

        // Load our airdrop data
        AirdropData storage airdrop = _airdropData[_creator][_airdropIndex];

        // Update our airdrop to mark is as claimed
        isAirdropClaimed[_creator][_airdropIndex][_claimant] = true;

        // Reduce the amount of tokens left in the airdrop
        airdrop.amountLeft -= _amount;

        // Withdraw the tokens to the caller
        _withdraw(airdrop.token, _amount);
        emit AirdropClaimed(_claimant, _creator, _airdropIndex, airdrop.token, _amount);
    }
}
