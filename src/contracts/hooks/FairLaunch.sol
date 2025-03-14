// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AccessControl} from '@openzeppelin/contracts/access/AccessControl.sol';

import {BeforeSwapDelta, toBeforeSwapDelta} from '@uniswap/v4-core/src/types/BeforeSwapDelta.sol';
import {BalanceDelta, toBalanceDelta} from '@uniswap/v4-core/src/types/BalanceDelta.sol';
import {Currency} from '@uniswap/v4-core/src/types/Currency.sol';
import {FullMath} from '@uniswap/v4-core/src/libraries/FullMath.sol';
import {IPoolManager} from '@uniswap/v4-core/src/interfaces/IPoolManager.sol';
import {LiquidityAmounts} from '@uniswap/v4-core/test/utils/LiquidityAmounts.sol';
import {PoolId, PoolIdLibrary} from '@uniswap/v4-core/src/types/PoolId.sol';
import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';
import {SafeCast} from '@uniswap/v4-core/src/libraries/SafeCast.sol';
import {TickMath} from '@uniswap/v4-core/src/libraries/TickMath.sol';

import {CurrencySettler} from '@flaunch/libraries/CurrencySettler.sol';
import {ProtocolRoles} from '@flaunch/libraries/ProtocolRoles.sol';
import {TickFinder} from '@flaunch/types/TickFinder.sol';


/**
 * Adds functionality to the {PositionManager} that promotes a fair token launch.
 *
 * This creates a time window right after the token is launched that keeps the token at
 * the same price in a single tick position. Fees earned from this are kept within the
 * position and cannot be sold into until the fair launch window has finished.
 *
 * Once the FairLaunch period has ended, the ETH raised and the remaining tokens are
 * both deployed into a Uniswap position to facilitate ongoing transactions and create
 * a price discovery.
 *
 * @dev Based on: https://github.com/fico23/fundraise-hook
 */
contract FairLaunch is AccessControl {

    using CurrencySettler for Currency;
    using PoolIdLibrary for PoolKey;
    using SafeCast for *;
    using TickFinder for int24;

    error CannotModifyLiquidityDuringFairLaunch();
    error CannotSellTokenDuringFairLaunch();
    error NotPositionManager();

    /// Emitted when a Fair Launch position is created
    event FairLaunchCreated(PoolId indexed _poolId, uint _tokens, uint _startsAt, uint _endsAt);

    /// Emitted when a Fair Launch is ended and rebalanced
    event FairLaunchEnded(PoolId indexed _poolId, uint _revenue, uint _supply, uint _endedAt);

    /**
     * Holds FairLaunch information for a Pool.
     *
     * @member startsAt The unix timestamp that the FairLaunch window starts
     * @member endsAt The unix timestamp that the FairLaunch window ends
     * @member initialTick The tick that the FairLaunch position was created at
     * @member revenue The amount of revenue earned by the FairLaunch position
     * @member supply The amount of supply in the FairLaunch
     * @member closed If the FairLaunch has been closed
     */
    struct FairLaunchInfo {
        uint startsAt;
        uint endsAt;
        int24 initialTick;
        uint revenue;
        uint supply;
        bool closed;
    }

    /// Our fair launch window duration
    uint public constant FAIR_LAUNCH_WINDOW = 30 minutes;

    /// Maps a PoolId to a FairLaunchInfo struct
    mapping (PoolId _poolId => FairLaunchInfo _info) internal _fairLaunchInfo;

    /// Our Uniswap V4 {PoolManager} contract address
    IPoolManager public immutable poolManager;

    /**
     * Stores our native token.
     *
     * @param _poolManager The Uniswap V4 {PoolManager} contract
     */
    constructor (IPoolManager _poolManager) {
        poolManager = _poolManager;

        // Set our caller to have the default admin of protocol roles
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    /**
     * Checks if the {PoolKey} is within the fair launch window.
     *
     * @param _poolId The ID of the PoolKey
     *
     * @return If the {PoolKey} is within the fair launch window
     */
    function inFairLaunchWindow(PoolId _poolId) public view returns (bool) {
        FairLaunchInfo memory info = _fairLaunchInfo[_poolId];
        return block.timestamp >= info.startsAt && block.timestamp < info.endsAt;
    }

    /**
     * Helper function to call the FairLaunchInfo struct for a pool.
     *
     * @param _poolId The ID of the PoolKey
     *
     * @return The FairLaunchInfo for the pool
     */
    function fairLaunchInfo(PoolId _poolId) public view returns (FairLaunchInfo memory) {
        return _fairLaunchInfo[_poolId];
    }

    /**
     * Creates an initial fair launch position.
     *
     * @param _poolId The ID for the pool being initialized
     * @param _initialTokenFairLaunch The amount of tokens to add as single sided fair launch liquidity
     */
    function createPosition(
        PoolId _poolId,
        int24 _initialTick,
        uint _flaunchesAt,
        uint _initialTokenFairLaunch
    ) public virtual onlyPositionManager returns (
        FairLaunchInfo memory
    ) {
        // Determine the time that the fair launch window will close
        uint endsAt = _flaunchesAt + FAIR_LAUNCH_WINDOW;

        // Map these tokens into an pseudo-escrow that we can reference during the sale
        // and activate our pool fair launch window.
        _fairLaunchInfo[_poolId] = FairLaunchInfo({
            startsAt: _flaunchesAt,
            endsAt: endsAt,
            initialTick: _initialTick,
            revenue: 0,
            supply: _initialTokenFairLaunch,
            closed: false
        });

        emit FairLaunchCreated(_poolId, _initialTokenFairLaunch, _flaunchesAt, endsAt);
        return _fairLaunchInfo[_poolId];
    }

    /**
     * Closes the FairLaunch position and recreates the position as a wide range position immediately
     * above the tick for our memecoin. This position is comprised of any unsold Memecoin
     * from the FairLaunch, as well as the remaining supply from mint.
     *
     * @param _poolKey The PoolKey we are closing the FairLaunch position of
     * @param _tokenFees The amount of token fees that need to remain in the {PositionManager}
     * @param _nativeIsZero If our native token is `currency0`
     */
    function closePosition(
        PoolKey memory _poolKey,
        uint _tokenFees,
        bool _nativeIsZero
    ) public onlyPositionManager returns (
        FairLaunchInfo memory
    ) {
        // Reference the pool's FairLaunchInfo, ready to store updated values
        FairLaunchInfo storage info = _fairLaunchInfo[_poolKey.toId()];

        int24 tickLower;
        int24 tickUpper;

        if (_nativeIsZero) {
            // ETH position
            tickLower = (info.initialTick + 1).validTick(false);
            tickUpper = tickLower + TickFinder.TICK_SPACING;
            _createImmutablePosition(_poolKey, tickLower, tickUpper, info.revenue, true);

            // memecoin position
            tickLower = TickFinder.MIN_TICK;
            tickUpper = (info.initialTick - 1).validTick(true);
            _createImmutablePosition(_poolKey, tickLower, tickUpper, _poolKey.currency1.balanceOf(msg.sender) - _tokenFees, false);
        } else {
            // ETH position
            tickUpper = (info.initialTick - 1).validTick(true);
            tickLower = tickUpper - TickFinder.TICK_SPACING;
            _createImmutablePosition(_poolKey, tickLower, tickUpper, info.revenue, false);

            // memecoin position
            tickLower = (info.initialTick + 1).validTick(false);
            tickUpper = TickFinder.MAX_TICK;
            _createImmutablePosition(_poolKey, tickLower, tickUpper, _poolKey.currency0.balanceOf(msg.sender) - _tokenFees, true);
        }

        // Mark our position as closed
        info.endsAt = block.timestamp;
        info.closed = true;

        // Emit the event with the balance of the currency we hold before we create a position with
        // it. We determine the end time by seeing if it has ended early, or if we are past the point
        // it was meant to end then we backdate it.
        emit FairLaunchEnded(_poolKey.toId(), info.revenue, info.supply, info.endsAt);

        return info;
    }

    /**
     * When we are filling from our Fair Launch position, we will always be buying tokens
     * with ETH. The amount specified that is passed in, however, could be positive or negative.
     *
     * The positive / negative flag will require us to calculate the amount the user will get in
     * a different way. Positive: How much ETH it costs to get amount. Negative: How many tokens
     * I can get for amount.
     *
     * The amount requested **can** exceed the Fair Launch position, but we will additionally
     * have to call `_closeFairLaunchPosition` to facilitate it during this call. This will
     * provide additional liquidity before the swap actually takes place.
     *
     * @dev `zeroForOne` will always be equal to `_nativeIsZero` as it will always be ETH -> Token.
     *
     * @param _poolKey The PoolKey we are filling from
     * @param _amountSpecified The amount specified in the swap
     * @param _nativeIsZero If our native token is `currency0`
     *
     * @return beforeSwapDelta_ The modified swap delta
     */
    function fillFromPosition(
        PoolKey memory _poolKey,
        int _amountSpecified,
        bool _nativeIsZero
    ) public onlyPositionManager returns (
        BeforeSwapDelta beforeSwapDelta_,
        BalanceDelta balanceDelta_,
        FairLaunchInfo memory fairLaunchInfo_
    ) {
        PoolId poolId = _poolKey.toId();
        FairLaunchInfo storage info = _fairLaunchInfo[poolId];

        // No tokens, no fun.
        if (_amountSpecified == 0) {
            return (beforeSwapDelta_, balanceDelta_, info);
        }

        uint ethIn;
        uint tokensOut;

        // If we have a negative amount specified, then we have an ETH amount passed in and want
        // to buy as many tokens as we can for that price.
        if (_amountSpecified < 0) {
            ethIn = uint(-_amountSpecified);
            tokensOut = _getQuoteAtTick(
                info.initialTick,
                ethIn,
                Currency.unwrap(_nativeIsZero ? _poolKey.currency0 : _poolKey.currency1),
                Currency.unwrap(_nativeIsZero ? _poolKey.currency1 : _poolKey.currency0)
            );
        }
        // Otherwise, if we have a positive amount specified, then we know the number of tokens that
        // are being purchased and need to calculate the amount of ETH required.
        else {
            tokensOut = uint(_amountSpecified);
            ethIn = _getQuoteAtTick(
                info.initialTick,
                tokensOut,
                Currency.unwrap(!_nativeIsZero ? _poolKey.currency0 : _poolKey.currency1),
                Currency.unwrap(!_nativeIsZero ? _poolKey.currency1 : _poolKey.currency0)
            );
        }

        // If the user has requested more tokens than are available in the fair launch, then we
        // need to strip back the amount that we can fulfill.
        if (tokensOut > info.supply) {
            // Calculate the percentage of tokensOut relative to the threshold and reduce the `ethIn`
            // value by the same amount. There may be some slight accuracy loss, but it's all good.
            uint percentage = info.supply * 1e18 / tokensOut;
            ethIn = (ethIn * percentage) / 1e18;

            // Update our `tokensOut` to the supply limit
            tokensOut = info.supply;
        }

        // Get our BeforeSwapDelta response ready
        beforeSwapDelta_ = (_amountSpecified < 0)
            ? toBeforeSwapDelta(ethIn.toInt128(), -tokensOut.toInt128())
            : toBeforeSwapDelta(-tokensOut.toInt128(), ethIn.toInt128());

        // Define our BalanceDelta
        balanceDelta_ = toBalanceDelta(
            _nativeIsZero ? ethIn.toInt128() : -tokensOut.toInt128(),
            _nativeIsZero ? -tokensOut.toInt128() : ethIn.toInt128()
        );

        info.revenue += ethIn;
        info.supply -= tokensOut;

        return (beforeSwapDelta_, balanceDelta_, info);
    }

    /**
     * Allows calls from the {PositionManager} to modify the amount of revenue stored against a pool's
     * FairLaunch position. This is required to correctly attribute fees taken.
     *
     * @param _poolId The ID of the PoolKey
     * @param _revenue The revenue amount to add or subtract
     */
    function modifyRevenue(PoolId _poolId, int _revenue) public onlyPositionManager {
        if (_revenue < 0) {
            _fairLaunchInfo[_poolId].revenue -= uint(-_revenue);
        } else if (_revenue > 0) {
            _fairLaunchInfo[_poolId].revenue += uint(_revenue);
        }
    }

    /**
     * Creates an immutable, single-sided position when the FairLaunch window is closed.
     *
     * @param _poolKey The PoolKey to create a position against
     * @param _tickLower The lower tick of the position
     * @param _tickUpper The upper tick of the position
     * @param _tokens The number of tokens to put into the position
     * @param _tokenIsZero True if the position is created `currency0`; false is `currency1`
     */
    function _createImmutablePosition(
        PoolKey memory _poolKey,
        int24 _tickLower,
        int24 _tickUpper,
        uint _tokens,
        bool _tokenIsZero
    ) internal {
        // Calculate the liquidity delta based on the tick range and token amount
        uint128 liquidityDelta = _tokenIsZero ? LiquidityAmounts.getLiquidityForAmount0({
            sqrtPriceAX96: TickMath.getSqrtPriceAtTick(_tickLower),
            sqrtPriceBX96: TickMath.getSqrtPriceAtTick(_tickUpper),
            amount0: _tokens
        }) : LiquidityAmounts.getLiquidityForAmount1({
            sqrtPriceAX96: TickMath.getSqrtPriceAtTick(_tickLower),
            sqrtPriceBX96: TickMath.getSqrtPriceAtTick(_tickUpper),
            amount1: _tokens
        });

        // If we have no liquidity, then exit before creating the position which would revert
        if (liquidityDelta == 0) return;

        // Create our single-sided position
        (BalanceDelta delta,) = poolManager.modifyLiquidity({
            key: _poolKey,
            params: IPoolManager.ModifyLiquidityParams({
                tickLower: _tickLower,
                tickUpper: _tickUpper,
                liquidityDelta: liquidityDelta.toInt128(),
                salt: ''
            }),
            hookData: ''
        });

        // Settle the tokens that are required to fill the position
        if (delta.amount0() < 0) {
            _poolKey.currency0.settle(poolManager, msg.sender, uint(-int(delta.amount0())), false);
        }

        if (delta.amount1() < 0) {
            _poolKey.currency1.settle(poolManager, msg.sender, uint(-int(delta.amount1())), false);
        }
    }

    /**
     * Given a tick and a token amount, calculates the amount of token received in exchange.
     *
     * @dev Forked from the `Uniswap/v3-periphery` {OracleLibrary} contract.
     *
     * @param _tick Tick value used to calculate the quote
     * @param _baseAmount Amount of token to be converted
     * @param _baseToken Address of an ERC20 token contract used as the baseAmount denomination
     * @param _quoteToken Address of an ERC20 token contract used as the quoteAmount denomination
     *
     * @return quoteAmount_ Amount of quoteToken received for baseAmount of baseToken
     */
    function _getQuoteAtTick(
        int24 _tick,
        uint _baseAmount,
        address _baseToken,
        address _quoteToken
    ) internal pure returns (
        uint quoteAmount_
    ) {
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(_tick);

        // Calculate `quoteAmount` with better precision if it doesn't overflow when multiplied
        // by itself.
        if (sqrtPriceX96 <= type(uint128).max) {
            uint ratioX192 = uint(sqrtPriceX96) * sqrtPriceX96;
            quoteAmount_ = _baseToken < _quoteToken
                ? FullMath.mulDiv(ratioX192, _baseAmount, 1 << 192)
                : FullMath.mulDiv(1 << 192, _baseAmount, ratioX192);
        } else {
            uint ratioX128 = FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, 1 << 64);
            quoteAmount_ = _baseToken < _quoteToken
                ? FullMath.mulDiv(ratioX128, _baseAmount, 1 << 128)
                : FullMath.mulDiv(1 << 128, _baseAmount, ratioX128);
        }
    }

    /**
     * Ensures that only a {PositionManager} can call the function.
     */
    modifier onlyPositionManager {
        if (!hasRole(ProtocolRoles.POSITION_MANAGER, msg.sender)) revert NotPositionManager();
        _;
    }

}
