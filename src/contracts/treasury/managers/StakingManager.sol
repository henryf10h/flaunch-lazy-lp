// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {Flaunch} from '@flaunch/Flaunch.sol';
import {SafeTransferLib} from '@solady/utils/SafeTransferLib.sol';
import {FullMath} from '@uniswap/v4-core/src/libraries/FullMath.sol';
import {FixedPoint128} from '@uniswap/v4-core/src/libraries/FixedPoint128.sol';

import {SingleTokenManager} from '@flaunch/treasury/managers/SingleTokenManager.sol';

/**
 * Allows an ERC721 to be locked inside a staking manager. The users can stake their tokens
 * and earn their share of ETH rewards from the memestream.
 * 
 * The creator can specify the split % between themselves and the stakers.
 * 
 * The NFT and tokens are locked, based on the values set by the creator.
 */
contract StakingManager is SingleTokenManager {

    /**
     * Parameters passed during manager initialization.
     * 
     * @member stakingToken The address of the token to be staked
     * @member minEscrowDuration The minimum duration that the creator's NFT is locked for
     * @member minStakeDuration The minimum duration that the user's tokens are locked for
     * @member creatorSplit The split percentage between the creator and the stakers
     */
    struct InitializeParams {
        address stakingToken;
        uint minEscrowDuration;
        uint minStakeDuration;
        uint creatorSplit;
    }

    /**
     * A struct that represents a user's position in the staking manager.
     * 
     * @member amount The amount of tokens staked
     * @member timelockedUntil The timestamp until which the stake is locked
     * @member ethRewardsPerTokenSnapshotX128 The global ETH rewards per token snapshot,
     *         updated whenever a user stakes, unstakes or claims
     * @member ethOwed The pending ETH rewards for the user, before the last snapshot
     */
    struct Position {
        uint amount;
        uint timelockedUntil;
        uint ethRewardsPerTokenSnapshotX128;
        uint ethOwed;
    }

    /// The maximum value of a creator's split (100%)
    uint internal constant MAX_CREATOR_SPLIT = 100_00;

    /// The address of the token to be staked
    address public stakingToken;

    /// The minimum duration that the creator's NFT is locked for
    uint public minEscrowDuration;

    /// The minimum duration that the user's tokens are locked for
    uint public minStakeDuration;

    /// The split % between the creator and the stakers
    uint public creatorSplit;

    /// Whether the creator has escrowed their NFT
    bool public isStakingActive;

    /// The total amount of tokens deposited
    uint public totalDeposited;

    /// The global ETH rewards per token snapshot
    uint public globalEthRewardsPerTokenX128;

    /// The pending ETH rewards for the creator
    uint public creatorETHRewards;

    /// The timestamp until which the creator's NFT is locked
    uint public escrowLockedUntil;

    /// A mapping of user addresses to their position in the staking manager
    mapping(address user => Position position) public userPositions;

    event ManagerInitialized(address indexed _flaunch, uint indexed _tokenId, InitializeParams _params);
    event EscrowDeposit(uint _tokenId, address _sender);
    event EscrowWithdrawal(uint _tokenId, address _sender);
    event CreatorClaim(uint _tokenId, address _sender, uint _amount);
    event EscrowDurationExtended(uint _tokenId, uint _newDuration);
    event Stake(uint _tokenId, address _sender, uint _amount);
    event Unstake(uint _tokenId, address _sender, uint _amount);
    event Claim(uint _tokenId, address _sender, uint _amount);
    event CreatorSplitUpdated(uint _tokenId, uint _newSplit);
    event MinStakeDurationUpdated(uint _tokenId, uint _newDuration);

    error TokenIdAlreadySet(uint _tokenId);
    error InvalidCreatorSplit();
    error EscrowLocked();
    error StakingDisabled();
    error StakeLocked();
    error InsufficientBalance();

    /**
     * Sets up the contract with the initial required contract addresses.
     *
     * @param _treasuryManagerFactory The {TreasuryManagerFactory} that will launch this implementation
     */
    constructor(address _treasuryManagerFactory) SingleTokenManager(_treasuryManagerFactory) {}

    /**
     * Registers the tokenId passed by the initialization and ensures that it is the only one
     * registered to the manager along with setting our initial configurations.
     *
     * @param _flaunchToken The Flaunch token that is being deposited
     * @param _data Staking manager variables
     */
    function _initialize(FlaunchToken calldata _flaunchToken, bytes calldata _data) internal override depositSingleToken(_flaunchToken) {
        // Unpack our initial manager settings
        (InitializeParams memory params) = abi.decode(_data, (InitializeParams));
        stakingToken = params.stakingToken;
        minEscrowDuration = params.minEscrowDuration;
        minStakeDuration = params.minStakeDuration;

        // Validate and set the creator split
        if (params.creatorSplit > MAX_CREATOR_SPLIT) revert InvalidCreatorSplit();
        creatorSplit = params.creatorSplit;

        // Set the timestamp for the escrow lock
        escrowLockedUntil = block.timestamp + params.minEscrowDuration;

        // Set the staking active flag
        isStakingActive = true;

        // Emit an event that shows our initial data
        emit ManagerInitialized(address(_flaunchToken.flaunch), _flaunchToken.tokenId, params);
    }

    /**
     * Allows the creator to withdraw their NFT, once the escrow lock has passed.
     */
    function escrowWithdraw() external onlyManagerOwner stakingIsActive {
        // Ensure that the escrow is unlocked
        if (block.timestamp < escrowLockedUntil) revert EscrowLocked();

        // Transfer the token from the contract to the msg.sender
        flaunchToken.flaunch.transferFrom(address(this), msg.sender, flaunchToken.tokenId);

        // Set the staking active flag to false
        isStakingActive = false;

        // Emit our escrow withdrawal event
        emit EscrowWithdrawal(flaunchToken.tokenId, msg.sender);
    }

    /**
     * Allows the creator to claim their pending ETH rewards.
     */
    function creatorClaim() external onlyManagerOwner {
        // Get the creator's pending ETH rewards
        uint _creatorETHRewards = creatorETHRewards;
        
        // Set the creator's pending ETH rewards to 0
        creatorETHRewards = 0;

        SafeTransferLib.safeTransferETH(msg.sender, _creatorETHRewards);

        // Emit our creator claim event
        emit CreatorClaim(flaunchToken.tokenId, msg.sender, _creatorETHRewards);
    }

    /**
     * Allows the creator to extend their escrow lock duration.
     * 
     * @param _extendBy The amount of time to extend the escrow by
     */
    function extendEscrowDuration(uint _extendBy) external onlyManagerOwner stakingIsActive {
        // Extend the escrow lock duration
        escrowLockedUntil += _extendBy;

        // Emit our escrow duration extended event
        emit EscrowDurationExtended(flaunchToken.tokenId, escrowLockedUntil);
    }

    /**
     * Allows a user to stake their tokens into the staking manager.
     * 
     * @param _amount The amount of tokens to stake
     */
    function stake(uint _amount) external stakingIsActive {
        // account fees for previous depositors
        _withdrawFees();

        // transfer the tokens from the msg.sender to the contract
        IERC20(stakingToken).transferFrom(msg.sender, address(this), _amount);
        totalDeposited += _amount;

        // update the user's position
        Position storage position = userPositions[msg.sender];

        // if the user has an existing position, calculate the eth owed till now
        if (position.amount != 0) {
            position.ethOwed = _getTotalEthOwed(position);
        }

        // Set rest of the position data
        position.amount += _amount;
        position.timelockedUntil = block.timestamp + minStakeDuration;
        position.ethRewardsPerTokenSnapshotX128 = globalEthRewardsPerTokenX128;

        // Emit our stake event
        emit Stake(flaunchToken.tokenId, msg.sender, _amount);
    }

    /**
     * Allows a user to unstake their tokens from the staking manager.
     * 
     * @dev Claims any pending ETH rewards before unstaking as well.
     * 
     * @param _amount The amount of tokens to unstake
     */
    function unstake(uint _amount) external {
        // Get the user's position
        Position storage position = userPositions[msg.sender];

        // Ensure that the stake is not locked
        if (block.timestamp < position.timelockedUntil) revert StakeLocked();

        // Ensure that the user has enough balance
        if (_amount > position.amount) revert InsufficientBalance();

        // Claim any pending rewards
        claim();

        // Update the positions data
        position.amount -= _amount;
        totalDeposited -= _amount;

        // Transfer the tokens from the contract to the msg.sender
        IERC20(stakingToken).transfer(msg.sender, _amount);

        // Emit our unstake event
        emit Unstake(flaunchToken.tokenId, msg.sender, _amount);
    }

    /**
     * Allows a user to claim their pending ETH rewards.
     */
    function claim() public {
        // Account for any fees owed to the sender and other depositors
        _withdrawFees();

        // Get the user's position
        Position storage position = userPositions[msg.sender];

        // Get the total ETH owed to the user
        uint ethOwed = _getTotalEthOwed(position);

        // Update the user's position data
        position.ethOwed = 0;
        position.ethRewardsPerTokenSnapshotX128 = globalEthRewardsPerTokenX128;

        // Transfer the ETH to the user
        SafeTransferLib.safeTransferETH(msg.sender, ethOwed);

        // Emit our claim event
        emit Claim(flaunchToken.tokenId, msg.sender, ethOwed);
    }

    /**
     * View the stake information for a user.
     * 
     * @param _user The address of the user to view the stake information for
     * 
     * @return amount The amount of tokens staked
     * @return timelockedUntil The timestamp until which the stake is locked
     * @return pendingETHRewards The pending ETH rewards for the user
     */
    function getUserStakeInfo(address _user) external view returns (
        uint amount,
        uint timelockedUntil,
        uint pendingETHRewards
    ) {
        Position storage position = userPositions[_user];
        return (
            position.amount,
            position.timelockedUntil,
            _getTotalEthOwed(position)
        );
    }

    /**
     * Allows the contract to withdraw any pending ETH fees.
     * 
     * @dev This function is called before each operation: stake, unstake, and claim.
     */
    function _withdrawFees() internal {
        uint startBalance = address(this).balance;

        // Withdraw fees in ETH
        flaunchToken.flaunch.positionManager().withdrawFees({
            _recipient: address(this),
            _unwrap: true
        });

        uint feesWithdrawn = address(this).balance - startBalance;

        // early return if there are no fees to distribute
        if (feesWithdrawn == 0) return;

        // if there were no staked deposits until now, all fees go to the creator
        if (totalDeposited == 0) {
            creatorETHRewards += feesWithdrawn;
            return;
        }

        // Calculate the creator's share of the fees
        uint creatorShare = FullMath.mulDiv(
            feesWithdrawn,
            creatorSplit,
            MAX_CREATOR_SPLIT
        );

        // Update the creator's pending ETH rewards
        creatorETHRewards += creatorShare;

        // Update the global ETH rewards per token snapshot, after deducting the creator's share
        globalEthRewardsPerTokenX128 += FullMath.mulDiv(
            feesWithdrawn - creatorShare,
            FixedPoint128.Q128,
            totalDeposited
        );
    }

    /**
     * Calculates the total ETH owed to a user, based on their position and the global ETH rewards per token snapshot.
     * 
     * @param _position The user's position in the staking manager
     * @return The total ETH owed to the user
     */
    function _getTotalEthOwed(
        Position storage _position
    ) internal view returns (uint) {
        return FullMath.mulDiv(
            globalEthRewardsPerTokenX128 - _position.ethRewardsPerTokenSnapshotX128,
            _position.amount,
            FixedPoint128.Q128
        ) + _position.ethOwed;
    }

    modifier stakingIsActive() {
        if (!isStakingActive) revert StakingDisabled();
        _;
    }
}