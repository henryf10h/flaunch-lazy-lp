// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import {IPoolManager} from '@uniswap/v4-core/src/interfaces/IPoolManager.sol';
import {toBeforeSwapDelta} from '@uniswap/v4-core/src/types/BeforeSwapDelta.sol';
import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';
import {PoolIdLibrary, PoolId} from '@uniswap/v4-core/src/types/PoolId.sol';
import {Hooks, IHooks} from '@uniswap/v4-core/src/libraries/Hooks.sol';
import {Currency} from '@uniswap/v4-core/src/types/Currency.sol';
import {TickMath} from '@uniswap/v4-core/src/libraries/TickMath.sol';

import {FairLaunch} from '@flaunch/hooks/FairLaunch.sol';
import {Flaunch} from '@flaunch/Flaunch.sol';
import {InitialPrice} from '@flaunch/price/InitialPrice.sol';
import {PositionManager} from '@flaunch/PositionManager.sol';
import {TokenSupply} from '@flaunch/libraries/TokenSupply.sol';
import {UniswapHookEvents} from '@flaunch/libraries/UniswapHookEvents.sol';

import {IMemecoin} from '@flaunch-interfaces/IMemecoin.sol';

import {FlaunchTest} from './FlaunchTest.sol';


contract PositionManagerTest is FlaunchTest {

    using PoolIdLibrary for PoolKey;

    constructor () {
        // Deploy our platform
        _deployPlatform();
    }

    function test_CanGetDefaultSettings() public view {
        // Set our default sqrtPriceX96 that tokens will start at
        assertEq(initialPrice.getSqrtPriceX96(address(this), false, abi.encode('')), FL_SQRT_PRICE_1_2);
        assertEq(initialPrice.getSqrtPriceX96(address(this), true, abi.encode('')), FL_SQRT_PRICE_2_1);
    }

    function test_CanFlaunch(uint24 _creatorFeeAllocation, bool _flipped) public flipTokens(_flipped) {
        vm.assume(_creatorFeeAllocation <= 100_00);

        address memecoin = positionManager.flaunch(
            PositionManager.FlaunchParams({
                name: 'Token Name',
                symbol: 'TOKEN',
                tokenUri: 'https://flaunch.gg/',
                initialTokenFairLaunch: supplyShare(50),
                premineAmount: 0,
                creator: address(this),
                creatorFeeAllocation: _creatorFeeAllocation,
                flaunchAt: 0,
                initialPriceParams: abi.encode(''),
                feeCalculatorParams: abi.encode(1_000)
            })
        );

        assertEq(IERC20(memecoin).balanceOf(address(positionManager)), TokenSupply.INITIAL_SUPPLY);

        PoolKey memory poolKey = positionManager.poolKey(memecoin);
        uint tokenId = flaunch.tokenId(memecoin);

        assertEq(Currency.unwrap(poolKey.currency0), _flipped ? memecoin : address(WETH));
        assertEq(Currency.unwrap(poolKey.currency1), _flipped ? address(WETH) : memecoin);
        assertEq(poolKey.fee, 0);
        assertEq(poolKey.tickSpacing, 60);
        assertEq(address(poolKey.hooks), address(positionManager));

        assertEq(IMemecoin(memecoin).name(), 'Token Name');
        assertEq(IMemecoin(memecoin).symbol(), 'TOKEN');
        assertEq(IMemecoin(memecoin).tokenURI(), 'https://flaunch.gg/');
        assertEq(flaunch.ownerOf(tokenId), address(this));
        assertEq(flaunch.memecoin(tokenId), memecoin);
        assertEq(flaunch.tokenURI(tokenId), 'https://api.flaunch.gg/token/1');
    }

    function test_CanMassFlaunch(uint8 flaunchCount, bool _flipped) public flipTokens(_flipped) {
        for (uint i; i < flaunchCount; ++i) {
            positionManager.flaunch(
                PositionManager.FlaunchParams({
                    name: 'Token Name',
                    symbol: 'TOKEN',
                    tokenUri: 'https://flaunch.gg/',
                    initialTokenFairLaunch: supplyShare(50),
                    premineAmount: 0,
                    creator: address(this),
                    creatorFeeAllocation: 50_00,
                    flaunchAt: 0,
                    initialPriceParams: abi.encode(''),
                    feeCalculatorParams: abi.encode(1_000)
                })
            );
        }
    }

    // Test that only the owner can call setInitialPrice
    function test_CanOnlySetInitialPriceAsOwner() public {
        // Call as non-owner, should revert
        vm.startPrank(address(1));
        vm.expectRevert(UNAUTHORIZED);
        positionManager.setInitialPrice(address(initialPrice));
        vm.stopPrank();

        // Call as owner, should succeed
        positionManager.setInitialPrice(address(initialPrice));
    }

    // Test setting a valid InitialPrice contract
    function test_CanSetValidInitialPrice() public {
        // Set valid InitialPrice contract
        positionManager.setInitialPrice(address(initialPrice));

        // Ensure the contract state was updated correctly
        assertEq(
            address(positionManager.getInitialPrice()),
            address(initialPrice),
            'Initial price contract should be set correctly'
        );
    }

    // Test that InitialPriceUpdated event is emitted when the initial price is set
    function test_CanGetInitialPriceUpdatedEvent() public {
        // Expect the InitialPriceUpdated event
        vm.expectEmit();
        emit PositionManager.InitialPriceUpdated(address(initialPrice));

        // Call as owner to set valid InitialPrice and emit event
        positionManager.setInitialPrice(address(initialPrice));
    }

    function test_CanScheduleFlaunch() public {
        PoolId expectedPoolId = PoolId.wrap(bytes32(0x38a1bfdc44f2dcf975eeca8e31a623cd8c8a05b243c4137c58f1b32a459b5e7d));

        vm.expectEmit();
        emit PositionManager.PoolScheduled(expectedPoolId, block.timestamp + 15 days);

        positionManager.flaunch(
            PositionManager.FlaunchParams({
                name: 'Token Name',
                symbol: 'TOKEN',
                tokenUri: 'https://flaunch.gg/',
                initialTokenFairLaunch: supplyShare(50),
                premineAmount: 0,
                creator: address(this),
                creatorFeeAllocation: 50_00,
                flaunchAt: block.timestamp + 15 days,
                initialPriceParams: abi.encode(''),
                feeCalculatorParams: abi.encode(1_000)
            })
        );
    }

    function test_CannotScheduleFlaunchWithLargeDuration(uint _duration) public {
        vm.assume(_duration > flaunch.MAX_SCHEDULE_DURATION());

        vm.expectRevert();
        positionManager.flaunch(
            PositionManager.FlaunchParams({
                name: 'Token Name',
                symbol: 'TOKEN',
                tokenUri: 'https://flaunch.gg/',
                initialTokenFairLaunch: supplyShare(50),
                premineAmount: 0,
                creator: address(this),
                creatorFeeAllocation: 50_00,
                flaunchAt: block.timestamp + _duration,
                initialPriceParams: abi.encode(''),
                feeCalculatorParams: abi.encode(1_000)
            })
        );
    }

    function test_CanCaptureDelta() public {
        int amount0;
        int amount1;

        address TOKEN = address(1);

        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(address(WETH)),
            currency1: Currency.wrap(TOKEN),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(address(positionManager))
        });

        PoolKey memory flippedPoolKey = PoolKey({
            currency0: Currency.wrap(TOKEN),
            currency1: Currency.wrap(address(WETH)),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(address(positionManager))
        });

        // This is ETH -> TOKEN on an unflipped pool
        // ETH is specified, TOKEN is unspecified
        (amount0, amount1) = positionManager.captureDelta(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -1 ether,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            toBeforeSwapDelta(-1 ether, 1 ether)
        );

        assertEq(amount0, 1 ether);
        assertEq(amount1, -1 ether);

        (amount0, amount1) = positionManager.captureDeltaSwapFee(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -1 ether,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            1 ether
        );

        assertEq(amount0, 0);
        assertEq(amount1, -1 ether);

        // This is ETH -> TOKEN on an unflipped pool
        // TOKEN is specified, ETH is unspecified
        (amount0, amount1) = positionManager.captureDelta(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: 1 ether,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            toBeforeSwapDelta(1 ether, -1 ether)
        );

        assertEq(amount0, 1 ether);
        assertEq(amount1, -1 ether);

        (amount0, amount1) = positionManager.captureDeltaSwapFee(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: 1 ether,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            1 ether
        );

        assertEq(amount0, -1 ether);
        assertEq(amount1, 0);

        // This is TOKEN -> ETH on an unflipped pool
        // TOKEN is specified, ETH is unspecified
        (amount0, amount1) = positionManager.captureDelta(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: -1 ether,
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            toBeforeSwapDelta(1 ether, -1 ether)
        );

        assertEq(amount0, 1 ether);
        assertEq(amount1, -1 ether);

        (amount0, amount1) = positionManager.captureDeltaSwapFee(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: -1 ether,
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            1 ether
        );

        assertEq(amount0, -1 ether);
        assertEq(amount1, 0);

        // This is TOKEN -> ETH on an unflipped pool
        // ETH is specified, TOKEN is unspecified
        (amount0, amount1) = positionManager.captureDelta(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: 1 ether,
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            toBeforeSwapDelta(-1 ether, 1 ether)
        );

        assertEq(amount0, 1 ether);
        assertEq(amount1, -1 ether);

        (amount0, amount1) = positionManager.captureDeltaSwapFee(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: 1 ether,
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            1 ether
        );

        assertEq(amount0, 0);
        assertEq(amount1, -1 ether);

        // This is ETH -> TOKEN on an flipped pool
        // ETH is specified, TOKEN is unspecified
        (amount0, amount1) = positionManager.captureDelta(
            flippedPoolKey,
            IPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: -1 ether,
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            toBeforeSwapDelta(-1 ether, 1 ether)
        );

        assertEq(amount0, -1 ether);
        assertEq(amount1, 1 ether);

        (amount0, amount1) = positionManager.captureDeltaSwapFee(
            flippedPoolKey,
            IPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: -1 ether,
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            1 ether
        );

        assertEq(amount0, -1 ether);
        assertEq(amount1, 0);

        // This is ETH -> TOKEN on an flipped pool
        // TOKEN is specified, ETH is unspecified
        (amount0, amount1) = positionManager.captureDelta(
            flippedPoolKey,
            IPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: 1 ether,
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            toBeforeSwapDelta(1 ether, -1 ether)
        );

        assertEq(amount0, -1 ether);
        assertEq(amount1, 1 ether);

        // This is TOKEN -> ETH on an flipped pool
        // TOKEN is specified, ETH is unspecified
        (amount0, amount1) = positionManager.captureDelta(
            flippedPoolKey,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -1 ether,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            toBeforeSwapDelta(1 ether, -1 ether)
        );

        assertEq(amount0, -1 ether);
        assertEq(amount1, 1 ether);

        // This is TOKEN -> ETH on an flipped pool
        // ETH is specified, TOKEN is unspecified
        (amount0, amount1) = positionManager.captureDelta(
            flippedPoolKey,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: 1 ether,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            toBeforeSwapDelta(-1 ether, 1 ether)
        );

        assertEq(amount0, -1 ether);
        assertEq(amount1, 1 ether);
    }

    function test_CanBurn721IfCreator() public {
        address memecoin = positionManager.flaunch(
            PositionManager.FlaunchParams({
                name: 'Token Name',
                symbol: 'TOKEN',
                tokenUri: 'https://flaunch.gg/',
                initialTokenFairLaunch: supplyShare(50),
                premineAmount: 0,
                creator: address(this),
                creatorFeeAllocation: 50_00,
                flaunchAt: 0,
                initialPriceParams: abi.encode(''),
                feeCalculatorParams: abi.encode(1_000)
            })
        );

        flaunch.burn(flaunch.tokenId(memecoin));
    }

    function test_CanBurn721IfApproved() public {
        address memecoin = positionManager.flaunch(
            PositionManager.FlaunchParams({
                name: 'Token Name',
                symbol: 'TOKEN',
                tokenUri: 'https://flaunch.gg/',
                initialTokenFairLaunch: supplyShare(50),
                premineAmount: 0,
                creator: address(this),
                creatorFeeAllocation: 50_00,
                flaunchAt: 0,
                initialPriceParams: abi.encode(''),
                feeCalculatorParams: abi.encode(1_000)
            })
        );

        uint tokenId = flaunch.tokenId(memecoin);

        address approvedCaller = address(1);
        flaunch.approve(approvedCaller, tokenId);

        vm.prank(approvedCaller);
        flaunch.burn(tokenId);
    }

    function test_CannotBurn721IfNotCreatorOrApproved() public {
        address memecoin = positionManager.flaunch(
            PositionManager.FlaunchParams({
                name: 'Token Name',
                symbol: 'TOKEN',
                tokenUri: 'https://flaunch.gg/',
                initialTokenFairLaunch: supplyShare(50),
                premineAmount: 0,
                creator: address(this),
                creatorFeeAllocation: 50_00,
                flaunchAt: 0,
                initialPriceParams: abi.encode(''),
                feeCalculatorParams: abi.encode(1_000)
            })
        );

        uint tokenId = flaunch.tokenId(memecoin);

        address unapprovedCaller = address(1);

        vm.prank(unapprovedCaller);
        vm.expectRevert(bytes4(0x4b6e7f18)); // NotOwnerNorApproved()
        flaunch.burn(tokenId);
    }

    function test_CannotFlaunchWithInvalidCreatorFeeAllocation(uint24 _creatorFeeAllocation) public {
        vm.assume(_creatorFeeAllocation > 100_00);

        vm.expectRevert(abi.encodeWithSelector(Flaunch.CreatorFeeAllocationInvalid.selector, _creatorFeeAllocation, flaunch.MAX_CREATOR_ALLOCATION()));
        positionManager.flaunch(
            PositionManager.FlaunchParams({
                name: 'Token Name',
                symbol: 'TOKEN',
                tokenUri: 'https://flaunch.gg/',
                initialTokenFairLaunch: supplyShare(50),
                premineAmount: 0,
                creator: address(this),
                creatorFeeAllocation: _creatorFeeAllocation,
                flaunchAt: 0,
                initialPriceParams: abi.encode(''),
                feeCalculatorParams: abi.encode(1_000)
            })
        );
    }

    function test_CanCaptureHookSwapEvents() public {
        // Flaunch our new token
        address memecoin = positionManager.flaunch(
            PositionManager.FlaunchParams({
                name: 'Token Name',
                symbol: 'TOKEN',
                tokenUri: 'https://flaunch.gg/',
                initialTokenFairLaunch: 1e18,
                premineAmount: 0,
                creator: address(this),
                creatorFeeAllocation: 0,
                flaunchAt: 0,
                initialPriceParams: abi.encode(''),
                feeCalculatorParams: abi.encode(1_000)
            })
        );

        // Get the {PoolKey} that we will swap against
        PoolKey memory poolKey = positionManager.poolKey(memecoin);

        flETH.deposit{value: 100 ether}();

        // Provide this test contract enough flETH to make the swap
        flETH.approve(address(poolSwap), type(uint).max);

        // Provide the PoolManager with some ETH because otherwise it sulks about being poor
        flETH.transfer(address(poolManager), 50 ether);

        // Mock a deposit into the ISP
        // deal(memecoin, address(positionManager), IERC20(memecoin).balanceOf(positionManager) + 0.5 ether);
        flETH.transfer(address(positionManager), 0.5 ether);
        positionManager.depositFeesMock(poolKey, 0.5 ether, 0.5 ether);

        // Detect our PositionManager swap
        vm.expectEmit();
        emit PositionManager.PoolSwap({
            poolId: poolKey.toId(),
            flAmount0: -500040918299108460,
            flAmount1: 1000000000000000000,
            flFee0: 0,
            flFee1: -10000000000000000,
            ispAmount0: 0,
            ispAmount1: 0,
            ispFee0: 0,
            ispFee1: 0,
            uniAmount0: -19499959081700891540,
            uniAmount1: 503396135662060805,
            uniFee0: 0,
            uniFee1: -5033961356620608
        });

        // Detect our Uniswap V4 swap
        vm.expectEmit();
        emit UniswapHookEvents.HookSwap({
            id: PoolId.unwrap(poolKey.toId()),
            sender: address(poolSwap),
            amount0: -500040918299108460,
            amount1: 1000000000000000000,
            hookLPfeeAmount0: 0,
            hookLPfeeAmount1: 0
        });

        vm.expectEmit();
        emit UniswapHookEvents.HookFee({
            id: PoolId.unwrap(poolKey.toId()),
            sender: address(poolSwap),
            feeAmount0: 0,
            feeAmount1: 10000000000000000
        });

        poolSwap.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -20 ether,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            })
        );
    }

}
