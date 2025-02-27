// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SafeTransferLib} from '@solady/utils/SafeTransferLib.sol';

import {PoolIdLibrary} from '@uniswap/v4-core/src/types/PoolId.sol';
import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';

import {IERC20} from '@openzeppelin/contracts/interfaces/IERC20.sol';

import {FlaunchPremineZap} from '@flaunch/zaps/FlaunchPremineZap.sol';
import {PositionManager} from '@flaunch/PositionManager.sol';
import {WhitelistFairLaunch} from '@flaunch/subscribers/WhitelistFairLaunch.sol';


/**
 * This zap allows the creator to flaunch a memecoin and create a whitelist of users that
 * will be able to claim from the fair launch allocation.
 */
contract FlaunchWhitelistZap {

    using PoolIdLibrary for PoolKey;

    /// Our internal contract addresses
    FlaunchPremineZap public immutable flaunchPremineZap;
    PositionManager public immutable positionManager;
    WhitelistFairLaunch public immutable whitelistFairLaunch;

    /**
     * Sets our required contracts.
     *
     * @param _positionManager The {PositionManager} contract address
     * @param _premineZap The {FlaunchPremineZap} contract address
     * @param _whitelistFairLaunch The {WhitelistFairLaunch} contract address
     */
    constructor (address payable _positionManager, address payable _premineZap, address _whitelistFairLaunch) {
        flaunchPremineZap = FlaunchPremineZap(_premineZap);
        positionManager = PositionManager(_positionManager);
        whitelistFairLaunch = WhitelistFairLaunch(_whitelistFairLaunch);
    }

    /**
     * Flaunches a memecoin and creates a whitelist of users that can make swaps
     * during fair launch.
     *
     * @param _params The flaunch parameters
     * @param _merkleRoot The merkle root for the airdrop
     * @param _merkleDataIPFSHash The IPFS hash of the merkle data
     * @param _whitelistMaxTokens The amount of tokens a user can buy during whitelist
     *
     * @return memecoin_ The address of the memecoin ERC20 created
     * @return ethSpent_ The amount of ETH spent during premining
     */
    function flaunch(
        PositionManager.FlaunchParams calldata _params,
        bytes32 _merkleRoot,
        string calldata _merkleDataIPFSHash,
        uint _whitelistMaxTokens
    ) external payable returns (address memecoin_, uint ethSpent_) {
        // Flaunch & premine the memecoin
        (memecoin_, ethSpent_) = flaunchPremineZap.flaunch(_params);

        // Set the whitelist merkle if we have an initial token fair launch value and the
        // merkle root appears valid.
        if (_params.initialTokenFairLaunch != 0 && _merkleRoot != '') {
            whitelistFairLaunch.setWhitelist({
                _poolId: positionManager.poolKey(memecoin_).toId(),
                _root: _merkleRoot,
                _ipfs: _merkleDataIPFSHash,
                _maxTokens: _whitelistMaxTokens
            });
        }

        // Send the user the tokens that they premined
        uint memecoinsPremined = IERC20(memecoin_).balanceOf(address(this));
        if (memecoinsPremined != 0) {
            IERC20(memecoin_).transfer(_params.creator, memecoinsPremined);
        }

        // Refund the remaining ETH
        uint remainingBalance = payable(address(this)).balance;
        if (remainingBalance > 0) {
            SafeTransferLib.safeTransferETH(msg.sender, remainingBalance);
        }
    }
}
