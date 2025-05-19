// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PositionManager} from '@flaunch/PositionManager.sol';
import {PreventNoFairLaunch} from '@flaunch/subscribers/PreventNoFairLaunch.sol';

import {FlaunchTest} from '../FlaunchTest.sol';


contract PreventNoFairLaunchTest is FlaunchTest {

    PreventNoFairLaunch internal preventNoFairLaunch;

    constructor () {
        // Deploy our platform
        _deployPlatform();
    }

    /**
     * Ensures that a valid value can still flaunch.
     */
    function test_CanFlaunchValidInitialTokenFairLaunch(
        uint _initialTokenFairLaunch,
        uint _premineAmount,
        bool _flipped
    ) public flipTokens(_flipped) {
        _registerSubscriber();

        _initialTokenFairLaunch = bound(
            _initialTokenFairLaunch,
            preventNoFairLaunch.MINIMUM_INITIAL_TOKENS(),
            69e27
        );

        vm.assume(_premineAmount <= _initialTokenFairLaunch);

        positionManager.flaunch(
            PositionManager.FlaunchParams({
                name: 'Token Name',
                symbol: 'TOKEN',
                tokenUri: 'https://flaunch.gg/',
                initialTokenFairLaunch: _initialTokenFairLaunch,
                fairLaunchDuration: 30 minutes,
                premineAmount: _premineAmount,
                creator: address(this),
                creatorFeeAllocation: 20_00,
                flaunchAt: 0,
                initialPriceParams: abi.encode(''),
                feeCalculatorParams: abi.encode(1_000)
            })
        );
    }

    /**
     * Ensures that an invalid value cannot flaunch.
     */
    function test_CannotFlaunchNoInitialTokenFairLaunch(
        uint _initialTokenFairLaunch,
        bool _flipped
    ) public flipTokens(_flipped) {
        _registerSubscriber();

        vm.assume(_initialTokenFairLaunch < preventNoFairLaunch.MINIMUM_INITIAL_TOKENS());

        vm.expectRevert();
        positionManager.flaunch(
            PositionManager.FlaunchParams({
                name: 'Token Name',
                symbol: 'TOKEN',
                tokenUri: 'https://flaunch.gg/',
                initialTokenFairLaunch: _initialTokenFairLaunch,
                fairLaunchDuration: 30 minutes,
                premineAmount: 0,
                creator: address(this),
                creatorFeeAllocation: 20_00,
                flaunchAt: 0,
                initialPriceParams: abi.encode(''),
                feeCalculatorParams: abi.encode(1_000)
            })
        );
    }

    /**
     * Attach our Notifier subscriber.
     *
     * @dev This is done as a function call as our `flipTokens` modifier would unset this
     * when set once in the constructor.
     */
    function _registerSubscriber() internal {
        preventNoFairLaunch = new PreventNoFairLaunch(address(positionManager.notifier()));
        positionManager.notifier().subscribe(address(preventNoFairLaunch), '');
    }

}
