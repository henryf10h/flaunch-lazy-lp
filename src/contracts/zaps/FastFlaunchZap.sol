// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PositionManager} from '@flaunch/PositionManager.sol';
import {TokenSupply} from '@flaunch/libraries/TokenSupply.sol';

/**
 * This zap allows the creator to instantly flaunch their coin, without any deployment fees,
 * with the following settings:
 * - $10k starting market cap
 * - 60% of the total supply goes to the fair launch
 * - fair launch starts instantly
 * - 80% dev / 20% community split
 */
contract FastFlaunchZap {

    /**
     * Parameters required when flaunching a new token.
     *
     * @member name Name of the token
     * @member symbol Symbol of the token
     * @member tokenUri The generated ERC721 token URI
     * @member creator The address that will receive the ERC721 ownership and premined ERC20 tokens
     */
    struct FastFlaunchParams {
        string name;
        string symbol;
        string tokenUri;
        address creator;
    }

    /// The Flaunch {PositionManager} contract
    PositionManager public immutable positionManager;

    /// The USDC market cap of the flaunched coins
    uint public constant USDC_MARKET_CAP = 10_000e6;

    /// The supply of the fair launch (60% of the total supply)
    uint public constant FAIR_LAUNCH_SUPPLY = TokenSupply.INITIAL_SUPPLY * 60 / 100;

    /**
     * Assigns the immutable contracts used by the zap.
     *
     * @param _positionManager Flaunch {PositionManager}
     */
    constructor (PositionManager _positionManager) {
        positionManager = _positionManager;
    }

    /**
     * Flaunches a token using a subset of the traditional flaunch parameters and filling the
     * rest with a standardised value.
     */
    function flaunch(FastFlaunchParams calldata _params) external returns (address memecoin_) {
        memecoin_ = positionManager.flaunch(
            PositionManager.FlaunchParams({
                // Variable parameters
                name: _params.name,
                symbol: _params.symbol,
                tokenUri: _params.tokenUri,
                creator: _params.creator,

                // Fixed flaunch parameters
                creatorFeeAllocation: 80_00,
                initialTokenFairLaunch: FAIR_LAUNCH_SUPPLY,
                premineAmount: 0,
                flaunchAt: 0,
                initialPriceParams: abi.encode(USDC_MARKET_CAP),
                feeCalculatorParams: bytes('')
            })
        );
    }
}
