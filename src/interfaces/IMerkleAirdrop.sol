// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IBaseAirdrop} from '@flaunch-interfaces/IBaseAirdrop.sol';

interface IMerkleAirdrop is IBaseAirdrop {

    /**
     * Stores the data for a memecoin airdrop.
     *
     * @member token The token to be airdropped. address(0) for ETH
     * @member airdropEndTime The timestamp at which the airdrop ends
     * @member amountLeft The amount of tokens left to be claimed
     * @member merkleRoot The merkle root for the airdrop
     * @member merkleDataIPFSHash The IPFS hash of the merkle data
     */
    struct AirdropData {
        address token;
        uint airdropEndTime;
        uint amountLeft;
        bytes32 merkleRoot;
        string merkleDataIPFSHash;
    }

    event NewAirdrop(address indexed _creator, uint indexed _airdropIndex, address _token, uint _amount, uint _airdropEndTime);
    event AirdropClaimed(address indexed _user, address indexed _creator, uint indexed _airdropIndex, address _tokenClaimed, uint _amount);
    event CreatorWithdraw(address indexed _creator, uint indexed _airdropIndex, address _tokenWithdrawn, uint _amount);

    error InvalidAirdropIndex();
    error AirdropAlreadyExists();
    error AirdropExpired();
    error MerkleVerificationFailed();

    function airdropsCount(address _creator) external view returns (uint);

    function airdropData(address _creator, uint _airdropIndex) external view returns (AirdropData memory);

    function isAirdropClaimed(address _creator, uint _airdropIndex, address _user) external view returns (bool);

    function addAirdrop(
        address _creator,
        uint _airdropIndex,
        address _token,
        uint _amount,
        uint _airdropEndTime,
        bytes32 _merkleRoot,
        string calldata _merkleDataIPFSHash
    ) external payable;

    function claim(
        address _creator,
        uint _airdropIndex,
        uint _amount,
        bytes32[] calldata _merkleProof
    ) external;

    function proxyClaim(
        address _claimant,
        address _creator,
        uint _airdropIndex,
        uint _amount,
        bytes32[] calldata _merkleProof
    ) external;

    function creatorWithdraw(uint _airdropIndex) external returns (uint tokensWithdrawn);

    function isPartOfMerkleTree(
        address _creator,
        uint _airdropIndex,
        address _user,
        uint _amount,
        bytes32[] calldata _merkleProof
    ) external view returns (bool);

    function isAirdropActive(address _creator, uint _airdropIndex) external view returns (bool);

}
