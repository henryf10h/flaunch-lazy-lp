// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SafeTransferLib} from '@solady/utils/SafeTransferLib.sol';

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import {BalanceDelta} from '@uniswap/v4-core/src/types/BalanceDelta.sol';
import {Currency} from '@uniswap/v4-core/src/types/Currency.sol';
import {IHooks} from '@uniswap/v4-core/src/libraries/Hooks.sol';
import {IPoolManager} from '@uniswap/v4-core/src/interfaces/IPoolManager.sol';
import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';
import {SafeCast} from '@uniswap/v4-core/src/libraries/SafeCast.sol';
import {TickMath} from '@uniswap/v4-core/src/libraries/TickMath.sol';

import {Flaunch} from '@flaunch/Flaunch.sol';
import {PoolSwap} from '@flaunch/zaps/PoolSwap.sol';
import {PositionManager} from '@flaunch/PositionManager.sol';
import {TokenSupply} from '@flaunch/libraries/TokenSupply.sol';

import {IFeeCalculator} from '@flaunch-interfaces/IFeeCalculator.sol';
import {IFLETH} from '@flaunch-interfaces/IFLETH.sol';
import {ITreasuryManagerFactory} from '@flaunch-interfaces/ITreasuryManagerFactory.sol';
import {ITreasuryManager} from '@flaunch-interfaces/ITreasuryManager.sol';


/**
 * This zap allows the creator to flaunch their coin, whilst also purchasing some of their
 * initial fair launch supply during the same transaction. The manager receives the flaunch creator NFT.
 */
contract CreateWithManagerZap {

    using SafeCast for uint;

    /// The Flaunch {PositionManager} contract
    PositionManager public immutable positionManager;
    Flaunch public immutable flaunchContract;

    /// The underlying flETH token paired against the created token
    IFLETH public immutable flETH;

    /// The swap contract being used to perform the token buy
    PoolSwap public immutable poolSwap;

    /// The treasury manager factory that deploys a new instance of the manager
    ITreasuryManagerFactory public immutable treasuryManagerFactory;

    /**
     * Assigns the immutable contracts used by the zap.
     *
     * @param _positionManager Flaunch {PositionManager}
     * @param _flaunchContract Flaunch contract
     * @param _flETH Underlying flETH token
     * @param _poolSwap Swap contract
     * @param _treasuryManagerFactory The treasury manager factory
     */
    constructor (
        PositionManager _positionManager,
        address _flaunchContract,
        address _flETH,
        PoolSwap _poolSwap,
        address _treasuryManagerFactory
    ) {
        positionManager = _positionManager;
        flaunchContract = Flaunch(_flaunchContract);
        flETH = IFLETH(_flETH);
        poolSwap = _poolSwap;
        treasuryManagerFactory = ITreasuryManagerFactory(_treasuryManagerFactory);
    }

    /**
     * Flaunches a new token and premines some tokens for the creator in exchange for ETH. The manager receives the flaunch creator NFT.
     * 
     * @dev If the manager is an approved implementation, then it's instance will be deployed. Otherwise the flaunch token will be transferred directly to the manager.
     *
     * @param _params The parameters for the flaunch
     * @param _manager The manager implementation to use
     * @param _managerInitData The data to initialize the manager with
     *
     * @return memecoin_ The created ERC20 token address
     * @return ethSpent_ The amount of ETH spent during the premine
     * @return deployedManager_ The address of the manager that was deployed
     */
    function flaunch(
        PositionManager.FlaunchParams calldata _params,
        address _manager,
        bytes calldata _managerInitData
    ) external payable returns (address memecoin_, uint ethSpent_, address deployedManager_) {
        // Flaunch new token
        memecoin_ = positionManager.flaunch{value: msg.value}(PositionManager.FlaunchParams({
            creator: address(this), // ensure that the creator is this zap contract, for this call.
            // the rest of the params remain the same
            name: _params.name,
            symbol: _params.symbol,
            tokenUri: _params.tokenUri,
            initialTokenFairLaunch: _params.initialTokenFairLaunch,
            premineAmount: _params.premineAmount,
            creatorFeeAllocation: _params.creatorFeeAllocation,
            flaunchAt: _params.flaunchAt,
            initialPriceParams: _params.initialPriceParams,
            feeCalculatorParams: _params.feeCalculatorParams
        }));

        // Get the token ID of the flaunch token
        uint tokenId = flaunchContract.tokenId(memecoin_);

        // Send the flaunch token to the manager
        if (treasuryManagerFactory.approvedManagerImplementation(_manager)) {
            // if it is a valid manager implementation, deploy a new instance
            deployedManager_ = treasuryManagerFactory.deployManager(_manager);

            // approve the manager to pull the flaunch token during initialization
            flaunchContract.approve(deployedManager_, tokenId);

            // initialize the manager
            ITreasuryManager(deployedManager_).initialize({
                _tokenId: tokenId,
                _owner: _params.creator,
                _data: _managerInitData
            });
        } else {
            // if it's not a valid manager implementation, transfer the flaunch token directly to the manager
            deployedManager_ = _manager;
            flaunchContract.transferFrom(address(this), deployedManager_, tokenId);
        }

        // Capture the PoolKey that was created during the 'flaunch'
        PoolKey memory poolKey = positionManager.poolKey(memecoin_);

        // Buy tokens from the fair launch pool
        if (_params.premineAmount != 0) {
            ethSpent_ = _buyTokens(poolKey, _params.premineAmount, payable(address(this)).balance, memecoin_);
        }

        // Refund the remaining ETH
        uint remainingBalance = payable(address(this)).balance;
        if (remainingBalance > 0) {
            SafeTransferLib.safeTransferETH(msg.sender, remainingBalance);
        }
    }

    /**
     * Swaps ETH into memecoin from the fair launch pool.
     *
     * @param _poolKey The `PoolKey` that was flaunched
     * @param _premineAmount The amount of tokens the user wants to purchase from initial supply
     * @param _ethAmount The amount of ETH that the user wants to spend
     * @param _memecoin The memecoin that was flaunched
     */
    function _buyTokens(
        PoolKey memory _poolKey,
        uint _premineAmount,
        uint _ethAmount,
        address _memecoin
    ) internal returns (uint flETHSwapped_) {
        // Wrapping ETH into flETH
        flETH.deposit{value: _ethAmount}(0);

        // Swap flETH directly for {Memecoin}
        flETHSwapped_ = _buyViaPoolSwap(_poolKey, _premineAmount, _ethAmount);

        // Transfer premined tokens to creator
        IERC20(_memecoin).transfer(msg.sender, _premineAmount);

        // If there is ETH remaining after the user has made their swap, then we want
        // to unwrap it back into ETH so that the calling function can return it.
        uint remainingETH = _ethAmount - flETHSwapped_;
        if (remainingETH > 0) {
            flETH.withdraw(remainingETH);
        }
    }

    /**
     * Triggers the token purchase against our swap pool.
     *
     * @param _poolKey The PoolKey we are buying the memecoin from
     * @param _premineAmount The amount of tokens the user wants to purchase from initial supply
     * @param _flETHAmount The amount of flETH that the user wants to spend
     */
    function _buyViaPoolSwap(
        PoolKey memory _poolKey,
        uint _premineAmount,
        uint _flETHAmount
    ) internal returns (uint flETHSwapped_) {
        // Check if we have a flipped pool
        bool flipped = Currency.unwrap(_poolKey.currency0) != address(flETH);

        // Give {PoolSwap} unlimited flETH allowance if we don't already have a
        // sufficient allowance.
        if (flETH.allowance(address(this), address(poolSwap)) < _flETHAmount) {
            flETH.approve(address(poolSwap), type(uint).max);
        }

        // Action our swap on the {PoolSwap} contract with max range
        BalanceDelta delta = poolSwap.swap({
            _key: _poolKey,
            _params: IPoolManager.SwapParams({
                zeroForOne: !flipped,
                amountSpecified: _premineAmount.toInt256(),
                sqrtPriceLimitX96: !flipped
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1
            })
        });

        // Calculate the amount of flETH swapped from the delta
        flETHSwapped_ = uint128(!flipped ? -delta.amount0() : -delta.amount1());
    }

    /**
     * Calculates the fee that will be required to use the zap with the specified premine. This allows
     * for a slippage amount to be set, just incase we want to provide some buffer on the call.
     *
     * @param _premineAmount The number of tokens to be premined
     * @param _slippage The slippage percentage with 2dp
     *
     * @return ethRequired_ The amount of ETH that will be required
     */
    function calculateFee(uint _premineAmount, uint _slippage, bytes calldata _initialPriceParams) public view returns (uint ethRequired_) {
        // Market cap / total supply * premineAmount + swapFee
        uint premineCost = positionManager.getFlaunchingMarketCap(_initialPriceParams) * _premineAmount / TokenSupply.INITIAL_SUPPLY;

        // Create a fake pool key, just to generate an non-existant ID to check against
        PoolKey memory fakePoolKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(0)),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });

        // Calculate swap fee
        IFeeCalculator feeCalculator = positionManager.getFeeCalculator(true);
        uint24 baseSwapFee = positionManager.getPoolFeeDistribution(fakePoolKey.toId()).swapFee;
        if (address(feeCalculator) != address(0)) {
            baseSwapFee = feeCalculator.determineSwapFee({
                _poolKey: fakePoolKey,
                _params: IPoolManager.SwapParams({
                    zeroForOne: false,
                    amountSpecified: _premineAmount.toInt256(),
                    sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE
                }),
                _baseFee: baseSwapFee
            });
        }

        // Set our base requirement of fee and premine market cost
        ethRequired_ = positionManager.getFlaunchingFee(_initialPriceParams) + premineCost;

        // Add our fee if present
        if (baseSwapFee != 0) {
            ethRequired_ += premineCost * baseSwapFee / 100_00;
        }

        // Add slippage
        if (_slippage != 0) {
            ethRequired_ += ethRequired_ * _slippage / 100_00;
        }
    }

    /**
     * To receive ETH from flETH on withdraw.
     */
    receive() external payable {}

}
