// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BalanceDelta} from '@uniswap/v4-core/src/types/BalanceDelta.sol';
import {IPoolManager} from '@uniswap/v4-core/src/interfaces/IPoolManager.sol';
import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';
import {PoolManager} from '@uniswap/v4-core/src/PoolManager.sol';
import {PoolIdLibrary, PoolId} from '@uniswap/v4-core/src/types/PoolId.sol';
import {Hooks, IHooks} from '@uniswap/v4-core/src/libraries/Hooks.sol';
import {Currency} from '@uniswap/v4-core/src/types/Currency.sol';
import {TickMath} from '@uniswap/v4-core/src/libraries/TickMath.sol';
import {StateLibrary} from '@uniswap/v4-core/src/libraries/StateLibrary.sol';

import {BidWall} from '@flaunch/bidwall/BidWall.sol';
import {PositionManager} from '@flaunch/PositionManager.sol';
import {ProtocolRoles} from '@flaunch/libraries/ProtocolRoles.sol';

import {MemecoinMock} from 'test/mocks/MemecoinMock.sol';

import {FlaunchTest} from '../FlaunchTest.sol';


contract BidWallTest is FlaunchTest {

    using PoolIdLibrary for PoolKey;
    using StateLibrary for PoolManager;

    PoolKey poolKey;

    address alice;
    address memecoinTreasury;

    MemecoinMock memecoin;

    constructor () {
        // Deploy our platform
        _deployPlatform();

        // Create our memecoin
        address _memecoin = positionManager.flaunch(PositionManager.FlaunchParams('name', 'symbol', 'https://token.gg/', supplyShare(50), 30 minutes, 0, address(this), 50_00, 0, abi.encode(''), abi.encode(1_000)));
        memecoin = MemecoinMock(_memecoin);

        uint tokenId = flaunch.tokenId(_memecoin);

        // Register the treasury
        memecoinTreasury = flaunch.memecoinTreasury(tokenId);

        // Define Alice address and give her fat stacks
        alice = makeAddr('alice');
        memecoin.mint(alice, 100_000_000 ether);
        deal(address(WETH), alice, 100_000_000 ether);

        vm.startPrank(alice);
        memecoin.approve(address(poolModifyPosition), type(uint).max);
        memecoin.approve(address(poolSwap), type(uint).max);
        WETH.approve(address(poolModifyPosition), type(uint).max);
        WETH.approve(address(poolSwap), type(uint).max);
        vm.stopPrank();

        // Set low BidWall threshold for testing
        bidWall.setSwapFeeThreshold(0.001 ether);
    }

    function setUp() public {
        poolKey = PoolKey({
            currency0: Currency.wrap(address(WETH)),
            currency1: Currency.wrap(address(memecoin)),
            fee: 0,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(positionManager))
        });
    }

    function test_CanDisableWithCreator() external {
        // initialially the hook should be enabled
        (bool isHookDisabled,,,,,) = bidWall.poolInfo(poolKey.toId());
        assertEq(isHookDisabled, false);

        vm.expectEmit();
        emit BidWall.BidWallDisabledStateUpdated(poolKey.toId(), true);

        // it should update the hook disabled status
        bidWall.setDisabledState({_key: poolKey, _disable: true});
        (isHookDisabled,,,,,) = bidWall.poolInfo(poolKey.toId());
        assertEq(isHookDisabled, true);

        vm.expectEmit();
        emit BidWall.BidWallDisabledStateUpdated(poolKey.toId(), false);

        // enable back the hook
        bidWall.setDisabledState({_key: poolKey, _disable: false});
        (isHookDisabled,,,,,) = bidWall.poolInfo(poolKey.toId());
        assertEq(isHookDisabled, false);
    }

    function test_CannotDisableWithoutCreator() external {
        vm.prank(address(1));
        vm.expectRevert(BidWall.CallerIsNotCreator.selector);
        bidWall.setDisabledState({_key: poolKey, _disable: true});
    }

    function test_CannotDisableBidWallWithInvalidPoolKey(uint24 _invalidFee) public {
        // Update our PoolKey to modify the fee to be different. This should invalidate the PoolId
        // that is generated and prevent the BidWall from disabling. The maximum value is also set
        // as defined in the {PoolKey} struct definition.
        vm.assume(_invalidFee != poolKey.fee && _invalidFee < 1_000_000);
        poolKey.fee = _invalidFee;

        vm.expectRevert(abi.encodeWithSelector(PositionManager.UnknownPool.selector, poolKey.toId()));
        bidWall.setDisabledState({_key: poolKey, _disable: true});
    }

    function test_CannotCallCloseBidWallDirectly() external {
        vm.expectRevert(BidWall.NotPositionManager.selector);
        bidWall.closeBidWall(poolKey);
    }

    function test_CanPassFeesToTreasuryWhenHookIsDisabled() external poolHasLiquidity {
        // Disable the hook via a treasury call
        bidWall.setDisabledState(poolKey, true);

        // Make a swap as alice
        vm.startPrank(alice);
        _swap(
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: 5 ether,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            })
        );

        // The swap fee won't have been transferred, but instead allocated
        assertEq(positionManager.feeEscrow().balances(memecoinTreasury), 0.011277785202558418 ether);

        // Check the pool has no pending fees for the bidwall
        (,,,, uint pendingETHFees,) = bidWall.poolInfo(poolKey.toId());
        assertEq(pendingETHFees, 0);
    }

    function test_CanStoreFeeAllocationInInternalSwapPoolWhenETHIsSpecifiedToken() external poolHasLiquidity {
        vm.startPrank(alice);
        _swap(
            IPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: 5 ether,
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            })
        );
        vm.stopPrank();

        // Check the pool pending fees for the bidwall. Fees will have gone into
        // an internal swap pool at this point, so won't yet be seen.
        (,,,, uint pendingETHFees,) = bidWall.poolInfo(poolKey.toId());
        assertEq(pendingETHFees, 0);
    }

    function test_CanFundBidWallWithFees(bool _flipped) external flipTokens(_flipped) {
        /** START: Flipped pre-run **/

        // Provide the PoolManager with some ETH because otherwise it sulks about being poor
        deal(address(WETH), address(poolManager), 1000e27 ether);

        // Create our memecoin now that we have might have flipped.
        address _memecoin = positionManager.flaunch(PositionManager.FlaunchParams('name', 'symbol', 'https://token.gg/', supplyShare(50), 30 minutes, 0, address(this), 50_00, 0, abi.encode(''), abi.encode(1_000)));
        memecoin = MemecoinMock(_memecoin);
        memecoinTreasury = flaunch.memecoinTreasury(flaunch.tokenId(_memecoin));

        // Remint the tokens
        memecoin.mint(alice, 100_000_000 ether);
        deal(address(WETH), alice, 100_000_000 ether);

        vm.startPrank(alice);
        memecoin.approve(address(poolModifyPosition), type(uint).max);
        memecoin.approve(address(poolSwap), type(uint).max);
        WETH.approve(address(poolModifyPosition), type(uint).max);
        WETH.approve(address(poolSwap), type(uint).max);
        vm.stopPrank();

        // Update our PoolKey to flip
        poolKey = PoolKey({
            currency0: Currency.wrap(_flipped ? address(memecoin) : address(WETH)),
            currency1: Currency.wrap(_flipped ? address(WETH) : address(memecoin)),
            fee: 0,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(positionManager))
        });

        // Update the {BidWall} reference
        bidWall = positionManager.bidWall();
        bidWall.setSwapFeeThreshold(1);

        /** END: Flipped pre-run **/

        // Skip the FairLaunch from taking place
        _bypassFairLaunch();

        vm.startPrank(alice);

        // Perform a swap that builds fees ready to convert
        poolSwap.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: !_flipped,
                amountSpecified: -2 ether,
                sqrtPriceLimitX96: !_flipped ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            })
        );

        vm.warp(block.timestamp + 1 days);

        vm.expectEmit();
        emit BidWall.BidWallDeposit(poolKey.toId(), 9000000000000000, 9000000000000000);

        // Perform another swap that will that will initialize the BidWall with the fees earned
        poolSwap.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: !_flipped,
                amountSpecified: -2 ether,
                sqrtPriceLimitX96: !_flipped ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            })
        );
        vm.stopPrank();

        // BidWall should be initialized now
        (, bool preIsInitialized, int24 tickLower, int24 tickUpper,,) = bidWall.poolInfo(poolKey.toId());
        assertEq(preIsInitialized, true, 'BidWall is not initialized');

        // Capture our treasury balance before closing the BidWall
        uint preETHBalance = WETH.balanceOf(memecoinTreasury);
        uint preMemecoinBalance = memecoin.balanceOf(memecoinTreasury);

        // Close our BidWall. As we are the creator of the pool we can call this directly.
        bidWall.setDisabledState(poolKey, true);

        // Capture our treasury balance after closing the BidWall
        uint postETHBalance = WETH.balanceOf(memecoinTreasury);
        uint postMemecoinBalance = memecoin.balanceOf(memecoinTreasury);

        // It should move all liquidity from the BidWall to the memecoin treasury address
        assertGt(postETHBalance, preETHBalance, 'ETH balance did not increase');
        assertGe(postMemecoinBalance, preMemecoinBalance, 'Token balance not >=');

        // Confirm that our BidWall position now has zero liquidity
        (uint128 liquidity,,) = poolManager.getPositionInfo({
            poolId: poolKey.toId(),
            owner: address(bidWall),
            tickLower: tickLower,
            tickUpper: tickUpper,
            salt: 'bidwall'
        });
        assertEq(liquidity, 0, 'Liquidity should be empty');

        // It should have also set the BidWall to be not initialized
        (, bool postIsInitialized,,, uint postPendingETHFees,) = bidWall.poolInfo(poolKey.toId());
        assertEq(postIsInitialized, false, 'Should not be initialised');
        assertEq(postPendingETHFees, 0, 'Should have no pending fees');

        // We should still be able to call close, even though it is no longer initialized. This
        // will just mean that no ETH is withdrawn.
        bidWall.setDisabledState(poolKey, true);
    }

    function test_CanInitializeTheBidWallWithASwap() external poolHasLiquidity {
        // initially the BidWall is not initialized
        (, bool preIsInitialized,,,,) = bidWall.poolInfo(poolKey.toId());
        assertEq(preIsInitialized, false);

        // create 0.6~ in swap fees, which will pass our threshold and initialize
        vm.startPrank(alice);
        _swap(
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: 250 ether,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            })
        );
        vm.stopPrank();

        // It should initialize the BidWall, just below the current price
        (, bool initialized, int24 tickLower, int24 tickUpper,,) = bidWall.poolInfo(poolKey.toId());
        assertEq(initialized, true);

        (uint128 liquidity,,) = poolManager.getPositionInfo({
            poolId: poolKey.toId(),
            owner: address(bidWall),
            tickLower: tickLower,
            tickUpper: tickUpper,
            salt: 'bidwall'
        });

        // BidWall should now have sufficient liquidity
        assertGt(liquidity, 0);
    }

    function test_CanReceiveFullFairLaunchAmount(bool _flipped) external flipTokens(_flipped) {
        // Provide the PoolManager with some ETH because otherwise it sulks about being poor
        deal(address(WETH), address(poolManager), 1000e27 ether);

        // Create our memecoin now that we have might have flipped.
        address _memecoin = positionManager.flaunch(PositionManager.FlaunchParams('name', 'symbol', 'https://token.gg/', supplyShare(50), 30 minutes, 0, address(this), 50_00, 0, abi.encode(''), abi.encode(1_000)));
        memecoin = MemecoinMock(_memecoin);
        memecoinTreasury = flaunch.memecoinTreasury(flaunch.tokenId(_memecoin));

        // Remint the tokens
        memecoin.mint(alice, 100_000_000 ether);
        deal(address(WETH), alice, 100_000_000 ether);

        vm.startPrank(alice);
        memecoin.approve(address(poolModifyPosition), type(uint).max);
        memecoin.approve(address(poolSwap), type(uint).max);
        WETH.approve(address(poolModifyPosition), type(uint).max);
        WETH.approve(address(poolSwap), type(uint).max);
        vm.stopPrank();

        // Update our PoolKey to flip
        poolKey = PoolKey({
            currency0: Currency.wrap(_flipped ? address(memecoin) : address(WETH)),
            currency1: Currency.wrap(_flipped ? address(WETH) : address(memecoin)),
            fee: 0,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(positionManager))
        });

        // Set a really high threshold so that our FairLaunch amount won't surpass it
        bidWall = positionManager.bidWall();
        bidWall.setSwapFeeThreshold(100 ether);

        // Make some FairLaunch swaps
        vm.startPrank(alice);
        _swap(
            IPoolManager.SwapParams({
                zeroForOne: !_flipped,
                amountSpecified: -1 ether,
                sqrtPriceLimitX96: !_flipped ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            })
        );

        // End FairLaunch with another swap
        vm.warp(block.timestamp + 1 days);
        _swap(
            IPoolManager.SwapParams({
                zeroForOne: !_flipped,
                amountSpecified: -0.001 ether,
                sqrtPriceLimitX96: !_flipped ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            })
        );

        // So we haven't currently hit the threshold, so the BidWall should not be initialized
        (, bool initialized, int24 tickLower, int24 tickUpper, uint pendingETHFees, uint cumulativeSwapFees) = bidWall.poolInfo(poolKey.toId());
        assertEq(initialized, false, 'BidWall should not be initialized');

        vm.stopPrank();

        // Set a lower threshold, add a swap and then we should have the BidWall initialised
        bidWall.setSwapFeeThreshold(1);

        vm.startPrank(alice);
        vm.warp(block.timestamp + 1 days);
        _swap(
            IPoolManager.SwapParams({
                zeroForOne: !_flipped,
                amountSpecified: -0.001 ether,
                sqrtPriceLimitX96: !_flipped ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            })
        );

        // Confirm that the BidWall holds ETH, even under threshold. It should initialize the
        // BidWall, just below the current price
        (, initialized, tickLower, tickUpper, pendingETHFees, cumulativeSwapFees) = bidWall.poolInfo(poolKey.toId());
        assertEq(initialized, true, 'BidWall should be initialized');
        assertEq(pendingETHFees, 0, 'Invalid pendingETHFees');
        assertEq(cumulativeSwapFees, 0.00045 ether, 'Invalid cumulativeSwapFees');

        (uint128 liquidity,,) = poolManager.getPositionInfo({
            poolId: poolKey.toId(),
            owner: address(bidWall),
            tickLower: tickLower,
            tickUpper: tickUpper,
            salt: 'bidwall'
        });

        assertGt(liquidity, 0, 'Liquidity should be > 0');

        vm.stopPrank();
    }

    function test_CanSetSwapFeeThresholdWithOwner(uint _newSwapFeeThreshold) public {
        vm.expectEmit();
        emit BidWall.FixedSwapFeeThresholdUpdated(_newSwapFeeThreshold);

        bidWall.setSwapFeeThreshold(_newSwapFeeThreshold);
    }

    function test_CannotSetSwapFeeThresholdWithoutOwner(address _caller, uint _newSwapFeeThreshold) public {
        // Ensure the caller is not the owner
        vm.assume(_caller != address(this));

        // Expect a revert due to the onlyOwner modifier
        vm.startPrank(_caller);
        vm.expectRevert(UNAUTHORIZED);
        bidWall.setSwapFeeThreshold(_newSwapFeeThreshold);
        vm.stopPrank();
    }

    function test_CanTriggerStaleBidWallLiquidity() public poolHasLiquidity {
        // Provide the PoolManager with some ETH because otherwise it sulks about being poor
        // deal(address(WETH), address(poolManager), 1000e27 ether);

        // Skip the FairLaunch from taking place
        _bypassFairLaunch();

        // Set a really high threshold so that our FairLaunch amount won't surpass it
        bidWall.setSwapFeeThreshold(100 ether);

        vm.startPrank(alice);

        // Perform a swap that builds fees
        poolSwap.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: -1 ether,
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            })
        );

        uint expectedFees = 0.002248410133947398 ether;

        // We will now have fees stored in the BidWall
        (,,,, uint pendingETHFees, uint cumulativeSwapFees) = bidWall.poolInfo(poolKey.toId());
        assertEq(pendingETHFees, expectedFees, 'Invalid pendingETHFees');
        assertEq(cumulativeSwapFees, expectedFees, 'Invalid cumulativeSwapFees');

        // Move past our timeout
        vm.warp(block.timestamp + bidWall.staleTimeWindow());

        // Perform another swap that will trigger the stale liquidity to be added
        poolSwap.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: -1 ether,
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            })
        );
        vm.stopPrank();

        uint nextExpectedFees = 0.002245234892371601 ether;

        // We will now have fees stored in the BidWall, but also some fees moved into a position
        (,,,, pendingETHFees, cumulativeSwapFees) = bidWall.poolInfo(poolKey.toId());
        assertEq(pendingETHFees, nextExpectedFees, 'Invalid pendingETHFees');
        assertEq(cumulativeSwapFees, expectedFees + nextExpectedFees, 'Invalid cumulativeSwapFees');
    }

    /// @dev To run this test, comment out the Uniswap V4 Core {PoolManager} `onlyWhenUnlocked` logic
    /*
    function test_CanGetBidWallPosition() external {
        // Skip past FairLaunch
        vm.warp(block.timestamp + 365 days);

        // Get the empty position
        (uint amount0, uint amount1, uint pendingEth) = bidWall.position(poolKey.toId());
        assertEq(amount0, 0);
        assertEq(amount1, 0);
        assertEq(pendingEth, 0);

        // Provide sufficient tokens for the transactions
        memecoin.mint(address(this), 1 ether);
        deal(address(WETH), address(positionManager), 0.0015 ether);

        // Deposit an amount of ETH (this has to be pranked as the PositionManager for valid call). This
        // will store as pending. This is 1.5x the threshold.
        (, int24 tick,,) = poolManager.getSlot0(poolKey.toId());

        vm.startPrank(address(positionManager));
        WETH.approve(address(bidWall), type(uint).max);
        bidWall.depositIntoBidWall({
            _poolKey: poolKey,
            _ethSwapAmount: 0.0015 ether,
            _currentTick: tick,
            _nativeIsZero: true,
            _bypassThreshold: false
        });
        vm.stopPrank();

        // Get the position which should hold just ETH
        (amount0, amount1, pendingEth) = bidWall.position(poolKey.toId());
        assertEq(amount0, 1499999999999999);
        assertEq(amount1, 0);
        assertEq(pendingEth, 0);

        // Make a swap that sells some token into the BidWall position
        memecoin.approve(address(poolSwap), type(uint).max);
        _swap(
            IPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: -0.0025 ether,
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            })
        );

        // Get the position which should have some ETH, some token and dust fees in pending eth
        (amount0, amount1, pendingEth) = bidWall.position(poolKey.toId());
        assertEq(amount0, 256612490504217);
        assertEq(amount1, 2499999999999999);
        assertEq(pendingEth, 4351856283235);

        // Deposit some pending ETH below the threshold
        deal(address(WETH), address(positionManager), 0.00025 ether);

        vm.startPrank(address(positionManager));
        bidWall.depositIntoBidWall({
            _poolKey: poolKey,
            _ethSwapAmount: 0.00025 ether,
            _currentTick: tick,
            _nativeIsZero: true,
            _bypassThreshold: false
        });
        vm.stopPrank();

        // Get the position which should have some ETH, some token and some pending ETH
        (amount0, amount1, pendingEth) = bidWall.position(poolKey.toId());
        assertEq(amount0, 256612490504217);
        assertEq(amount1, 2499999999999999);
        assertEq(pendingEth, 254351856283235);
    }
    */

    // Helpers

    function _swap(IPoolManager.SwapParams memory swapParams) internal returns (BalanceDelta delta) {
        delta = poolSwap.swap(
            poolKey,
            swapParams
        );
    }

    modifier poolHasLiquidity() {
        // Ensure that FairLaunch period has ended for the token
        vm.warp(block.timestamp + 1 days);

        vm.startPrank(alice);
        poolModifyPosition.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(TICK_SPACING),
                tickUpper: TickMath.maxUsableTick(TICK_SPACING),
                liquidityDelta: 1000 ether,
                salt: ''
            }),
            ''
        );
        vm.stopPrank();

        _;
    }

}
