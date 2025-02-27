// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from '@solady/auth/Ownable.sol';

import {FullMath} from '@uniswap/v4-core/src/libraries/FullMath.sol';

import {FlaunchFeeExemption} from '@flaunch/price/FlaunchFeeExemption.sol';
import {TokenSupply} from '@flaunch/libraries/TokenSupply.sol';

import {IInitialPrice} from '@flaunch-interfaces/IInitialPrice.sol';


/**
 * This contract defines an initial flaunch price by calling on a value already set by the
 * Owner. This is a very simple implementation that sets an ETH : Token price.
 */
contract InitialPrice is IInitialPrice, Ownable {

    event InitialSqrtPriceX96Updated(uint160 _unflipped, uint160 _flipped);

    /// Stores the initial `sqrtPriceX96` that will be used for each pool
    struct InitialSqrtPriceX96 {
        uint160 unflipped;
        uint160 flipped;
    }

    /// Our starting token sqrtPriceX96
    InitialSqrtPriceX96 internal _initialSqrtPriceX96;

    /// Our static flaunching fee
    uint internal immutable flaunchFee;

    /// The {FlaunchFeeExemption} contract
    FlaunchFeeExemption public immutable flaunchFeeExemption;

    /**
     * Sets the owner of this contract that will be allowed to update the `_initialSqrtPriceX96`.
     *
     * @param _flaunchFee The fee to pay when flaunching in ETH
     * @param _protocolOwner The address of the owner
     * @param _flaunchFeeExemption The {FlaunchFeeExemption} contract address
     */
    constructor (uint _flaunchFee, address _protocolOwner, address _flaunchFeeExemption) {
        // Set our flaunch fee
        flaunchFee = _flaunchFee;

        // Register our {FlaunchFeeExemption}
        flaunchFeeExemption = FlaunchFeeExemption(_flaunchFeeExemption);

        // Grant ownership permissions to the caller
        _initializeOwner(_protocolOwner);
    }

    /**
     * Sets a flat Flaunching fee of 1 finney.
     *
     * @param _sender The address flaunching, which may be exluded from flaunching fees
     *
     * @return uint The fee taken from the user for Flaunching a token
     */
    function getFlaunchingFee(address _sender, bytes calldata /* _initialPriceParams */) public view returns (uint) {
        // Check if our `_sender` is fee excluded
        if (flaunchFeeExemption.feeExcluded(_sender)) {
            return 0;
        }

        return flaunchFee;
    }

    /**
     * Gets the ETH value of the desired market cap against the sqrtPriceX96.
     *
     * @return uint The ETH value of the market cap
     */
    function getMarketCap(bytes calldata _initialPriceParams) public view returns (uint) {
        uint160 sqrtPriceX96 = getSqrtPriceX96(msg.sender, false, _initialPriceParams);

        if (sqrtPriceX96 <= type(uint128).max) {
            uint ratioX192 = uint(sqrtPriceX96) * sqrtPriceX96;
            return FullMath.mulDiv(1 << 192, TokenSupply.INITIAL_SUPPLY, ratioX192);
        } else {
            uint ratioX128 = FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, 1 << 64);
            return FullMath.mulDiv(1 << 128, TokenSupply.INITIAL_SUPPLY, ratioX128);
        }
    }

    /**
     * Retrieves the stored `_initialSqrtPriceX96` value and provides the flipped or unflipped
     * `sqrtPriceX96` value.
     *
     * @param _flipped If the PoolKey currencies are flipped
     *
     * @return uint160 The `sqrtPriceX96` value
     */
    function getSqrtPriceX96(address /* _sender */, bool _flipped, bytes calldata /* _initialPriceParams */) public view returns (uint160) {
        return _flipped ? _initialSqrtPriceX96.flipped : _initialSqrtPriceX96.unflipped;
    }

    /**
     * Updates the `_initialSqrtPriceX96` value for all future flaunched tokens.
     *
     * @dev This can only be called by the contract owner
     *
     * @param _sqrtPriceX96 The new `_initialSqrtPriceX96` value
     */
    function setSqrtPriceX96(InitialSqrtPriceX96 memory _sqrtPriceX96) public onlyOwner {
        _initialSqrtPriceX96 = _sqrtPriceX96;
        emit InitialSqrtPriceX96Updated(_sqrtPriceX96.unflipped, _sqrtPriceX96.flipped);
    }

    /**
     * Override to return true to make `_initializeOwner` prevent double-initialization.
     *
     * @return bool Set to `true` to prevent owner being reinitialized.
     */
    function _guardInitializeOwner() internal pure virtual override returns (bool) {
        return true;
    }

}
