// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import {BalanceDelta, toBalanceDelta} from '@uniswap/v4-core/src/types/BalanceDelta.sol';
import {Currency} from '@uniswap/v4-core/src/types/Currency.sol';
import {Hooks, IHooks} from '@uniswap/v4-core/src/libraries/Hooks.sol';
import {IPoolManager, PoolManager, Pool} from '@uniswap/v4-core/src/PoolManager.sol';
import {LPFeeLibrary} from '@uniswap/v4-core/src/libraries/LPFeeLibrary.sol';
import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';
import {PoolIdLibrary, PoolId} from '@uniswap/v4-core/src/types/PoolId.sol';
import {TickMath} from '@uniswap/v4-core/src/libraries/TickMath.sol';

import {FeeDistributor} from '@flaunch/hooks/FeeDistributor.sol';
import {InternalSwapPool} from '@flaunch/hooks/InternalSwapPool.sol';
import {PositionManager} from '@flaunch/PositionManager.sol';
import {TokenSupply} from '@flaunch/libraries/TokenSupply.sol';

import {FlaunchTest} from '../FlaunchTest.sol';


contract InternalSwapPoolTest is FlaunchTest {

    using PoolIdLibrary for PoolKey;

    /**
     * @dev Indicates a failure with the `spender`’s `allowance`. Used in transfers.
     * @param spender Address that may be allowed to operate on tokens without being their owner.
     * @param allowance Amount of tokens a `spender` is allowed to operate with.
     * @param needed Minimum amount required to perform a transfer.
     */
    error ERC20InsufficientAllowance(address spender, uint allowance, uint needed);

    /**
     * @dev Indicates an error related to the current `balance` of a `sender`. Used in transfers.
     * @param sender Address whose tokens are being transferred.
     * @param balance Current balance for the interacting account.
     * @param needed Minimum amount required to perform a transfer.
     */
    error ERC20InsufficientBalance(address sender, uint balance, uint needed);

    /// Set up a test ID
    uint private constant TOKEN_ID = 1;

    /// The minimum value that can be returned from #getSqrtRatioAtTick. Equivalent to getSqrtRatioAtTick(MIN_TICK)
    uint160 internal constant MIN_SQRT_RATIO = 4306310044;

    /// The maximum value that can be returned from #getSqrtRatioAtTick. Equivalent to getSqrtRatioAtTick(MAX_TICK)
    uint160 internal constant MAX_SQRT_RATIO = 1457652066949847389969617340386294118487833376468;

    /// The maximum tick spacing for a number of oracle tests
    int24 constant MAX_TICK_SPACING = 32767;

    // Set a test-wide pool key
    PoolKey private _poolKey;

    // Store our memecoin created for the test
    address memecoin;

    constructor () {
        // Deploy our platform
        _deployPlatform();
    }

    /**
     * @dev `ClaimableFees` will always have the ETH amount as `amount0` and the non-ETH amount
     * will always be `amount1`. This doesn't matter if it is flipped or not.
     */
    function test_CanDepositFees(uint128 _amount0, uint128 _amount1, bool _flipped) public flipTokens(_flipped) {
        // Create our memecoin
        memecoin = positionManager.flaunch(PositionManager.FlaunchParams('name', 'symbol', 'https://token.gg/', supplyShare(50), 30 minutes, 0, address(this), 50_00, 0, abi.encode(''), abi.encode(1_000)));

        _bypassFairLaunch();

        // Reference our `_poolKey` for later tests
        _poolKey = positionManager.poolKey(memecoin);

        // Reference our memecoin
        IERC20 token = IERC20(memecoin);

        // Add non-ETH tokens to the pool fees, ready to swap into
        deal(address(WETH), address(this), _amount0);
        deal(address(token), address(this), _amount1);

        WETH.transfer(address(positionManager), _amount0);
        token.transfer(address(positionManager), _amount1);

        positionManager.depositFeesMock(_poolKey, _amount0, _amount1);

        // Confirm that the fees are ready
        InternalSwapPool.ClaimableFees memory fees = positionManager.poolFees(_poolKey);
        assertEq(fees.amount0, _amount0, 'Incorrect starting pool token0 fees');
        assertEq(fees.amount1, _amount1, 'Incorrect starting pool token1 fees');
    }

    function test_CanSwap_ZeroForOne_ExactOutput(bool _flipped) public flipTokens(_flipped) {
        // Create our memecoin
        memecoin = positionManager.flaunch(PositionManager.FlaunchParams('name', 'symbol', 'https://token.gg/', supplyShare(50), 30 minutes, 0, address(this), 50_00, 0, abi.encode(''), abi.encode(1_000)));

        _bypassFairLaunch();

        // Reference our `_poolKey` for later tests
        _poolKey = positionManager.poolKey(memecoin);

        // Add liquidity to the pool to allow for swaps
        _addLiquidityToPool(memecoin, int(10 ether), false);

        // Reference our memecoin
        IERC20 token = IERC20(memecoin);

        // Confirm our starting balance of the pool
        uint poolStartEth = 7.071067811865475244 ether;
        uint poolTokenStart = 14.142135623730950488 ether;

        assertEq(WETH.balanceOf(address(poolManager)), poolStartEth, 'Invalid starting poolManager ETH balance');
        assertEq(token.balanceOf(address(poolManager)), poolTokenStart, 'Invalid starting poolManager token balance');

        // Add non-ETH tokens to the pool fees, ready to swap into
        deal(address(token), address(this), 2 ether);
        token.transfer(address(positionManager), 2 ether);
        positionManager.depositFeesMock(_poolKey, 0, 2 ether);

        uint positionManagerStartEth = 0 ether;
        uint positionManagerTokenStart = TokenSupply.INITIAL_SUPPLY + 2 ether;

        assertEq(WETH.balanceOf(address(positionManager)), positionManagerStartEth, 'Invalid starting positionManager ETH balance');
        assertEq(token.balanceOf(address(positionManager)), positionManagerTokenStart, 'Invalid starting positionManager token balance');

        // Confirm that the fees are ready
        InternalSwapPool.ClaimableFees memory fees = positionManager.poolFees(_poolKey);
        assertEq(fees.amount0, 0, 'Incorrect starting pool ETH fees');
        assertEq(fees.amount1, 2 ether, 'Incorrect starting pool token1 fees');

        // Get our user's starting balances
        deal(address(WETH), address(this), 10 ether);
        WETH.approve(address(poolSwap), type(uint).max);

        // Confirm that the pool fee tokens have been swapped to ETH
        vm.expectEmit();
        uint internalSwapEthInput = 1.164715669629907659 ether;
        uint internalSwapTokenOutput = 2 ether;

        uint internalSwapEthSwapFee = 0.011647156696299076 ether;

        emit InternalSwapPool.PoolFeesSwapped(_poolKey.toId(), !_flipped, internalSwapEthInput, internalSwapTokenOutput);

        // Make a swap that requests 3 tokens, paying any amount of ETH to get those tokens
        poolSwap.swap(
            _poolKey,
            IPoolManager.SwapParams({
                zeroForOne: !_flipped,
                amountSpecified: 3 ether,
                sqrtPriceLimitX96: !_flipped ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            })
        );

        // Confirm that the pool fee tokens have been swapped to ETH
        fees = positionManager.poolFees(_poolKey);
        assertEq(fees.amount0, 0, 'Incorrect closing pool ETH fees');
        assertEq(fees.amount1, 0, 'Incorrect closing pool token1 fees');

        // Determine the amount that Uniswap takes in ETH for the remaining
        uint uniswapSwapEthInput = 0.501575448855083099 ether;
        uint uniswapSwapTokenOutput = 1 ether;
        uint uniswapSwapEthSwapFee = 0.005015754488550830 ether;

        // Confirm that the user has received their total expected tokens
        assertEq(WETH.balanceOf(address(this)), 10 ether - internalSwapEthInput - uniswapSwapEthInput - internalSwapEthSwapFee - uniswapSwapEthSwapFee, 'Invalid closing user ETH balance');
        assertEq(token.balanceOf(address(this)), internalSwapTokenOutput + uniswapSwapTokenOutput, 'Invalid closing user token balance');
    }

    function test_CanSwap_ZeroForOne_ExactInput(bool _flipped) public flipTokens(_flipped) {
        // Create our Memecoin
        memecoin = positionManager.flaunch(PositionManager.FlaunchParams('name', 'symbol', 'https://token.gg/', supplyShare(50), 30 minutes, 0, address(this), 50_00, 0, abi.encode(''), abi.encode(1_000)));

        _bypassFairLaunch();

        // Reference our `_poolKey` for later tests
        _poolKey = positionManager.poolKey(memecoin);

        // Add liquidity to the pool to allow for swaps
        _addLiquidityToPool(memecoin, int(10 ether), false);

        // Reference our memecoin
        IERC20 token = IERC20(memecoin);

        // Confirm our starting balance of the pool
        uint poolStartEth = 7.071067811865475244 ether;
        uint poolTokenStart = 14.142135623730950488 ether;

        assertEq(WETH.balanceOf(address(poolManager)), poolStartEth, 'Invalid starting poolManager ETH balance');
        assertEq(token.balanceOf(address(poolManager)), poolTokenStart, 'Invalid starting poolManager token balance');

        // Add non-ETH tokens to the pool fees, ready to swap into
        deal(address(token), address(this), 2 ether);
        token.transfer(address(positionManager), 2 ether);
        positionManager.depositFeesMock(_poolKey, 0, 2 ether);

        // Confirm that the fees are ready
        InternalSwapPool.ClaimableFees memory fees = positionManager.poolFees(_poolKey);
        assertEq(fees.amount0, 0, 'Incorrect starting pool ETH fees');
        assertEq(fees.amount1, 2 ether, 'Incorrect starting pool token1 fees');

        uint positionManagerStartEth = 0 ether;
        uint positionManagerTokenStart = TokenSupply.INITIAL_SUPPLY + 2 ether;

        assertEq(WETH.balanceOf(address(positionManager)), positionManagerStartEth, 'Invalid starting positionManager ETH balance');
        assertEq(token.balanceOf(address(positionManager)), positionManagerTokenStart, 'Invalid starting positionManager token balance');

        // Get our user's starting balances
        deal(address(WETH), address(this), 10 ether);
        WETH.approve(address(poolSwap), type(uint).max);

        // Confirm that the pool fee tokens have been swapped to ETH
        vm.expectEmit();
        uint internalSwapEthInput = 0.292893218813452475 ether;
        uint internalSwapTokenOutput = 2 ether;

        uint internalSwapTokenSwapFee = 0.02 ether;

        emit InternalSwapPool.PoolFeesSwapped(_poolKey.toId(), !_flipped, internalSwapEthInput, internalSwapTokenOutput);

        poolSwap.swap(
            _poolKey,
            IPoolManager.SwapParams({
                zeroForOne: !_flipped,
                amountSpecified: -5 ether,
                sqrtPriceLimitX96: !_flipped ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            })
        );

        // Confirm that the pool fee tokens have been swapped to ETH, but new tokens will have
        // come in to be hit in the next swap due to fees on the internal swap
        fees = positionManager.poolFees(_poolKey);
        assertEq(fees.amount0, 0, 'Incorrect closing pool ETH fees');
        assertEq(fees.amount1, 0.113843438963717918 ether, 'Incorrect closing pool token1 fees');

        // Determine the amount that Uniswap takes in ETH for the remaining
        uint uniswapSwapEthInput = 4.707106781186547525 ether;
        uint uniswapSwapTokenOutput = 9.384343896371791814 ether;
        uint uniswapSwapTokenSwapFee = 0.093843438963717918 ether;

        // Confirm that the user has received their total expected tokens
        assertEq(WETH.balanceOf(address(this)), 10 ether - internalSwapEthInput - uniswapSwapEthInput, 'Invalid closing user ETH balance');
        assertEq(token.balanceOf(address(this)), internalSwapTokenOutput + uniswapSwapTokenOutput - internalSwapTokenSwapFee - uniswapSwapTokenSwapFee, 'Invalid closing user token balance');
    }

}
