// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import {Currency} from '@uniswap/v4-core/src/types/Currency.sol';
import {CustomRevert} from '@uniswap/v4-core/src/libraries/CustomRevert.sol';
import {Hooks, IHooks} from '@uniswap/v4-core/src/libraries/Hooks.sol';
import {IPoolManager} from '@uniswap/v4-core/src/interfaces/IPoolManager.sol';
import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';
import {PoolIdLibrary, PoolId} from '@uniswap/v4-core/src/types/PoolId.sol';
import {TickMath} from '@uniswap/v4-core/src/libraries/TickMath.sol';

import {FairLaunch} from '@flaunch/hooks/FairLaunch.sol';
import {FeeDistributor} from '@flaunch/hooks/FeeDistributor.sol';
import {Flaunch} from '@flaunch/Flaunch.sol';
import {InitialPrice} from '@flaunch/price/InitialPrice.sol';
import {PositionManager} from '@flaunch/PositionManager.sol';
import {ProtocolRoles} from '@flaunch/libraries/ProtocolRoles.sol';
import {TokenSupply} from '@flaunch/libraries/TokenSupply.sol';

import {FlaunchTest} from '../FlaunchTest.sol';


contract FairLaunchTest is FlaunchTest {

    using PoolIdLibrary for PoolKey;

    PoolKey internal EXPECTED_POOL_KEY;
    PoolKey internal EXPECTED_FLIPPED_POOL_KEY;

    PoolId internal immutable EXPECTED_POOL_ID;
    PoolId internal immutable EXPECTED_FLIPPED_POOL_ID;

    uint FAIR_LAUNCH_WINDOW;

    address MEMECOIN_UNFLIPPED = 0xF2C9428E4C5657e1Ea0c45C3ffD227025CA05f00;
    address MEMECOIN_FLIPPED = 0x32a65F37D7CA5aa2AA1A9A81E6DEeEa36198554a;

    constructor () {
        // Deploy our platform
        _deployPlatform();

        // Set our expected PoolKey. The `currency1` address is the deterministic address of the `Memecoin`
        // that will be created when we run `positionManager.flaunch`.
        EXPECTED_POOL_KEY = _normalizePoolKey(PoolKey({
            currency0: Currency.wrap(address(WETH)),
            currency1: Currency.wrap(MEMECOIN_UNFLIPPED),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(address(positionManager))
        }));
        EXPECTED_POOL_ID = EXPECTED_POOL_KEY.toId();

        EXPECTED_FLIPPED_POOL_KEY = _normalizePoolKey(PoolKey({
            currency0: Currency.wrap(0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF),
            currency1: Currency.wrap(MEMECOIN_FLIPPED),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(address(positionManager))
        }));
        EXPECTED_FLIPPED_POOL_ID = EXPECTED_FLIPPED_POOL_KEY.toId();

        // Get the FairLaunch window from the FairLaunch contract constant
        FAIR_LAUNCH_WINDOW = fairLaunch.FAIR_LAUNCH_WINDOW();
    }

    function test_CanCreateFairLaunchPool(uint _supply, bool _flipped) public flipTokens(_flipped) {
        // Ensure we have a valid initial supply
        vm.assume(_supply <= flaunch.MAX_FAIR_LAUNCH_TOKENS());

        if (!_flipped) {
            vm.expectEmit();
            emit PositionManager.PoolStateUpdated(EXPECTED_POOL_ID, 112045541949572279837463876454, 6931, 0, 0, 0);
        } else {
            vm.expectEmit();
            emit PositionManager.PoolStateUpdated(EXPECTED_FLIPPED_POOL_ID, 56022770974786139918731938227, -6932, 0, 0, 0);
        }

        // Create our Memecoin
        address memecoin = positionManager.flaunch(PositionManager.FlaunchParams('name', 'symbol', 'https://token.gg/', _supply, 0, address(this), 0, 0, abi.encode(''), abi.encode(1_000)));

        // Confirm the balances of our two contracts
        assertEq(IERC20(memecoin).balanceOf(address(positionManager)), TokenSupply.INITIAL_SUPPLY);
        assertEq(IERC20(memecoin).balanceOf(address(poolManager)), 0);
    }

    function test_CannotCreateFairLaunchPoolWithHighInitialSupply(uint _supply, bool _flipped) public flipTokens(_flipped) {
        // Ensure we have an invalid initial supply
        vm.assume(_supply > flaunch.MAX_FAIR_LAUNCH_TOKENS());

        vm.expectRevert(abi.encodeWithSelector(Flaunch.InvalidInitialSupply.selector, _supply));
        positionManager.flaunch(PositionManager.FlaunchParams('name', 'symbol', 'https://token.gg/', _supply, 0, address(this), 0, 0, abi.encode(''), abi.encode(1_000)));
    }

    function test_CanGetInsideFairLaunchWindow(uint _timestamp, bool _flipped) public flipTokens(_flipped) {
        vm.assume(_timestamp >= block.timestamp);
        vm.assume(_timestamp < block.timestamp + FAIR_LAUNCH_WINDOW);

        positionManager.flaunch(PositionManager.FlaunchParams('name', 'symbol', 'https://token.gg/', supplyShare(50), 0, address(this), 0, 0, abi.encode(''), abi.encode(1_000)));

        vm.warp(_timestamp);
        assertTrue(fairLaunch.inFairLaunchWindow(poolId(_flipped)));
    }

    function test_CanGetOutsideFairLaunchWindow(uint _timestamp, bool _flipped) public flipTokens(_flipped) {
        vm.assume(_timestamp >= block.timestamp + FAIR_LAUNCH_WINDOW);

        positionManager.flaunch(PositionManager.FlaunchParams('name', 'symbol', 'https://token.gg/', supplyShare(50), 0, address(this), 0, 0, abi.encode(''), abi.encode(1_000)));

        vm.warp(_timestamp);
        assertFalse(fairLaunch.inFairLaunchWindow(poolId(_flipped)));
    }

    function test_CanRebalancePoolAfterFairLaunch(bool _flipped) public flipTokens(_flipped) {
        deal(address(WETH), address(poolManager), 1000e27 ether);

        // Create our memecoin
        positionManager.flaunch(PositionManager.FlaunchParams('name', 'symbol', 'https://token.gg/', supplyShare(50), 0, address(this), 0, 0, abi.encode(''), abi.encode(1_000)));

        vm.warp(block.timestamp + FAIR_LAUNCH_WINDOW + 1);
        assertFalse(fairLaunch.inFairLaunchWindow(poolId(_flipped)));

        // Give tokens and approve for swap
        deal(address(WETH), address(this), 1 ether);
        WETH.approve(address(poolSwap), type(uint).max);

        // Action our swap
        poolSwap.swap(
            poolKey(_flipped),
            IPoolManager.SwapParams({
                zeroForOne: !_flipped,
                amountSpecified: -1 ether,
                sqrtPriceLimitX96: !_flipped ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            })
        );
    }

    /**
     * FairLaunch swaps will always be NATIVE for CT.
     *
     * SPECIFIED means that we want the CT amount and fees will be NATIVE
     * UNSPECIFIED means that we want the NATIVE amount and fees will be CT
     *
     * FLIPPED and UNFLIPPED should not make any difference aside from a slight tick
     * variance, meaning that we may have a dust variation.
     *
     * - FLIPPED tick (-6932)
     * - UNFLIPPED tick (6931)
     *
     * The test suite is set up to understand that 1 ETH : 2 TOKEN (0.5 ETH : 1 TOKEN).
     */
    function test_CanCaptureRevenueAndSupplyChange(bool _specified, bool _flipped, bool _fees) public flipTokens(_flipped) {
        // If we have no fees fuzzed, then we disable pool swap fees
        if (!_fees) {
            positionManager.setFeeDistribution(
                FeeDistributor.FeeDistribution({
                    swapFee: 0,
                    referrer: 0,
                    protocol: 0,
                    active: true
                })
            );
        }
        // Otherwise, ensure that we send 100% to the protocol to avoid the bidWall share going
        // back into the `fairLaunchRevenue` due to the `bidWall` pre-allocation.
        else {
            positionManager.setFeeDistribution(
                FeeDistributor.FeeDistribution({
                    swapFee: 1_00,
                    referrer: 0,
                    protocol: 10_00,
                    active: true
                })
            );
        }

        deal(address(WETH), address(poolManager), 1000e27 ether);

        // Create our memecoin
        positionManager.flaunch(PositionManager.FlaunchParams('name', 'symbol', 'https://token.gg/', supplyShare(50), 0, address(this), 0, 0, abi.encode(''), abi.encode(1_000)));
        assertTrue(fairLaunch.inFairLaunchWindow(poolId(_flipped)));

        // Give tokens and approve for swap
        deal(address(WETH), address(this), 10 ether);
        WETH.approve(address(poolSwap), type(uint).max);

        // Action our swap to buy token from the pool
        poolSwap.swap(
            poolKey(_flipped),
            IPoolManager.SwapParams({
                zeroForOne: !_flipped,
                amountSpecified: _specified ? int(1 ether) : -1 ether,
                sqrtPriceLimitX96: !_flipped ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            })
        );

        uint ethIn;
        uint tokenOut;
        uint fees;

        if (_specified) {
            tokenOut = 1 ether;
            ethIn = _flipped ? 499990919207187760 : 500040918299108479;

            if (_fees) {
                fees = _flipped ? 4999909192071877 : 5000409182991084;
            }
        } else {
            ethIn = 1 ether;
            tokenOut = _flipped ? 2000036323830947322 : 1999836340196927629;
        }

        // Confirm that our revenue and supply values are correct
        FairLaunch.FairLaunchInfo memory fairLaunchInfo = fairLaunch.fairLaunchInfo(poolId(_flipped));
        assertEq(fairLaunchInfo.revenue, ethIn - fees, 'Invalid revenue');
        assertEq(fairLaunchInfo.supply, supplyShare(50) - tokenOut, 'Invalid token');

        // Confirm we hold at least the expected revenue in the contract
        assertGe(
            IERC20(positionManager.getNativeToken()).balanceOf(address(positionManager)),
            ethIn - fees
        );
    }

    /// @dev This also test that we can sell after the Fair Launch window has ended
    function test_CannotSellTokenDuringFairLaunchWindow(bool _flipped) public flipTokens(_flipped) {
        deal(address(WETH), address(poolManager), 1000e27 ether);

        // Create our memecoin
        address memecoin = positionManager.flaunch(PositionManager.FlaunchParams('name', 'symbol', 'https://token.gg/', supplyShare(50), 0, address(this), 0, 0, abi.encode(''), abi.encode(1_000)));

        vm.warp(block.timestamp + FAIR_LAUNCH_WINDOW - 1);
        assertTrue(fairLaunch.inFairLaunchWindow(poolId(_flipped)));

        // Give tokens and approve for swap
        deal(address(WETH), address(this), 1 ether);
        WETH.approve(address(poolSwap), type(uint).max);

        // Action our swap to buy token from the pool
        poolSwap.swap(
            poolKey(_flipped),
            IPoolManager.SwapParams({
                zeroForOne: !_flipped,
                amountSpecified: -1 ether,
                sqrtPriceLimitX96: !_flipped ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            })
        );

        // Now try and sell the token back into the pool
        IERC20(memecoin).approve(address(poolSwap), type(uint).max);
        int sellAmountSpecified = -int(IERC20(memecoin).balanceOf(address(this)));

        // Expect our error wrapped within the `FailedHookCall` response
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(positionManager),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(FairLaunch.CannotSellTokenDuringFairLaunch.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );

        poolSwap.swap(
            poolKey(_flipped),
            IPoolManager.SwapParams({
                zeroForOne: _flipped,
                amountSpecified: sellAmountSpecified,
                sqrtPriceLimitX96: _flipped ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            })
        );

        // Move forward to fair launch window expiration and attempt swap again (successfully)
        vm.warp(block.timestamp + FAIR_LAUNCH_WINDOW + 1);
        assertFalse(fairLaunch.inFairLaunchWindow(poolId(_flipped)));

        poolSwap.swap(
            poolKey(_flipped),
            IPoolManager.SwapParams({
                zeroForOne: _flipped,
                amountSpecified: sellAmountSpecified,
                sqrtPriceLimitX96: _flipped ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            })
        );
    }

    function test_CanGetFeesFromFairLaunchSwap(bool _flipped) public flipTokens(_flipped) {
        deal(address(WETH), address(poolManager), 1000e27 ether);

        // Create our memecoin with tokens in fair launch
        positionManager.flaunch(PositionManager.FlaunchParams('name', 'symbol', 'https://token.gg/', supplyShare(50), 0, address(this), 0, 0, abi.encode(''), abi.encode(1_000)));

        // We should currently be within the FairLaunch window
        assertTrue(fairLaunch.inFairLaunchWindow(poolId(_flipped)));

        // Deal enough ETH to fulfill the entire FairLaunch position
        deal(address(WETH), address(this), 100e27 ether);
        WETH.approve(address(poolSwap), type(uint).max);

        // Perfect a swap with ETH as the unspecified token
        poolSwap.swap(
            poolKey(_flipped),
            IPoolManager.SwapParams({
                zeroForOne: !_flipped,
                amountSpecified: 0.5 ether,
                sqrtPriceLimitX96: !_flipped ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            })
        );

        // Perfect a swap with non-ETH as the unspecified token
        poolSwap.swap(
            poolKey(_flipped),
            IPoolManager.SwapParams({
                zeroForOne: !_flipped,
                amountSpecified: -0.5 ether,
                sqrtPriceLimitX96: !_flipped ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            })
        );

        // Pass time
        vm.warp(block.timestamp + 1 days);

        for (uint i; i < 1; ++i) {
            // We should currently be within the FairLaunch window
            assertFalse(fairLaunch.inFairLaunchWindow(poolId(_flipped)));

            // Action a swap that will rebalance
            poolSwap.swap(
                poolKey(_flipped),
                IPoolManager.SwapParams({
                    zeroForOne: !_flipped,
                    amountSpecified: -0.1 ether,
                    sqrtPriceLimitX96: !_flipped ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                })
            );

            vm.warp(block.timestamp + 5);
        }
    }

    function test_CanBuyTokenAtSamePriceDuringFairLaunch(bool _flipped) public flipTokens(_flipped) {
        deal(address(WETH), address(poolManager), 1000e27 ether);

        // Create our memecoin with tokens in fair launch
        positionManager.flaunch(PositionManager.FlaunchParams('name', 'symbol', 'https://token.gg/', supplyShare(50), 0, address(this), 0, 0, abi.encode(''), abi.encode(1_000)));

        // We should currently be within the FairLaunch window
        assertTrue(fairLaunch.inFairLaunchWindow(poolId(_flipped)));

        // Get the starting pool manager ETH balance
        uint poolManagerEth = WETH.balanceOf(address(poolManager));

        // Deal enough ETH to fulfill the entire FairLaunch position
        deal(address(WETH), address(this), 100e27 ether);
        WETH.approve(address(poolSwap), type(uint).max);

        uint startBalance = WETH.balanceOf(address(this));
        uint ethSpent;

        // Action our swap to buy all of the FairLaunch tokens from the pool
        uint expectedEthCost;
        uint tokenBuyAmount = supplyShare(5);

        // We stop just shy of the limit as we don't want to go over the threshold
        for (uint i = tokenBuyAmount; i <= supplyShare(45);) {
            uint loopStartBalance = WETH.balanceOf(address(this));

            poolSwap.swap(
                poolKey(_flipped),
                IPoolManager.SwapParams({
                    zeroForOne: !_flipped,
                    amountSpecified: int(tokenBuyAmount),
                    sqrtPriceLimitX96: !_flipped ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                })
            );

            // Capture the first buy cost
            if (expectedEthCost == 0) {
                expectedEthCost = startBalance - WETH.balanceOf(address(this));
            }

            // Confirm the amount of ETH spent the same each time
            uint iterationEthCost = loopStartBalance - WETH.balanceOf(address(this));
            assertEq(expectedEthCost, iterationEthCost, 'Invalid ETH spent');

            ethSpent += iterationEthCost;

            address memecoin = _flipped ? MEMECOIN_FLIPPED : MEMECOIN_UNFLIPPED;

            // Confirm that we receive _just about_ the right amount of token
            assertApproxEqRel(
                IERC20(memecoin).balanceOf(address(this)),
                uint(i),
                0.000001 ether, // 0.0001%
                'Invalid Memecoin balance'
            );

            // Confirm that the expected people are holding the expected token balances
            assertEq(IERC20(memecoin).balanceOf(address(this)), i, 'Invalid user balance');
            assertEq(IERC20(memecoin).balanceOf(address(fairLaunch)), 0, 'Invalid FairLaunch balance');
            assertEq(IERC20(memecoin).balanceOf(address(positionManager)), TokenSupply.INITIAL_SUPPLY - i, 'Invalid PositionManager balance');
            assertEq(IERC20(memecoin).balanceOf(address(poolManager)), 0, 'Invalid PoolManager balance');

            assertEq(WETH.balanceOf(address(this)), startBalance - ethSpent, 'Invalid user ETH balance');
            assertEq(WETH.balanceOf(address(fairLaunch)), 0, 'Invalid FairLaunch ETH balance');
            assertEq(WETH.balanceOf(address(positionManager)), ethSpent, 'Invalid PositionManager ETH balance');
            assertEq(WETH.balanceOf(address(poolManager)), poolManagerEth, 'Invalid PoolManager ETH balance');

            FairLaunch.FairLaunchInfo memory fairLaunchInfo = fairLaunch.fairLaunchInfo(poolId(_flipped));
            assertEq(fairLaunchInfo.supply, supplyShare(50) - i, 'Invalid PositionManager token supply');

            // Iterate to the next swap
            i += tokenBuyAmount;
        }
    }

    function test_CanOverbuyFairLaunchPosition(bool _flipped) public flipTokens(_flipped) {
        deal(address(WETH), address(poolManager), 1000e27 ether);

        // Create our memecoin with tokens in fair launch
        positionManager.flaunch(PositionManager.FlaunchParams('name', 'symbol', 'https://token.gg/', 0.1e27, 0, address(this), 0, 0, abi.encode(''), abi.encode(1_000)));

        // We should currently be within the FairLaunch window
        assertTrue(fairLaunch.inFairLaunchWindow(poolId(_flipped)));

        // Deal enough ETH to fulfill the entire FairLaunch position
        deal(address(WETH), address(this), 100e27 ether);
        WETH.approve(address(poolSwap), type(uint).max);

        uint startBalance = WETH.balanceOf(address(this));

        // Action our swap to buy all of the FairLaunch tokens from the pool
        poolSwap.swap(
            poolKey(_flipped),
            IPoolManager.SwapParams({
                zeroForOne: !_flipped,
                amountSpecified: int(supplyShare(50)),
                sqrtPriceLimitX96: !_flipped ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            })
        );

        uint ethSpent = startBalance - WETH.balanceOf(address(this));

        assertEq(IERC20(_flipped ? MEMECOIN_FLIPPED : MEMECOIN_UNFLIPPED).balanceOf(address(this)), supplyShare(50), 'Invalid user balance');
        assertLt(WETH.balanceOf(address(this)), startBalance, 'Invalid user ETH balance');

        // Confirm the fair window is closed
        assertFalse(fairLaunch.inFairLaunchWindow(EXPECTED_POOL_ID));

        // Confirm that we cannot sell the tokens back for more than we bought them for
        vm.expectRevert();
        poolSwap.swap(
            poolKey(_flipped),
            IPoolManager.SwapParams({
                zeroForOne: _flipped,
                amountSpecified: int(ethSpent),
                sqrtPriceLimitX96: _flipped ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            })
        );

        // Confirm that we can buy more tokens now that we are out of FL
        poolSwap.swap(
            poolKey(_flipped),
            IPoolManager.SwapParams({
                zeroForOne: !_flipped,
                amountSpecified: -0.01 ether,
                sqrtPriceLimitX96: !_flipped ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            })
        );
    }

    function test_CanFairLaunchSwap(uint _supply) public {
        // Ensure our supply is within the full range (0 - 100%)
        _supply = bound(_supply, 0, 100);

        deal(address(WETH), address(poolManager), 1000e27 ether);

        initialPrice.setSqrtPriceX96(
            InitialPrice.InitialSqrtPriceX96({
                unflipped: FL_SQRT_PRICE_1_2,
                flipped: FL_SQRT_PRICE_2_1
            })
        );

        positionManager.flaunch(
            PositionManager.FlaunchParams(
                'name',
                'symbol',
                'https://token.gg/',
                supplyShare(_supply),
                0,
                address(this),
                0,
                0,
                abi.encode(''),
                abi.encode(1_000)
            )
        );

        // Deal enough ETH to fulfill the entire FairLaunch position
        deal(address(WETH), address(this), 1000e18);
        WETH.approve(address(poolSwap), type(uint).max);

        // Action our swap to buy all of the FairLaunch tokens from the pool
        poolSwap.swap(
            poolKey(false),
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -1000e18,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            })
        );
    }

    function test_CanFairLaunchWithScheduledFlaunch() public {
        deal(address(WETH), address(poolManager), 1000e27 ether);

        initialPrice.setSqrtPriceX96(
            InitialPrice.InitialSqrtPriceX96({
                unflipped: FL_SQRT_PRICE_1_2,
                flipped: FL_SQRT_PRICE_2_1
            })
        );

        uint startsAt = block.timestamp + 6 hours;
        uint endsAt = startsAt + fairLaunch.FAIR_LAUNCH_WINDOW();

        positionManager.flaunch(
            PositionManager.FlaunchParams({
                name: 'name',
                symbol: 'symbol',
                tokenUri: 'https://token.gg/',
                initialTokenFairLaunch: supplyShare(50),
                premineAmount: 0,
                creator: address(this),
                creatorFeeAllocation: 0,
                flaunchAt: startsAt,
                initialPriceParams: abi.encode(''),
                feeCalculatorParams: abi.encode(1_000)
            })
        );

        // Deal enough ETH to fulfill our tests
        deal(address(WETH), address(this), 0.5e18);
        WETH.approve(address(poolSwap), type(uint).max);

        assertFalse(fairLaunch.inFairLaunchWindow(poolId(false)));

        // Action our swap to buy all of the FairLaunch tokens from the pool
        vm.expectRevert();
        poolSwap.swap(
            poolKey(false),
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -0.1e18,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            })
        );

        // Shift forward to just before the window
        vm.warp(startsAt - 1);

        assertFalse(fairLaunch.inFairLaunchWindow(poolId(false)));

        // We should still revert
        vm.expectRevert();
        poolSwap.swap(
            poolKey(false),
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -0.1e18,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            })
        );

        // Skip to window opening
        vm.warp(startsAt + 1);

        assertTrue(fairLaunch.inFairLaunchWindow(poolId(false)));

        poolSwap.swap(
            poolKey(false),
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -0.1e18,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            })
        );

        // Move to just before window ends
        vm.warp(endsAt - 1);

        assertTrue(fairLaunch.inFairLaunchWindow(poolId(false)));

        poolSwap.swap(
            poolKey(false),
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -0.1e18,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            })
        );

        // Move outside window
        vm.warp(endsAt + 1);

        assertFalse(fairLaunch.inFairLaunchWindow(poolId(false)));

        poolSwap.swap(
            poolKey(false),
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -0.1e18,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            })
        );
    }

    function poolKey(bool _flipped) internal view returns (PoolKey memory) {
        return _flipped ? EXPECTED_FLIPPED_POOL_KEY : EXPECTED_POOL_KEY;
    }

    function poolId(bool _flipped) internal view returns (PoolId) {
        return _flipped ? EXPECTED_FLIPPED_POOL_ID : EXPECTED_POOL_ID;
    }

}
