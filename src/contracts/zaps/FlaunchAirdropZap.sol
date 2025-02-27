// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SafeTransferLib} from '@solady/utils/SafeTransferLib.sol';

import {IERC20} from '@openzeppelin/contracts/interfaces/IERC20.sol';

import {PositionManager} from '@flaunch/PositionManager.sol';
import {FlaunchPremineZap} from '@flaunch/zaps/FlaunchPremineZap.sol';
import {IMerkleAirdrop} from '@flaunch-interfaces/IMerkleAirdrop.sol';

/**
 * This zap allows the creator to flaunch a memecoin and create an airdrop for it from the premine.
 */
contract FlaunchAirdropZap {
    FlaunchPremineZap public flaunchPremineZap;
    IMerkleAirdrop public merkleAirdrop;

    error InsufficientMemecoinsForAirdrop();

    constructor(address payable _premineZap, address payable _merkleAirdrop) {
        flaunchPremineZap = FlaunchPremineZap(_premineZap);
        merkleAirdrop = IMerkleAirdrop(_merkleAirdrop);
    }

    /**
     * Flaunches a memecoin and creates an airdrop for it.
     *
     * @param _params The flaunch parameters
     * @param _airdropIndex The index of the airdrop
     * @param _airdropAmount The amount of memecoins to add to the airdrop
     * @param _airdropEndTime The timestamp at which the airdrop ends
     * @param _merkleRoot The merkle root for the airdrop
     * @param _merkleDataIPFSHash The IPFS hash of the merkle data
     */
    function flaunch(
        PositionManager.FlaunchParams calldata _params,
        uint256 _airdropIndex,
        uint256 _airdropAmount,
        uint256 _airdropEndTime,
        bytes32 _merkleRoot,
        string calldata _merkleDataIPFSHash
    ) external payable returns (address memecoin_, uint ethSpent_) {
        // Flaunch & premine the memecoin
        (memecoin_, ethSpent_) = flaunchPremineZap.flaunch(_params);

        uint256 memecoinsPremined = IERC20(memecoin_).balanceOf(address(this));
        if (memecoinsPremined < _airdropAmount) revert InsufficientMemecoinsForAirdrop();

        // Add the memecoin airdrop to the merkle airdrop contract
        IERC20(memecoin_).approve(address(merkleAirdrop), _airdropAmount);
        merkleAirdrop.addAirdrop(_params.creator, _airdropIndex, memecoin_, _airdropAmount, _airdropEndTime, _merkleRoot, _merkleDataIPFSHash);

        // Send the remaining memecoins to the creator
        if (memecoinsPremined > _airdropAmount) {
            IERC20(memecoin_).transfer(_params.creator, memecoinsPremined - _airdropAmount);
        }

        // Refund the remaining ETH
        uint256 remainingBalance = payable(address(this)).balance;
        if (remainingBalance > 0) {
            SafeTransferLib.safeTransferETH(msg.sender, remainingBalance);
        }
    }
}
