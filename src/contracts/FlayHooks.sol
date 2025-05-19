// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from '@solady/auth/Ownable.sol';

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import {BalanceDelta} from '@uniswap/v4-core/src/types/BalanceDelta.sol';
import {BaseHook} from '@uniswap-periphery/base/hooks/BaseHook.sol';
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from '@uniswap/v4-core/src/types/BeforeSwapDelta.sol';
import {Currency} from '@uniswap/v4-core/src/types/Currency.sol';
import {IPoolManager} from '@uniswap/v4-core/src/interfaces/IPoolManager.sol';
import {Hooks, IHooks} from '@uniswap/v4-core/src/libraries/Hooks.sol';
import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';
import {PoolId, PoolIdLibrary} from '@uniswap/v4-core/src/types/PoolId.sol';
import {SafeCast} from '@uniswap/v4-core/src/libraries/SafeCast.sol';
import {StateLibrary} from '@uniswap/v4-core/src/libraries/StateLibrary.sol';

import {BidWall} from '@flaunch/bidwall/BidWall.sol';

import {InternalSwapPool} from '@flaunch/hooks/InternalSwapPool.sol';

/**
 * This is a Uniswap V4 hook contract that enables Internal Swap Pool and BidWall for
 * FLETH/FLAY pool.
 */
contract FlayHooks is BaseHook, InternalSwapPool, Ownable {
    
    using PoolIdLibrary for PoolKey;
    using BeforeSwapDeltaLibrary for BeforeSwapDelta;
    using SafeCast for uint;
    using StateLibrary for IPoolManager;

    error CannotBeInitializedDirectly();

    /// Base Mainnet Token addresses (nativeToken ($FLETH) is currency0)
    address public constant nativeToken = 0x000000000D564D5be76f7f0d28fE52605afC7Cf8;
    address public constant flayToken = 0xF1A7000000950C7ad8Aff13118Bb7aB561A448ee;

    /// Base Mainnet Uniswap V4 {PoolManager} contract
    address public constant _poolManager = 0x498581fF718922c3f8e6A244956aF099B2652b2b;

    /// Constant to define 100% to 2dp
    uint internal constant ONE_HUNDRED_PERCENT = 100_00;

    /// The base swap fee for the pool
    uint24 public constant BASE_SWAP_FEE = 1_00; // 1%

    /// The minimum amount before a distribution is triggered
    uint public constant MIN_DISTRIBUTE_THRESHOLD = 0.001 ether;
    
    /// Store the contract that will manage our Bidwall interactions
    BidWall public immutable bidWall;

    /// Store an optional flayBurner address
    address payable public flayBurner;

    /// The pool key for the flayNative pool
    PoolKey public flayNativePoolKey;

    /// Internal storage to allow the `beforeSwap` tick value to be used in `afterSwap`
    int24 internal _beforeSwapTick;

    /**
     * Defines our {PoolManager} and the tokens that will define the referenced {PoolKey}.
     *
     * @param _initialSqrtPriceX96 The initial sqrt price for the pool
     * @param _protocolOwner The address to set as the {Ownable} owner for the {BidWall}
     */
    constructor(uint160 _initialSqrtPriceX96, address _protocolOwner) BaseHook(IPoolManager(_poolManager)) {
        // Initialize the Ownable contract
        _initializeOwner(_protocolOwner);

        // Deploy our BidWall contract and transfer ownership to the protocol owner
        bidWall = new BidWall(nativeToken, _poolManager, _protocolOwner);

        // Approve the BidWall to manage native token from the FlayHooks
        IERC20(nativeToken).approve(address(bidWall), type(uint).max);

        // Initialize our flayNative pool key
        flayNativePoolKey = PoolKey({
            currency0: Currency.wrap(nativeToken),
            currency1: Currency.wrap(flayToken),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(address(this))
        });

        // Initializes the pool with the given initial sqrt price.
        poolManager.initialize(flayNativePoolKey, _initialSqrtPriceX96);
    }

    /**
     * Defines the Uniswap V4 hooks that are used by our implementation. This will determine
     * the address that our contract **must** be deployed to for Uniswap V4. This address suffix
     * is shown in the dev comments for this function call.
     *
     * @dev 1000 0011 0011 00 == 20CC
     */
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return
            Hooks.Permissions({
                beforeInitialize: true, // Prevent initialize
                afterInitialize: false,
                beforeAddLiquidity: false,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: true, // [InternalSwapPool]
                afterSwap: true, // [InternalSwapPool], [BidWall]
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: true, // [InternalSwapPool]
                afterSwapReturnDelta: true, // [FeeDistributor]
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }

    /**
     * Prevent external contracts from initializing pools using our contract as a hook.
     *
     * @dev As we call `poolManager.initialize` from the IHooks contract itself, we bypass this
     * hook call as therefore bypass the prevention.
     */
    function beforeInitialize(address, PoolKey calldata, uint160) external view override onlyPoolManager returns (bytes4) {
        revert CannotBeInitializedDirectly();
    }

    /**
     * We want to see if we have any token1 fee tokens that we can use to fill the swap before
     * it hits the Uniswap pool. This prevents the pool from being affected and reduced gas
     * costs. This also allows us to benefit from the Uniswap routing infrastructure.
     *
     * This frontruns Uniswap to sell undesired token amounts from our fees into desired tokens
     * ahead of our fee distribution. This acts as a partial orderbook to remove impact against
     * our pool.
     *
     * @param _key The key for the pool
     * @param _params The parameters for the swap
     *
     * @return selector_ The function selector for the hook
     * @return beforeSwapDelta_ The hook's delta in specified and unspecified currencies. Positive: the hook is owed/took currency, negative: the hook owes/sent currency
     * @return swapFee_ The percentage fee applied to our swap
     */
    function beforeSwap(
        address /* _sender */,
        PoolKey calldata _key,
        IPoolManager.SwapParams memory _params,
        bytes calldata /* _hookData */
    ) public override onlyPoolManager returns (
        bytes4 selector_,
        BeforeSwapDelta beforeSwapDelta_,
        uint24
    ) {
        // Check the {InternalSwapPool} for any tokens that can be swapped before hitting Uniswap
        (uint tokenIn, uint tokenOut) = _internalSwap(poolManager, _key, _params, true);
        if (tokenIn + tokenOut != 0) {
            // Update our hook delta to reduce the upcoming swap amount to show that we have
            // already spent some of the FLETH and received some of the underlying ERC20.
            BeforeSwapDelta internalBeforeSwapDelta = _params.amountSpecified >= 0
                ? toBeforeSwapDelta(-tokenOut.toInt128(), tokenIn.toInt128())
                : toBeforeSwapDelta(tokenIn.toInt128(), -tokenOut.toInt128());

            // We need to determine the amount of fees generated by our internal swap to capture, rather
            // than sending the full amount to the end user.
            uint _swapFee = _captureAndDepositFees(_key, _params, internalBeforeSwapDelta.getUnspecifiedDelta());

            // Increase the delta being sent back
            beforeSwapDelta_ = toBeforeSwapDelta(
                beforeSwapDelta_.getSpecifiedDelta() + internalBeforeSwapDelta.getSpecifiedDelta(),
                beforeSwapDelta_.getUnspecifiedDelta() + internalBeforeSwapDelta.getUnspecifiedDelta() + _swapFee.toInt128()
            );
        }

        // Capture the beforeSwap tick value before actioning our Uniswap swap
        (, _beforeSwapTick,,) = poolManager.getSlot0(_key.toId());

        // Set our return selector
        selector_ = IHooks.beforeSwap.selector;
    }

    /**
     * Captures fees from the swap to either distribute or send to ISP. If any of the swap was
     * filled by the ISP, then we can distribute these fees too.
     *
     * @param _key The key for the pool
     * @param _params The parameters for the swap
     * @param _delta The amount owed to the caller (positive) or owed to the pool (negative)
     *
     * @return selector_ The function selector for the hook
     * @return hookDeltaUnspecified_ The hook's delta in unspecified currency. Positive: the hook is owed/took currency, negative: the hook owes/sent currency
     */
    function afterSwap(
        address,
        PoolKey calldata _key,
        IPoolManager.SwapParams calldata _params,
        BalanceDelta _delta,
        bytes calldata
    ) public override onlyPoolManager returns (
        bytes4 selector_,
        int128 hookDeltaUnspecified_
    ) {
        // We need to determine the amount of fees generated by our Uniswap swap to capture, rather
        // than sending the full amount to the end user.
        int128 swapAmount = _params.amountSpecified < 0 == _params.zeroForOne ? _delta.amount1() : _delta.amount0();
        uint _swapFee = _captureAndDepositFees(_key, _params, swapAmount);

        // Distribute any fees that have been converted by the swap.
        _distributeFees(_key);

        // Set our return selector
        hookDeltaUnspecified_ = _swapFee.toInt128();
        selector_ = IHooks.afterSwap.selector;
    }

    /**
     * Capture the fees from our swap. This could either be from an internal swap (`beforeSwap`)
     * or from the actual Uniswap swap (`afterSwap`).
     *
     * @param _key The {PoolKey} that the swap was made against
     * @param _params The swap parameters called in the swap
     * @param _delta The balance change from the swap
     *
     * @return swapFee_ The fee taken from the swap
     */
    function _captureAndDepositFees(
        PoolKey calldata _key,
        IPoolManager.SwapParams memory _params,
        int128 _delta
    ) internal returns (uint swapFee_) {
        // Determine the swap fee currency based on swap parameters
        Currency swapFeeCurrency = _params.amountSpecified < 0 == _params.zeroForOne ? _key.currency1 : _key.currency0;

        // Determine our swap amount
        uint128 _swapAmount = uint128(_delta < 0 ? -_delta : _delta);

        // If we have no swap amount, then we have nothing to process
        if (_swapAmount == 0) {
            return 0;
        }

        // Determine our fee amount
        swapFee_ = _swapAmount * BASE_SWAP_FEE / ONE_HUNDRED_PERCENT;

        // Take our swap fees from the {PoolManager}
        poolManager.take(swapFeeCurrency, address(this), swapFee_);

        // Deposit the remaining fees against our pool to be either distributed to others,
        // or placed into the Internal Swap Pool to be converted into an ETH equivalent token.
        _depositFees(
            _key,
            Currency.unwrap(swapFeeCurrency) == nativeToken ? swapFee_ : 0,
            Currency.unwrap(swapFeeCurrency) == nativeToken ? 0 : swapFee_
        );
    }

    /**
     * We want to be able to distribute fees across recipients when we reach a set threshold.
     * This will only ever distribute the ETH equivalent token, as the non-ETH token will be
     * converted via the {InternalSwapPool} hook logic.
     *
     * @param _poolKey The PoolKey reference that will have fees distributed
     */
    function _distributeFees(PoolKey memory _poolKey) internal {
        PoolId poolId = _poolKey.toId();

        // Get the amount of the native token available to distribute
        uint bidWallFee = _poolFees[poolId].amount0;

        // Ensure that the collection has sufficient fees available
        if (bidWallFee < MIN_DISTRIBUTE_THRESHOLD) {
            return;
        }

        // Reduce our available fees for the pool
        _poolFees[poolId].amount0 = 0;

        // Check if we have a flayBurner address. If we do then send the ETH there to
        // process into a buy and burn.
        if (flayBurner != address(0)) {
            // Transfer the flETH fees to the flayBurner
            IERC20(nativeToken).transfer(flayBurner, bidWallFee);
        }
        // Otherwise, we send the fees to the BidWall
        else {
            // All fees are directly deposited into the BidWall
            bidWall.deposit(_poolKey, bidWallFee, _beforeSwapTick, true);

            emit PoolFeesDistributed(poolId, bidWallFee, 0, bidWallFee, 0, 0);
        }
    }

    /**
     * Allows the owner to update the {FlayBurner} contract address.
     *
     * @dev This can be set to a zero-address to bypass the FlayBurner and instead send
     * fees to the BidWall.
     *
     * @param _flayBurner The new {FlayBurner} contract address
     */
    function setFlayBurner(address _flayBurner) external onlyOwner {
        flayBurner = payable(_flayBurner);
    }
}
