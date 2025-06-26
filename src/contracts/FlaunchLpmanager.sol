// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {Currency} from '@uniswap/v4-core/src/types/Currency.sol';
import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';
import {PoolId, PoolIdLibrary} from '@uniswap/v4-core/src/types/PoolId.sol';
import {IPoolManager} from '@uniswap/v4-core/src/interfaces/IPoolManager.sol';
import {BalanceDelta} from '@uniswap/v4-core/src/types/BalanceDelta.sol';
import {ILockCallback} from '@uniswap/v4-core/src/interfaces/callback/ILockCallback.sol';
import {StateLibrary} from '@uniswap/v4-core/src/libraries/StateLibrary.sol';
import {IAnyFlaunch} from '@flaunch-interfaces/IAnyFlaunch.sol';

/**
 * @title FlaunchLPManager
 * @notice LP manager for FLETH token with Synthetix-style rewards
 * @dev Only handles FLETH (ERC20) - no native ETH handling needed
 */
contract FlaunchLPManager is ILockCallback {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    error UnauthorizedAccess();
    error InvalidPool();
    error InsufficientBalance();
    error ZeroAmount();
    error PoolNotConfigured();

    event FeesReceived(address indexed memecoin, uint256 amount);
    event LiquidityProvided(PoolId indexed poolId, int128 liquidityDelta, uint256 amount);
    event RewardsWithdrawn(address indexed creator, uint256 amount);
    event PoolConfigured(PoolId indexed poolId);
    event RewardAdded(uint256 reward);

    struct CreatorStake {
        uint256 stake;
        uint256 rewardPerTokenPaid;
        uint256 rewards;
    }

    struct LPPosition {
        bool initialized;
        int24 tickLower;
        int24 tickUpper;
    }

    address public immutable positionManager;
    IAnyFlaunch public immutable flaunchContract;
    IPoolManager public immutable poolManager;
    address public immutable nativeToken; // FLETH token

    mapping(address => address) public memecoinToCreator;
    mapping(address => CreatorStake) public creatorStakes;
    mapping(PoolId => LPPosition) public positions;
    
    PoolKey[] public configuredPools;

    uint256 public rewardPerTokenStored;
    uint256 public lastUpdateTime;
    uint256 public totalStaked;
    uint256 public pendingRewards;

    uint256 public constant MIN_LIQUIDITY_AMOUNT = 0.01 ether;

    constructor(
        address _positionManager,
        address _flaunchContract,
        address _poolManager,
        address _nativeToken // FLETH address
    ) {
        positionManager = _positionManager;
        flaunchContract = IAnyFlaunch(_flaunchContract);
        poolManager = IPoolManager(_poolManager);
        nativeToken = _nativeToken;
        
        // Approve FLETH for pool manager operations
        IERC20(_nativeToken).approve(address(poolManager), type(uint256).max);
    }

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
     * @notice Receives FLETH fees from AnyPositionManager
     * @dev No payable needed - only handles ERC20 FLETH
     */
    function receiveFeesToken(address _memecoin, uint256 _amount) external updateReward(address(0)) {
        if (msg.sender != positionManager) revert UnauthorizedAccess();
        if (_amount == 0) revert ZeroAmount();

        // Transfer FLETH from position manager
        IERC20(nativeToken).transferFrom(positionManager, address(this), _amount);

        address creator = flaunchContract.creator(_memecoin);
        
        if (memecoinToCreator[_memecoin] == address(0)) {
            memecoinToCreator[_memecoin] = creator;
        }

        _updateCreatorStake(creator, _amount);
        emit FeesReceived(_memecoin, _amount);
        _tryProvideLiquidity();
    }

    function _updateCreatorStake(address _creator, uint256 _amount) internal updateReward(_creator) {
        CreatorStake storage stake = creatorStakes[_creator];
        totalStaked += _amount;
        stake.stake += _amount;
    }

    function rewardPerToken() public view returns (uint256) {
        if (totalStaked == 0) {
            return rewardPerTokenStored;
        }
        return rewardPerTokenStored + (pendingRewards * 1e18 / totalStaked);
    }

    function earned(address _creator) public view returns (uint256) {
        CreatorStake storage stake = creatorStakes[_creator];
        return (stake.stake * (rewardPerToken() - stake.rewardPerTokenPaid)) / 1e18 + stake.rewards;
    }

    /**
     * @notice Attempts to provide liquidity with FLETH
     */
    function _tryProvideLiquidity() internal {
        // Check FLETH balance
        uint256 availableBalance = IERC20(nativeToken).balanceOf(address(this)) - pendingRewards;
        
        if (availableBalance < MIN_LIQUIDITY_AMOUNT || configuredPools.length == 0) {
            return;
        }

        uint256 amountPerPool = availableBalance / configuredPools.length;
        
        for (uint256 i = 0; i < configuredPools.length; i++) {
            _provideLiquidityToPool(configuredPools[i], amountPerPool);
        }
    }

    /**
     * @notice Provides single-sided FLETH liquidity
     */
    function _provideLiquidityToPool(PoolKey memory _poolKey, uint256 _amount) internal {
        PoolId poolId = _poolKey.toId();
        LPPosition storage position = positions[poolId];
        
        if (!position.initialized) revert PoolNotConfigured();

        // Prepare data for lock callback
        bytes memory data = abi.encode(
            _poolKey,
            position.tickLower,
            position.tickUpper,
            _amount
        );

        // Use lock pattern for liquidity provision
        poolManager.lock(data);
    }

    /**
     * @notice Lock callback for liquidity provision
     */
    function lockAcquired(bytes calldata rawData) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert UnauthorizedAccess();

        (
            PoolKey memory key,
            int24 tickLower,
            int24 tickUpper,
            uint256 amount
        ) = abi.decode(rawData, (PoolKey, int24, int24, uint256));

        // Determine if FLETH is token0 or token1
        bool isToken0 = Currency.unwrap(key.currency0) == nativeToken;
        
        // Simple liquidity calculation for single-sided
        int128 liquidityDelta = int128(uint128(amount / 1e12));

        // Modify position
        (BalanceDelta delta, BalanceDelta feeDelta) = poolManager.modifyPosition(
            key,
            IPoolManager.ModifyPositionParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: liquidityDelta,
                salt: bytes32(0)
            }),
            ""
        );

        // Process balance delta
        _processBalanceDelta(key, delta);

        // Collect any fees
        if (feeDelta.amount0() > 0 || feeDelta.amount1() > 0) {
            _collectFees(key, feeDelta);
        }

        emit LiquidityProvided(key.toId(), liquidityDelta, amount);
        return abi.encode(liquidityDelta);
    }

    /**
     * @notice Process balance delta for FLETH and other tokens
     */
    function _processBalanceDelta(PoolKey memory key, BalanceDelta delta) private {
        // Handle token0
        if (delta.amount0() < 0) {
            // We owe token0
            uint256 amount0Owed = uint256(uint128(-delta.amount0()));
            
            if (Currency.unwrap(key.currency0) == nativeToken) {
                // FLETH - already approved in constructor
                poolManager.settle(key.currency0);
            } else {
                // Other token - approve and settle
                IERC20(Currency.unwrap(key.currency0)).approve(address(poolManager), amount0Owed);
                poolManager.settle(key.currency0);
            }
        } else if (delta.amount0() > 0) {
            // Pool owes us token0
            poolManager.take(key.currency0, address(this), uint256(uint128(delta.amount0())));
        }

        // Handle token1
        if (delta.amount1() < 0) {
            // We owe token1
            uint256 amount1Owed = uint256(uint128(-delta.amount1()));
            
            if (Currency.unwrap(key.currency1) == nativeToken) {
                // FLETH - already approved
                poolManager.settle(key.currency1);
            } else {
                // Other token
                IERC20(Currency.unwrap(key.currency1)).approve(address(poolManager), amount1Owed);
                poolManager.settle(key.currency1);
            }
        } else if (delta.amount1() > 0) {
            // Pool owes us token1
            poolManager.take(key.currency1, address(this), uint256(uint128(delta.amount1())));
        }
    }

    /**
     * @notice Collect fees in FLETH
     */
    function _collectFees(PoolKey memory _poolKey, BalanceDelta _feeDelta) private {
        uint256 totalFeesInFleth = 0;
        
        // Collect FLETH fees
        if (_feeDelta.amount0() > 0 && Currency.unwrap(_poolKey.currency0) == nativeToken) {
            totalFeesInFleth += uint256(uint128(_feeDelta.amount0()));
        }
        
        if (_feeDelta.amount1() > 0 && Currency.unwrap(_poolKey.currency1) == nativeToken) {
            totalFeesInFleth += uint256(uint128(_feeDelta.amount1()));
        }
        
        if (totalFeesInFleth > 0) {
            _notifyRewardAmount(totalFeesInFleth);
        }
    }

    function _notifyRewardAmount(uint256 _reward) internal updateReward(address(0)) {
        pendingRewards += _reward;
        emit RewardAdded(_reward);
    }

    /**
     * @notice Withdraw FLETH rewards
     */
    function withdrawRewards() external updateReward(msg.sender) {
        CreatorStake storage stake = creatorStakes[msg.sender];
        uint256 reward = stake.rewards;
        
        if (reward == 0) revert ZeroAmount();
        
        stake.rewards = 0;
        pendingRewards -= reward;
        
        // Transfer FLETH to creator
        IERC20(nativeToken).transfer(msg.sender, reward);
        
        emit RewardsWithdrawn(msg.sender, reward);
    }

    /**
     * @notice Configure pool for liquidity provision
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
            tickUpper: _tickUpper
        });
        
        configuredPools.push(_poolKey);
        
        emit PoolConfigured(poolId);
    }

    function getClaimableAmount(address _creator) external view returns (uint256) {
        return earned(_creator);
    }
}