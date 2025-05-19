// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {CustomRevert} from '@uniswap/v4-core/src/libraries/CustomRevert.sol';
import {Hooks, IHooks} from '@uniswap/v4-core/src/libraries/Hooks.sol';
import {IPoolManager} from '@uniswap/v4-core/src/interfaces/IPoolManager.sol';
import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';
import {TickMath} from '@uniswap/v4-core/src/libraries/TickMath.sol';

import {PauseCalculator} from '@flaunch/fees/PauseCalculator.sol';
import {PositionManager} from '@flaunch/PositionManager.sol';

import {FlaunchTest} from '../FlaunchTest.sol';


contract PauseCalculatorTest is FlaunchTest {

    PauseCalculator feeCalculator;

    function setUp() public {
        _deployPlatform();

        feeCalculator = new PauseCalculator();
    }

    function test_CannotFlaunch() public {
        // Set the PauseCalculator that will prevent flaunching
        positionManager.setFeeCalculator(feeCalculator);

        vm.expectRevert(PauseCalculator.EnforcedPause.selector);
        _flaunch();
    }

    function test_CannotSwapInFairLaunchWindow() public {
        address memecoin = _flaunch();

        // Set the PauseCalculator that will prevent flaunching
        positionManager.setFeeCalculator(feeCalculator);

        // Provide fees to our user
        deal(address(WETH), address(this), 1 ether);
        deal(address(WETH), address(poolManager), 1 ether);
        WETH.approve(address(poolSwap), type(uint).max);

        PoolKey memory poolKey = positionManager.poolKey(memecoin);

        // error WrappedError(address target, bytes4 selector, bytes reason, bytes details);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(positionManager),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(PauseCalculator.EnforcedPause.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );

        poolSwap.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -0.01 ether,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            })
        );
    }

    function test_CannotSwapAfterFairLaunchWindow() public {
        address memecoin = _flaunch();

        // Move past the fair launch
        vm.warp(block.timestamp + 1 days);

        // Set the PauseCalculator that will prevent flaunching
        positionManager.setFeeCalculator(feeCalculator);

        // Provide fees to our user
        deal(address(WETH), address(this), 1 ether);
        deal(address(WETH), address(poolManager), 1 ether);
        WETH.approve(address(poolSwap), type(uint).max);

        PoolKey memory poolKey = positionManager.poolKey(memecoin);

        // error WrappedError(address target, bytes4 selector, bytes reason, bytes details);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(positionManager),
                IHooks.afterSwap.selector,
                abi.encodeWithSelector(PauseCalculator.EnforcedPause.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );

        poolSwap.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -0.01 ether,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            })
        );
    }

    function _flaunch() internal returns (address) {
        return positionManager.flaunch(
            PositionManager.FlaunchParams({
                name: 'Token Name',
                symbol: 'TOKEN',
                tokenUri: 'https://flaunch.gg/',
                initialTokenFairLaunch: supplyShare(50),
                fairLaunchDuration: 30 minutes,
                premineAmount: 0,
                creator: address(this),
                creatorFeeAllocation: 10_00,
                flaunchAt: 0,
                initialPriceParams: abi.encode(''),
                feeCalculatorParams: abi.encode(1_000)
            })
        );
    }

}
