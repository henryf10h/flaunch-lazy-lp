// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from '@uniswap/v4-core/src/libraries/Hooks.sol';
import {PoolId} from '@uniswap/v4-core/src/types/PoolId.sol';

import {BaseSubscriber} from '@flaunch/subscribers/Base.sol';
import {PositionManager} from '@flaunch/PositionManager.sol';


/**
 * Prevents a user from flaunching a token that has no FairLaunch. The reasons for this are
 * two-fold:
 *
 *  1. Fair Launch promotes fair trading at launch and is anti-bot
 *  2. The protocol had an undiscovered bug that prevents swaps on fair launch-less tokens
 *
 * This hooks into the `afterInitialize` key to check the parameters passed, and if we see
 * that no fair launch supply was allocated then we revert.
 */
contract PreventNoFairLaunch is BaseSubscriber {

    error InvalidInitialTokenFairLaunch(uint _invalidAmount, uint _minTokens);

    /// Set our minimum initial tokens to 1%
    uint public constant MINIMUM_INITIAL_TOKENS = 1e27;

    /**
     * Sets our {Notifier} to parent contract to lock down calls.
     */
    constructor (address _notifier) BaseSubscriber(_notifier) {
        // ..
    }

    /**
     * Called when the contract is subscribed to the Notifier.
     *
     * We have no subscription requirements, so we can just confirm immediately.
     *
     * @dev This must return `true` to be subscribed.
     */
    function subscribe(bytes memory /* _data */) public view override onlyNotifier returns (bool) {
        return true;
    }

    /**
     * Called when `afterInitialize` is fired to ensure that `initialTokenFairLaunch` is
     * not zero.
     *
     * @param _key The notification key
     * @param _data The data passed during initialization
     */
    function notify(PoolId /* _poolId */, bytes4 _key, bytes calldata _data) public view override onlyNotifier {
        // We only want to deal with the `afterInitialize` key
        if (_key != IHooks.afterInitialize.selector) {
            return;
        }

        // Decode our parameters to get the Flaunch parameters
        (/* uint tokenId */, PositionManager.FlaunchParams memory params) = abi.decode(
            _data,
            (uint, PositionManager.FlaunchParams)
        );

        // If no initial token fair launch was allocated then revert
        if (params.initialTokenFairLaunch < MINIMUM_INITIAL_TOKENS) {
            revert InvalidInitialTokenFairLaunch(params.initialTokenFairLaunch, MINIMUM_INITIAL_TOKENS);
        }
    }

}
