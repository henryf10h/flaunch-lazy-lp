// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {Currency} from '@uniswap/v4-core/src/types/Currency.sol';
import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';
import {PoolId, PoolIdLibrary} from '@uniswap/v4-core/src/types/PoolId.sol';
import {IPoolManager} from '@uniswap/v4-core/src/interfaces/IPoolManager.sol';
import {BalanceDelta} from '@uniswap/v4-core/src/types/BalanceDelta.sol';
import {TickMath} from '@uniswap/v4-core/src/libraries/TickMath.sol';
import {StateLibrary} from '@uniswap/v4-core/src/libraries/StateLibrary.sol';
import {IAnyFlaunch} from '@flaunch-interfaces/IAnyFlaunch.sol';

/**
 * @title FlaunchLPManager
 * @notice Manages LP provision and Synthetix-style reward distribution for Flaunch
 * @dev Receives fees from AnyPositionManager and provides liquidity to Uniswap V4 pools
 */
contract FlaunchLPManager {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    error UnauthorizedAccess();
    error InvalidPool();
    error InsufficientBalance();
    error ZeroAmount();
    error PoolNotConfigured();

    event FeesReceived(address indexed memecoin, uint256 amount);
    event LiquidityProvided(PoolId indexed poolId, int256 liquidityDelta, uint256 amount);
    event RewardsWithdrawn(address indexed creator, uint256 amount);
    event PoolConfigured(PoolId indexed poolId);
    event RewardAdded(uint256 reward);

    /**
     * @notice Synthetix-style staking info per creator
     * @member stake Current stake amount (total contributed)
     * @member rewardPerTokenPaid Snapshot of rewardPerToken when last updated
     * @member rewards Accumulated rewards for this creator
     */
    struct CreatorStake {
        uint256 stake;
        uint256 rewardPerTokenPaid;
        uint256 rewards;
    }

    /**
     * @notice Configuration for LP positions in Uniswap V4
     * @member initialized Whether this pool is configured
     * @member tickLower Lower tick for concentrated liquidity
     * @member tickUpper Upper tick for concentrated liquidity
     * @member currentLiquidity Current liquidity in position
     */
    struct LPPosition {
        bool initialized;
        int24 tickLower;
        int24 tickUpper;
        uint128 currentLiquidity;
    }

    /// @notice AnyPositionManager contract reference
    address public immutable positionManager;

    /// @notice AnyFlaunch contract reference
    IAnyFlaunch public immutable flaunchContract;

    /// @notice Uniswap V4 PoolManager
    IPoolManager public immutable poolManager;

    /// @notice Native token (ETH/WETH) address
    address public immutable nativeToken;

    /// @notice Maps memecoin to its original creator
    mapping(address => address) public memecoinToCreator;

    /// @notice Synthetix-style staking data per creator
    mapping(address => CreatorStake) public creatorStakes;

    /// @notice LP positions per pool
    mapping(PoolId => LPPosition) public positions;

    /// @notice Configured pool keys for liquidity provision
    PoolKey[] public configuredPools;

    // Synthetix-style global state
    uint256 public rewardPerTokenStored;
    uint256 public lastUpdateTime;
    uint256 public totalStaked;
    uint256 public pendingRewards;

    /// @notice Minimum amount before providing liquidity
    uint256 public constant MIN_LIQUIDITY_AMOUNT = 0.01 ether;

    /**
     * @notice Constructor
     * @param _positionManager AnyPositionManager contract
     * @param _flaunchContract AnyFlaunch contract
     * @param _poolManager Uniswap V4 PoolManager
     * @param _nativeToken Native token address (ETH/WETH)
     */
    constructor(
        address _positionManager,
        address _flaunchContract,
        address _poolManager,
        address _nativeToken
    ) {
        positionManager = _positionManager;
        flaunchContract = IAnyFlaunch(_flaunchContract);
        poolManager = IPoolManager(_poolManager);
        nativeToken = _nativeToken;
    }

    /**
     * @notice Updates the global reward per token value (Synthetix pattern)
     */
    modifier updateReward(address account) {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = block.timestamp;
        
        if (account != address(0)) {
            CreatorStake storage stake = creatorStakes[account];
            stake.rewards = earned(account);
            stake.rewardPerTokenPaid = rewardPerTokenStored;
        }
        _;
    }

    /**
     * @notice Receives fees from AnyPositionManager (called with lpFee amount)
     * @param _memecoin The memecoin that generated the fees
     * @dev This function receives native ETH
     */
    function receiveFees(address _memecoin) external payable updateReward(address(0)) {
        if (msg.sender != positionManager) revert UnauthorizedAccess();
        if (msg.value == 0) revert ZeroAmount();

        // Get the creator for this memecoin
        address creator = flaunchContract.creator(_memecoin);
        
        // Initialize creator mapping if first time
        if (memecoinToCreator[_memecoin] == address(0)) {
            memecoinToCreator[_memecoin] = creator;
        }

        // Update creator's stake (Synthetix style)
        _updateCreatorStake(creator, msg.value);

        emit FeesReceived(_memecoin, msg.value);

        // Try to provide liquidity if we have enough
        _tryProvideLiquidity();
    }

    /**
     * @notice Receives WETH fees from AnyPositionManager
     * @param _memecoin The memecoin that generated the fees
     * @param _amount Amount of WETH received
     * @dev This function is called when nativeToken is WETH
     */
    function receiveFeesToken(address _memecoin, uint256 _amount) external updateReward(address(0)) {
        if (msg.sender != positionManager) revert UnauthorizedAccess();
        if (_amount == 0) revert ZeroAmount();

        // Transfer WETH from position manager
        IERC20(nativeToken).transferFrom(positionManager, address(this), _amount);

        // Get the creator for this memecoin
        address creator = flaunchContract.creator(_memecoin);
        
        // Initialize creator mapping if first time
        if (memecoinToCreator[_memecoin] == address(0)) {
            memecoinToCreator[_memecoin] = creator;
        }

        // Update creator's stake (Synthetix style)
        _updateCreatorStake(creator, _amount);

        emit FeesReceived(_memecoin, _amount);

        // Try to provide liquidity if we have enough
        _tryProvideLiquidity();
    }

    /**
     * @notice Updates a creator's stake with new contribution
     * @param _creator Creator address
     * @param _amount Amount to add to stake
     */
    function _updateCreatorStake(address _creator, uint256 _amount) internal updateReward(_creator) {
        CreatorStake storage stake = creatorStakes[_creator];
        
        totalStaked += _amount;
        stake.stake += _amount;
    }

    /**
     * @notice Calculates current reward per token (Synthetix formula)
     */
    function rewardPerToken() public view returns (uint256) {
        if (totalStaked == 0) {
            return rewardPerTokenStored;
        }
        
        // Add any pending rewards to the calculation
        return rewardPerTokenStored + (pendingRewards * 1e18 / totalStaked);
    }

    /**
     * @notice Calculates earned rewards for a creator (Synthetix formula)
     * @param _creator Creator address
     */
    function earned(address _creator) public view returns (uint256) {
        CreatorStake storage stake = creatorStakes[_creator];
        
        return (stake.stake * (rewardPerToken() - stake.rewardPerTokenPaid)) / 1e18 + stake.rewards;
    }

    /**
     * @notice Attempts to provide liquidity to configured pools
     */
    function _tryProvideLiquidity() internal {
        uint256 availableBalance;
        
        // Check balance based on whether we're using ETH or WETH
        if (nativeToken == address(0) || nativeToken == 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE) {
            availableBalance = address(this).balance - pendingRewards;
        } else {
            availableBalance = IERC20(nativeToken).balanceOf(address(this)) - pendingRewards;
        }
        
        if (availableBalance < MIN_LIQUIDITY_AMOUNT || configuredPools.length == 0) {
            return;
        }

        // Distribute equally among configured pools
        uint256 amountPerPool = availableBalance / configuredPools.length;
        
        for (uint256 i = 0; i < configuredPools.length; i++) {
            _provideLiquidityToPool(configuredPools[i], amountPerPool);
        }
    }

    /**
     * @notice Provides liquidity to a specific Uniswap V4 pool
     * @param _poolKey Pool key for the target pool
     * @param _amount Amount of native token to provide
     */
    function _provideLiquidityToPool(PoolKey memory _poolKey, uint256 _amount) internal {
        PoolId poolId = _poolKey.toId();
        LPPosition storage position = positions[poolId];
        
        if (!position.initialized) revert PoolNotConfigured();

        // Determine if native token is token0 or token1
        bool isToken0 = Currency.unwrap(_poolKey.currency0) == nativeToken;
        
        // Calculate liquidity delta for single-sided provision
        uint160 sqrtPriceX96 = poolManager.getSqrtPriceX96(poolId);
        
        // For single-sided liquidity, we need to calculate the liquidity amount
        // This is a simplified calculation - in production, use proper math
        uint128 liquidityDelta = _calculateLiquidityDelta(
            sqrtPriceX96,
            position.tickLower,
            position.tickUpper,
            _amount,
            isToken0
        );

        // Prepare modify liquidity params
        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: position.tickLower,
            tickUpper: position.tickUpper,
            liquidityDelta: int256(uint256(liquidityDelta)),
            salt: bytes32(0)
        });

        // Unlock pool manager and provide liquidity
        bytes memory result = poolManager.unlock(
            abi.encodeWithSelector(this._modifyLiquidityCallback.selector, _poolKey, params, _amount, isToken0)
        );
        
        // Decode result to get actual liquidity added
        int256 actualLiquidityDelta = abi.decode(result, (int256));
        
        position.currentLiquidity += uint128(uint256(actualLiquidityDelta));
        
        emit LiquidityProvided(poolId, actualLiquidityDelta, _amount);
    }

    /**
     * @notice Callback for modifying liquidity in Uniswap V4
     */
    function _modifyLiquidityCallback(
        PoolKey memory _poolKey,
        IPoolManager.ModifyLiquidityParams memory _params,
        uint256 _amount,
        bool _isToken0
    ) external returns (int256) {
        if (msg.sender != address(poolManager)) revert UnauthorizedAccess();

        // Modify liquidity
        (BalanceDelta delta, BalanceDelta feeDelta) = poolManager.modifyLiquidity(_poolKey, _params, "");
        
        // Settle the balance delta
        if (_isToken0) {
            _settleBalance(_poolKey.currency0, delta.amount0(), _amount);
            _settleBalance(_poolKey.currency1, delta.amount1(), 0);
        } else {
            _settleBalance(_poolKey.currency0, delta.amount0(), 0);
            _settleBalance(_poolKey.currency1, delta.amount1(), _amount);
        }
        
        // Handle any fees collected
        if (feeDelta.amount0() > 0 || feeDelta.amount1() > 0) {
            _collectAndAddRewards(_poolKey, feeDelta);
        }
        
        return _params.liquidityDelta;
    }

    /**
     * @notice Settles balance with pool manager
     */
    function _settleBalance(Currency currency, int128 deltaAmount, uint256 maxAmount) internal {
        if (deltaAmount < 0) {
            // We owe tokens to the pool
            uint256 amountOwed = uint256(uint128(-deltaAmount));
            if (amountOwed > maxAmount) amountOwed = maxAmount;
            
            if (Currency.unwrap(currency) == nativeToken) {
                if (nativeToken == address(0) || nativeToken == 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE) {
                    // Native ETH - send directly
                    poolManager.settle{value: amountOwed}(currency);
                } else {
                    // WETH - approve and settle
                    IERC20(nativeToken).approve(address(poolManager), amountOwed);
                    poolManager.settle(currency);
                }
            } else {
                // Other tokens
                IERC20(Currency.unwrap(currency)).approve(address(poolManager), amountOwed);
                poolManager.settle(currency);
            }
        } else if (deltaAmount > 0) {
            // Pool owes us tokens (fees collected)
            poolManager.take(currency, address(this), uint256(uint128(deltaAmount)));
        }
    }

    /**
     * @notice Collects fees and adds to reward pool
     */
    function _collectAndAddRewards(PoolKey memory _poolKey, BalanceDelta _feeDelta) internal {
        uint256 totalFeesInETH = 0;
        
        // Collect and convert fees to ETH equivalent
        if (_feeDelta.amount0() > 0) {
            if (Currency.unwrap(_poolKey.currency0) == nativeToken) {
                totalFeesInETH += uint256(uint128(_feeDelta.amount0()));
            }
            // Note: Non-native token conversion would happen here
        }
        
        if (_feeDelta.amount1() > 0) {
            if (Currency.unwrap(_poolKey.currency1) == nativeToken) {
                totalFeesInETH += uint256(uint128(_feeDelta.amount1()));
            }
            // Note: Non-native token conversion would happen here
        }
        
        if (totalFeesInETH > 0) {
            _notifyRewardAmount(totalFeesInETH);
        }
    }

    /**
     * @notice Adds rewards to the pool (Synthetix pattern)
     */
    function _notifyRewardAmount(uint256 _reward) internal updateReward(address(0)) {
        pendingRewards += _reward;
        emit RewardAdded(_reward);
    }

    /**
     * @notice Allows creators to withdraw their rewards
     */
    function withdrawRewards() external updateReward(msg.sender) {
        CreatorStake storage stake = creatorStakes[msg.sender];
        uint256 reward = stake.rewards;
        
        if (reward == 0) revert ZeroAmount();
        
        stake.rewards = 0;
        pendingRewards -= reward;
        
        // Transfer native token to creator
        if (nativeToken == address(0) || nativeToken == 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE) {
            // Native ETH
            (bool success,) = msg.sender.call{value: reward}("");
            require(success, "ETH transfer failed");
        } else {
            // WETH or other token
            IERC20(nativeToken).transfer(msg.sender, reward);
        }
        
        emit RewardsWithdrawn(msg.sender, reward);
    }

    /**
     * @notice Configures a new pool for liquidity provision
     * @param _poolKey Pool key
     * @param _tickLower Lower tick
     * @param _tickUpper Upper tick
     */
    function configurePool(
        PoolKey calldata _poolKey,
        int24 _tickLower,
        int24 _tickUpper
    ) external {
        if (msg.sender != positionManager) revert UnauthorizedAccess();
        
        PoolId poolId = _poolKey.toId();
        
        positions[poolId] = LPPosition({
            initialized: true,
            tickLower: _tickLower,
            tickUpper: _tickUpper,
            currentLiquidity: 0
        });
        
        configuredPools.push(_poolKey);
        
        emit PoolConfigured(poolId);
    }

    /**
     * @notice Simplified liquidity calculation for single-sided provision
     * @dev In production, use proper Uniswap V4 math libraries
     */
    function _calculateLiquidityDelta(
        uint160 sqrtPriceX96,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount,
        bool isToken0
    ) internal pure returns (uint128) {
        // This is a simplified calculation
        // In production, implement proper liquidity math
        uint160 sqrtRatioAX96 = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtRatioBX96 = TickMath.getSqrtPriceAtTick(tickUpper);
        
        if (isToken0) {
            // Calculate liquidity for token0
            return uint128(amount * 1e18 / (sqrtRatioBX96 - sqrtPriceX96));
        } else {
            // Calculate liquidity for token1
            return uint128(amount * 1e18 / (sqrtPriceX96 - sqrtRatioAX96));
        }
    }

    /**
     * @notice Returns creator's total claimable amount (stake + rewards)
     */
    function getClaimableAmount(address _creator) external view returns (uint256) {
        return earned(_creator);
    }

    receive() external payable {}
}