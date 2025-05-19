// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import {LPFeeLibrary} from '@uniswap/v4-core/src/libraries/LPFeeLibrary.sol';
import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';
import {PoolIdLibrary} from '@uniswap/v4-core/src/types/PoolId.sol';
import {IPoolManager} from '@uniswap/v4-core/src/PoolManager.sol';
import {TickMath} from '@uniswap/v4-core/src/libraries/TickMath.sol';

import {InternalSwapPool} from '@flaunch/hooks/InternalSwapPool.sol';
import {FeeExemptions} from '@flaunch/hooks/FeeExemptions.sol';
import {PositionManager} from '@flaunch/PositionManager.sol';

import {FlaunchTest} from '../FlaunchTest.sol';


contract FeeExemptionsTest is FlaunchTest {

    using LPFeeLibrary for uint24;
    using PoolIdLibrary for PoolKey;

    // Set a test-wide pool key
    PoolKey private _poolKey;

    // Store our memecoin created for the test
    address memecoin;

    constructor () {
        // Deploy our platform
        _deployPlatform();

        // Create our memecoin
        memecoin = positionManager.flaunch(PositionManager.FlaunchParams('name', 'symbol', 'https://token.gg/', supplyShare(50), 30 minutes, 0, address(this), 0, 0, abi.encode(''), abi.encode(1_000)));

        // Reference our `_poolKey` for later tests
        _poolKey = positionManager.poolKey(memecoin);

        // Skip FairLaunch
        _bypassFairLaunch();
    }

    function test_CanSetFeeExemption(address _beneficiary, uint24 _validFee) public {
        // Ensure that the valid fee is.. well.. valid
        vm.assume(_validFee.isValid());

        // Confirm that the position does not yet exist
        FeeExemptions.FeeExemption memory feeExemption = feeExemptions.feeExemption(_beneficiary);
        assertEq(feeExemption.flatFee, 0);
        assertEq(feeExemption.enabled, false);

        vm.expectEmit();
        emit FeeExemptions.BeneficiaryFeeSet(_beneficiary, _validFee);
        feeExemptions.setFeeExemption(_beneficiary, _validFee);

        // Get our stored fee override
        feeExemption = feeExemptions.feeExemption(_beneficiary);
        assertEq(feeExemption.flatFee, _validFee);
        assertEq(feeExemption.enabled, true);
    }

    function test_CannotSetFeeExemptionWithInvalidFee(address _beneficiary, uint24 _invalidFee) public {
        // Ensure that the fee is invalid
        vm.assume(!_invalidFee.isValid());

        vm.expectRevert(abi.encodeWithSelector(
            FeeExemptions.FeeExemptionInvalid.selector, _invalidFee, LPFeeLibrary.MAX_LP_FEE
        ));

        feeExemptions.setFeeExemption(_beneficiary, _invalidFee);
    }

    function test_CannotSetFeeExemptionWithoutOwner(address _caller) public {
        // Ensure that the caller is not the owner
        vm.assume(_caller != feeExemptions.owner());

        vm.startPrank(_caller);
        vm.expectRevert(UNAUTHORIZED);
        feeExemptions.setFeeExemption(_caller, 0);
    }

    function test_CanRemoveFeeExemption(address _beneficiary) public hasExemption(_beneficiary) {
        vm.expectEmit();
        emit FeeExemptions.BeneficiaryFeeRemoved(_beneficiary);
        feeExemptions.removeFeeExemption(_beneficiary);

        // Confirm that the position does not exist
        FeeExemptions.FeeExemption memory feeExemption = feeExemptions.feeExemption(_beneficiary);
        assertEq(feeExemption.flatFee, 0);
        assertEq(feeExemption.enabled, false);
    }

    function test_CannotRemoveFeeExemptionOfUnknownBeneficiary(address _beneficiary) public {
        vm.expectRevert(
            abi.encodeWithSelector(FeeExemptions.NoBeneficiaryExemption.selector, _beneficiary)
        );

        feeExemptions.removeFeeExemption(_beneficiary);
    }

    function test_CannotRemoveFeeExemptionWithoutOwner(address _caller, address _beneficiary) public hasExemption(_beneficiary) {
        // Ensure that the caller is not the owner
        vm.assume(_caller != feeExemptions.owner());

        vm.startPrank(_caller);
        vm.expectRevert(UNAUTHORIZED);
        feeExemptions.removeFeeExemption(_beneficiary);
    }

    function test_CanMakeSwapWithExemptFees_ExactInput() public {
        // Add some liquidity to the pool so we can action a swap
        _addLiquidityToPool(memecoin, 100 ether, false);

        // Exempt a beneficiary with a set fee (0.05%)
        address beneficiary = address(poolSwap);
        feeExemptions.setFeeExemption(beneficiary, 50);

        // Give tokens and approve for swap
        deal(address(WETH), address(this), 1 ether);
        WETH.approve(address(poolSwap), type(uint).max);

        vm.expectEmit();
        emit InternalSwapPool.PoolFeesReceived(_poolKey.toId(), 0, 9970020458801235);

        // Action our swap
        _swap(
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -1 ether,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            })
        );

        // Update our exemption
        feeExemptions.setFeeExemption(beneficiary, 75);

        // Give tokens and approve for swap
        deal(address(WETH), address(this), 1 ether);
        WETH.approve(address(poolSwap), type(uint).max);

        // In this second swap, we will be catching the fees in the Internal Swap Pool, so we will have
        // this `PoolFeesReceived` event fire first, and then a subsequent `PoolFeesReceived` event will
        // fire that shows the Uniswap fees received. The combined fees received should be about 50%
        // higher than that of the previous swap due to new fee exemption amount.

        vm.expectEmit();
        emit InternalSwapPool.PoolFeesSwapped(_poolKey.toId(), true, 5000896186752441, 9970020458801235);

        vm.expectEmit();
        emit InternalSwapPool.PoolFeesReceived(_poolKey.toId(), 0, 74775153441009);

        vm.expectEmit();
        emit InternalSwapPool.PoolFeesReceived(_poolKey.toId(), 0, 14877575514451723);

        // Action our swap
        _swap(
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -1 ether,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            })
        );
    }

    function test_CanMakeSwapWithExemptFees_ExactOutput() public {
        // Add some liquidity to the pool so we can action a swap
        _addLiquidityToPool(memecoin, 100 ether, false);

        // Exempt a beneficiary with a set fee (0.05%)
        address beneficiary = address(poolSwap);
        feeExemptions.setFeeExemption(beneficiary, 50);

        // Give tokens and approve for swap
        deal(address(WETH), address(this), 10 ether);
        WETH.approve(address(poolSwap), type(uint).max);

        vm.expectEmit();
        emit InternalSwapPool.PoolFeesReceived(_poolKey.toId(), 2507070676188200, 0);

        // Action our swap
        _swap(
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: 1 ether,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            })
        );

        // Update our exemption
        feeExemptions.setFeeExemption(beneficiary, 75);

        vm.expectEmit();
        emit InternalSwapPool.PoolFeesReceived(_poolKey.toId(), 3761950294486174, 0);

        // Action our swap
        _swap(
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: 1 ether,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            })
        );
    }

    function test_CanMakeInternalSwapWithExemptFees() public {
        // Add some liquidity to the pool so we can action a swap, as the ISP uses the pool
        // price to determine the swap value.
        _addLiquidityToPool(memecoin, 100 ether, false);

        // Add fees to the ISP that will be sourced from
        deal(memecoin, address(positionManager), 20 ether);
        positionManager.depositFeesMock(_poolKey, 0, 20 ether);

        // Exempt a beneficiary with a set fee (0.05%)
        address beneficiary = address(poolSwap);
        feeExemptions.setFeeExemption(beneficiary, 50);

        // Give tokens and approve for swap
        deal(address(WETH), address(this), 10 ether);
        WETH.approve(address(poolSwap), type(uint).max);

        // From this swap we should expect to see 1e18 tokens given to the user for `-5.035e17` plus
        // fees, which at 50% should be `-2.517e15`. These will be moved into the pool via the
        // `PoolFeesReceived` event and shows the swap value via `PoolFeesSwapped`.

        vm.expectEmit();
        emit InternalSwapPool.PoolFeesSwapped(_poolKey.toId(), true, 503560711941529815, 1000000000000000000);

        vm.expectEmit();
        emit InternalSwapPool.PoolFeesReceived(_poolKey.toId(), 2517803559707649, 0);

        // Action our swap
        _swap(
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: 1 ether,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            })
        );

        // Update our exemption
        feeExemptions.setFeeExemption(beneficiary, 75);

        // The same amount will be swapped, as this has facilitated the internal value, but the amount
        // received will be higher as there is a reduced fee exemption (75% fees, rather than 50%).

        vm.expectEmit();
        emit InternalSwapPool.PoolFeesSwapped(_poolKey.toId(), true, 503560711941529815, 1000000000000000000);

        vm.expectEmit();
        emit InternalSwapPool.PoolFeesReceived(_poolKey.toId(), 3776705339561473, 0);

        // Action our swap
        _swap(
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: 1 ether,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            })
        );
    }

    function test_CanSwapWithZeroFeeExemption() public {
        // Add some liquidity to the pool so we can action a swap
        _addLiquidityToPool(memecoin, 100 ether, false);

        // Exempt a beneficiary with a set fee (0%)
        address beneficiary = address(poolSwap);
        feeExemptions.setFeeExemption(beneficiary, 0);

        // Give sufficient WETH to fill the swap. This will cost just over 1e18 as
        // it's a 1:1 pool and the tick will shift a little.
        deal(address(WETH), address(this), 1.5 ether);
        WETH.approve(address(poolSwap), type(uint).max);

        // Remove any memecoins we may have
        deal(memecoin, address(this), 0);

        // Action our swap
        _swap(
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: 1 ether,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            })
        );

        // We should have received the entire amount with no fees
        assertEq(IERC20(memecoin).balanceOf(address(this)), 1 ether);
    }

    function test_CanUseLowerBaseFeeIfHigherExemptionFee() public {
        // Add some liquidity to the pool so we can action a swap
        _addLiquidityToPool(memecoin, 100 ether, false);

        // Exempt a beneficiary with a set fee (100%)
        address beneficiary = address(poolSwap);
        feeExemptions.setFeeExemption(beneficiary, 100_0000);

        // Give tokens and approve for swap
        deal(address(WETH), address(this), 1 ether);
        WETH.approve(address(poolSwap), type(uint).max);

        vm.expectEmit();
        emit InternalSwapPool.PoolFeesReceived(_poolKey.toId(), 0, 19940040917602470);

        // Action our swap
        _swap(
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -1 ether,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            })
        );
    }

    modifier hasExemption(address _beneficiary) {
        feeExemptions.setFeeExemption(_beneficiary, 0);
        _;
    }

    function _swap(IPoolManager.SwapParams memory _swapParams) internal {
        poolSwap.swap(
            _poolKey,
            _swapParams
        );
    }

}
