// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PositionManager} from '@flaunch/PositionManager.sol';

import {IBaseAirdrop} from '@flaunch-interfaces/IBaseAirdrop.sol';

interface ISnapshotAirdrop is IBaseAirdrop {

    /**
     * Stores the data for a memecoin airdrop.
     *
     * @member creator The creator of the airdrop
     * @member token The token to be airdropped. address(0) for ETH
     * @member totalTokensToAirdrop The total amount of tokens to be airdropped
     * @member memecoinHoldersTimestamp The timestamp at which the memecoin holders were snapshot
     * @member eligibleSupplySnapshot The total supply of the memecoin that is eligible for the airdrop: 
     *         Excludes balances in our {PositionManager} + Uniswap V4's {PoolManager} [so we neglect the FairLaunch liquidity]
     * @member airdropEndTime The timestamp at which the airdrop ends
     * @member amountLeft The amount of tokens left to be claimed
     */
    struct AirdropData {
        address creator;
        address token;
        uint totalTokensToAirdrop;
        uint memecoinHoldersTimestamp;
        uint eligibleSupplySnapshot;
        uint airdropEndTime;
        uint amountLeft;
    }

    event NewAirdrop(address indexed _memecoin, uint indexed _airdropIndex, AirdropData _airdropData);
    event AirdropClaimed(address indexed _user, address indexed _memecoin, uint indexed _airdropIndex, address _tokenClaimed, uint _amount);
    event CreatorWithdraw(address indexed _memecoin, uint indexed _airdropIndex, address indexed _creator, address _token, uint _amount);

    error InvalidMemecoin();
    error NotEligible();
    error CallerIsNotCreator();
    error IndexLengthMismatch();

    function positionManager() external view returns (PositionManager);

    function airdropsCount(address _memecoin) external view returns (uint);

    function airdropData(address _memecoin, uint _airdropIndex) external view returns (AirdropData memory);

    function isAirdropClaimed(address _creator, uint _airdropIndex, address _user) external view returns (bool);

    function addAirdrop(address _memecoin, address _creator, address _token, uint _amount, uint _airdropEndTime) external payable returns (uint airdropIndex);

    function claim(address _memecoin, uint _airdropIndex) external;

    function claimMultiple(address[] calldata _memecoins, uint[] calldata _airdropIndices) external;

    function proxyClaim(address _claimant, address _memecoin, uint _airdropIndex) external;

    function creatorWithdraw(address _memecoin, uint _airdropIndex) external returns (uint tokensWithdrawn);

    function isAirdropActive(address _memecoin, uint _airdropIndex) external view returns (bool);

    function checkAirdropEligibility(address _memecoin, uint _airdropIndex, address _user) external view returns (uint claimableAmount);
}