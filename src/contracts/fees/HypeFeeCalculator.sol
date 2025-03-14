// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from '@solady/auth/Ownable.sol';

import {BalanceDelta} from '@uniswap/v4-core/src/types/BalanceDelta.sol';
import {Currency} from '@uniswap/v4-core/src/types/Currency.sol';
import {FixedPointMathLib} from '@solady/utils/FixedPointMathLib.sol';
import {IPoolManager} from '@uniswap/v4-core/src/interfaces/IPoolManager.sol';
import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';
import {PoolId, PoolIdLibrary} from '@uniswap/v4-core/src/types/PoolId.sol';
import {TickMath} from '@uniswap/v4-core/src/libraries/TickMath.sol';
import {FullMath} from '@uniswap/v4-core/src/libraries/FullMath.sol';

import {FairLaunch} from '@flaunch/hooks/FairLaunch.sol';
import {ProtocolRoles} from '@flaunch/libraries/ProtocolRoles.sol';

import {IFeeCalculator} from '@flaunch-interfaces/IFeeCalculator.sol';


/**
 * Calculates hype fees during fair launch based on token sale rates.
 * The fee increases as the sale rate exceeds the target rate to discourage sniping.
 */
contract HypeFeeCalculator is IFeeCalculator, Ownable {

    using PoolIdLibrary for PoolKey;
    using FixedPointMathLib for uint;

    error CallerNotPositionManager();

    /**
     * Holds information regarding each pool used in price calculations.
     *
     * @member isHypeFeeEnabled Whether to use HypeFee
     * @member totalTokensSold Total tokens sold during fair launch
     * @member targetTokensPerSec Target tokens per second
     */
    struct PoolInfo {
        bool isHypeFeeEnabled;
        uint totalTokensSold;
        uint targetTokensPerSec;
    }

    /// Our fair launch window duration
    uint internal constant FAIR_LAUNCH_WINDOW = 30 minutes;

    /// The scaling factor for the fee
    uint24 internal constant SCALING_FACTOR = 1e4;

    /// The fee charged for swaps has to be always greater than MINIMUM_FEE represented in bps
    uint24 public constant MINIMUM_FEE_SCALED = 1_0000; // 1% in bps scaled by 1_00

    /// The fee charged for swaps has to be always less than MAXIMUM_FEE represented in bps
    uint24 public constant MAXIMUM_FEE_SCALED = 50_0000; // 50% in bps scaled by 1_00

    /// 100% in bps
    uint256 constant MAX_BPS = 100_00;

    /// The FairLaunch contract reference
    FairLaunch public immutable fairLaunch;

    /// Our native token
    address public immutable nativeToken;

    /// Maps pool IDs to their info
    mapping(PoolId => PoolInfo) public poolInfos;

    /// The maximum swap amount % per tx in bps
    uint256 public maxSwapPercentPerTx = 100_00; // 100%

    error SwapExceedsMaxSwapPercentPerTx();
    error InvalidMaxSwapPercentPerTx();

    /**
     * Registers our FairLaunch contract and native token.
     *
     * @param _fairLaunch The address of our {FairLaunch} contract
     * @param _nativeToken The native token used for Flaunch
     */
    constructor (FairLaunch _fairLaunch, address _nativeToken) {
        fairLaunch = _fairLaunch;
        nativeToken = _nativeToken;

        _initializeOwner(msg.sender);
    }

    /**
     * Takes parameters during a Flaunch call to customise the PoolInfo.
     *
     * @param _poolId The PoolId of the pool that has been flaunched
     * @param _params Any additional parameter information
     */
    function setFlaunchParams(PoolId _poolId, bytes calldata _params) external override {
        // Decode the required parameters
        uint _targetTokensPerSec;
        if (_params.length > 0) {
            _targetTokensPerSec = abi.decode(_params, (uint));
        }

        // Ensure that this call is coming from the {PositionManager} and validate the
        // value passed.
        if (!fairLaunch.hasRole(ProtocolRoles.POSITION_MANAGER, msg.sender)) {
            revert CallerNotPositionManager();
        }

        if (_targetTokensPerSec == 0) {
            poolInfos[_poolId].isHypeFeeEnabled = false;
        } else {
            poolInfos[_poolId].isHypeFeeEnabled = true;
            poolInfos[_poolId].targetTokensPerSec = _targetTokensPerSec;
        }
    }

    /**
     * Allows owner to set the maximum swap amount % per tx.
     *
     * @param _maxSwapPercentPerTx The maximum swap amount % per tx in bps
     */
    function setMaxSwapPercentPerTx(uint256 _maxSwapPercentPerTx) external onlyOwner {
        if (_maxSwapPercentPerTx > MAX_BPS) revert InvalidMaxSwapPercentPerTx();
        maxSwapPercentPerTx = _maxSwapPercentPerTx;
    }

    /**
     * Calculates the current swap fee based on token sale rate.
     *
     * @param _poolKey The PoolKey to calculate the swap fee for
     * @param _baseFee The base fee of the pool
     *
     * @return swapFee_ The swap fee to be applied
     */
    function determineSwapFee(
        PoolKey memory _poolKey,
        IPoolManager.SwapParams memory _params,
        uint24 _baseFee
    ) external view override returns (uint24 swapFee_) {
        PoolId poolId = _poolKey.toId();
        PoolInfo memory poolInfo = poolInfos[poolId];

        // Return base fee if hype fee is not enabled or (no swaps yet or fair launch ended)
        if (!poolInfo.isHypeFeeEnabled || !fairLaunch.inFairLaunchWindow(poolId)) {
            return _baseFee;
        }

        FairLaunch.FairLaunchInfo memory flInfo = fairLaunch.fairLaunchInfo(poolId);

        uint elapsedSeconds = block.timestamp - (flInfo.endsAt - FAIR_LAUNCH_WINDOW);

        // Prevent division by zero
        if (elapsedSeconds == 0) return _baseFee;

        // Calculate current sale rate
        uint tokensBoughtInThisSwap = _getTokensBoughtFromFairLaunch(_poolKey, flInfo, _params);
        uint currentSaleRatePerSec = (poolInfo.totalTokensSold + tokensBoughtInThisSwap) / elapsedSeconds;
        uint targetTokensPerSec = getTargetTokensPerSec(poolId);

        uint swapFeeScaled;

        // If sale rate <= target rate, return min fee
        if (currentSaleRatePerSec <= targetTokensPerSec) {
            swapFeeScaled = MINIMUM_FEE_SCALED;
        } else {
            // Calculate hype fee
            uint rateExcess = currentSaleRatePerSec - targetTokensPerSec;
            uint hypeFeeScaled = MINIMUM_FEE_SCALED +
                ((MAXIMUM_FEE_SCALED - MINIMUM_FEE_SCALED) * rateExcess) /
                targetTokensPerSec;

            // Cap at MAX_FEE
            swapFeeScaled = FixedPointMathLib.min(hypeFeeScaled, MAXIMUM_FEE_SCALED);
        }

        // Ensure that the swap fee is at least the base fee. scale down the result to bps
        swapFee_ = uint24(
            FixedPointMathLib.max(swapFeeScaled, _baseFee * 1_00) / 1_00
        );
    }

    /**
     * After a swap is made, we track the total tokens sold in fair launch window
     *
     * @param _key The key for the pool
     * @param _delta The amount owed to the caller (positive) or owed to the pool (negative)
     */
    function trackSwap(
        address /* _sender */,
        PoolKey calldata _key,
        IPoolManager.SwapParams calldata /* _params */,
        BalanceDelta _delta,
        bytes calldata /* _hookData */
    ) external override {
        // Ensure that this call is coming from the {PositionManager}
        if (!fairLaunch.hasRole(ProtocolRoles.POSITION_MANAGER, msg.sender)) {
            revert CallerNotPositionManager();
        }

        // Load our PoolInfo, opened as storage to update values
        PoolId poolId = _key.toId();
        PoolInfo storage poolInfo = poolInfos[poolId];

        // Skip if hype fee is not enabled or (pool not initialized / fair launch ended)
        if (!poolInfo.isHypeFeeEnabled || !fairLaunch.inFairLaunchWindow(poolId)) {
            return;
        }

        // Absolute amount of non-native token swapped
        int tokenDelta = int(
            Currency.unwrap(_key.currency0) == nativeToken
                ? _delta.amount1()
                : _delta.amount0()
        );
        uint tokensSold = uint(tokenDelta < 0 ? -tokenDelta : tokenDelta);

        uint maxSwapAmount = (fairLaunch.fairLaunchInfo(poolId).supply * maxSwapPercentPerTx) / MAX_BPS;

        if (tokensSold > maxSwapAmount) revert SwapExceedsMaxSwapPercentPerTx();

        // Update the total tokens sold
        poolInfo.totalTokensSold += tokensSold;
    }

    /**
     * Gets the target tokens per second for the pool.
     *
     * If no target tokens per second is set, determine via the fair launch supply can happen
     * when the fee calculator is set after the fair launch has already started.
     *
     * @param _poolId The PoolId of the pool to query
     *
     * @return The target tokens per second
     */
    function getTargetTokensPerSec(PoolId _poolId) public view returns (uint) {
        uint storedTargetTokensPerSec = poolInfos[_poolId].targetTokensPerSec;

        //
        if (storedTargetTokensPerSec == 0) {
            return fairLaunch.fairLaunchInfo(_poolId).supply / FAIR_LAUNCH_WINDOW;
        }

        return storedTargetTokensPerSec;
    }

    /**
     * Gets the tokens bought from the fair launch in this swap.
     */
    function _getTokensBoughtFromFairLaunch(
        PoolKey memory _poolKey,
        FairLaunch.FairLaunchInfo memory flInfo,
        IPoolManager.SwapParams memory _params
    ) internal view returns (uint tokensOut) {
        bool nativeIsZero = nativeToken == Currency.unwrap(_poolKey.currency0);

        // If we have a negative amount specified, then we have an ETH amount passed in and want
        // to buy as many tokens as we can for that price.
        if (_params.amountSpecified < 0) {
            uint ethIn = uint(-_params.amountSpecified);
            tokensOut = _getQuoteAtTick(
                flInfo.initialTick,
                ethIn,
                Currency.unwrap(nativeIsZero ? _poolKey.currency0 : _poolKey.currency1),
                Currency.unwrap(nativeIsZero ? _poolKey.currency1 : _poolKey.currency0)
            );
        }
        // Otherwise, if we have a positive amount specified, then we know the number of tokens that
        // are being purchased and need to calculate the amount of ETH required.
        else {
            tokensOut = uint(_params.amountSpecified);
        }

        // If the user has requested more tokens than are available in the fair launch, then we
        // need to strip back the amount that we can fulfill.
        if (tokensOut > flInfo.supply) {
            // Update our `tokensOut` to the supply limit
            tokensOut = flInfo.supply;
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
}
