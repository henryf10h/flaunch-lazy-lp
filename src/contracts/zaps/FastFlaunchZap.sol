// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PositionManager} from '@flaunch/PositionManager.sol';
import {MarketCappedPriceV3} from '@flaunch/price/MarketCappedPriceV3.sol';
import {TokenSupply} from '@flaunch/libraries/TokenSupply.sol';

/**
 * This zap allows the creator to instantly flaunch their coin, without any deployment fees, with the following settings:
 * - $10k starting market cap
 * - 60% of the total supply goes to the fair launch
 * - fair launch starts instantly
 * - no fee calculator
 */
contract FastFlaunchZap {

    /**
     * Parameters required when flaunching a new token.
     *
     * @member name Name of the token
     * @member symbol Symbol of the token
     * @member tokenUri The generated ERC721 token URI
     * @member creator The address that will receive the ERC721 ownership and premined ERC20 tokens
     * @member creatorFeeAllocation The percentage of fees the creators wants to take from the BidWall
     */
    struct FastFlaunchParams {
        string name;
        string symbol;
        string tokenUri;
        address creator;
        uint24 creatorFeeAllocation;
    }

    /// The Flaunch {PositionManager} contract
    PositionManager public immutable positionManager;

    /// The USDC market cap of the flaunched coins
    uint public usdcMarketCap = 10_000e6;

    /// The supply of the fair launch
    uint public fairLaunchSupply = TokenSupply.INITIAL_SUPPLY * 60 / 100; // 60% of the total supply

    /**
     * Assigns the immutable contracts used by the zap.
     *
     * @param _positionManager Flaunch {PositionManager}
     */
    constructor (PositionManager _positionManager) {
        positionManager = _positionManager;
    }

    function flaunch(FastFlaunchParams calldata _params) external returns (address memecoin_) {
        memecoin_ = positionManager.flaunch(PositionManager.FlaunchParams({
            name: _params.name,
            symbol: _params.symbol,
            tokenUri: _params.tokenUri,
            creator: _params.creator,
            creatorFeeAllocation: _params.creatorFeeAllocation,
            // fixed flaunch params
            initialTokenFairLaunch: fairLaunchSupply,
            premineAmount: 0,
            flaunchAt: 0, // start fair launch instantly
            initialPriceParams: abi.encode(MarketCappedPriceV3.MarketCappedPriceParams({
                usdcMarketCap: usdcMarketCap
            })),
            feeCalculatorParams: bytes('')
        }));
    }
}