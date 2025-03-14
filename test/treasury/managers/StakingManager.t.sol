// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20Mock} from "test/mocks/ERC20Mock.sol";
import {PoolId} from '@uniswap/v4-core/src/types/PoolId.sol';

import {Flaunch} from '@flaunch/Flaunch.sol';
import {PositionManager} from '@flaunch/PositionManager.sol';
import {TreasuryManager} from '@flaunch/treasury/managers/TreasuryManager.sol';
import {StakingManager} from '@flaunch/treasury/managers/StakingManager.sol';
import {SingleTokenManager} from '@flaunch/treasury/managers/SingleTokenManager.sol';

import {ITreasuryManager} from '@flaunch-interfaces/ITreasuryManager.sol';

import {FlaunchTest} from 'test/FlaunchTest.sol';

contract StakingManagerTest is FlaunchTest {
    /// constants
    uint internal constant MAX_CREATOR_SPLIT = 100_00;

    /// The staking manager
    StakingManager stakingManager;
    address managerImplementation;

    /// Store our flaunched tokenId
    uint tokenId;

    /// Define some helper addresses used during testing
    address payable owner = payable(address(123));
    address payable nonOwner = payable(address(456));

    /// Set some default test parameters
    ERC20Mock stakingToken;
    uint minEscrowDuration = 30 days;
    uint minStakeDuration = 7 days;
    uint creatorSplit = 10_00;

    function setUp() public {
        // Deploy the Flaunch protocol
        _deployPlatform();

        // Deploy and approve our staking manager implementation
        managerImplementation = address(new StakingManager(address(treasuryManagerFactory)));
        treasuryManagerFactory.approveManager(managerImplementation);

        // Deploy our {StakingManager} implementation
        vm.startPrank(owner);
        address payable implementation = treasuryManagerFactory.deployManager(managerImplementation);
        stakingManager = StakingManager(implementation);

        // Create a memecoin and approve the manager to take it
        tokenId = _createERC721(owner);
        flaunch.approve(address(stakingManager), tokenId);

        // Deploy a Token to stake for testing
        stakingToken = new ERC20Mock("Meme", "MEME");

        // Initialize a testing token
        stakingManager.initialize({
            _flaunchToken: ITreasuryManager.FlaunchToken({
                flaunch: flaunch,
                tokenId: tokenId
            }),
            _owner: owner,
            _data: abi.encode(
                StakingManager.InitializeParams(address(stakingToken), minEscrowDuration, minStakeDuration, creatorSplit)
            )
        });
        
        vm.stopPrank();
    }

    /**
     * initialize
     */

    function test_CanInitializeSuccessfully(
        address _stakingToken,
        uint _minEscrowDuration,
        uint _minStakeDuration,
        uint _creatorSplit
    ) public freshManager {
        // Ensure that the creator split is valid
        vm.assume(_creatorSplit <= MAX_CREATOR_SPLIT);
        // Ensure that there's no overflow in tests when `escrowLockedUntil` is calculated
        vm.assume(_minEscrowDuration < type(uint).max - block.timestamp);

        // Create a memecoin and approve the manager to take it
        vm.startPrank(owner);
        uint newTokenId = _createERC721(owner);
        flaunch.approve(address(stakingManager), newTokenId);

        // Define our initialization parameters
        StakingManager.InitializeParams memory params = StakingManager.InitializeParams({
            stakingToken: _stakingToken,
            minEscrowDuration: _minEscrowDuration,
            minStakeDuration: _minStakeDuration,
            creatorSplit: _creatorSplit
        });

        vm.expectEmit();
        emit StakingManager.ManagerInitialized(address(flaunch), newTokenId, params);

        // Initialize a testing token
        stakingManager.initialize({
            _flaunchToken: ITreasuryManager.FlaunchToken({
                flaunch: flaunch,
                tokenId: newTokenId
            }),
            _owner: owner,
            _data: abi.encode(params)
        });

        vm.stopPrank();

        (Flaunch _flaunch, uint _tokenId) = stakingManager.flaunchToken();
        assertEq(address(_flaunch), address(flaunch));
        assertEq(_tokenId, newTokenId);

        assertEq(stakingManager.stakingToken(), _stakingToken);
        assertEq(stakingManager.minEscrowDuration(), _minEscrowDuration);
        assertEq(stakingManager.minStakeDuration(), _minStakeDuration);
        assertEq(stakingManager.creatorSplit(), _creatorSplit);
        assertEq(stakingManager.escrowLockedUntil(), block.timestamp + _minEscrowDuration);
        assertEq(stakingManager.isStakingActive(), true);
    }

    function test_CannotInitializeWithInvalidCreatorSplit(uint _creatorSplit) public freshManager {
        // Ensure that the creator split is invalid
        vm.assume(_creatorSplit > MAX_CREATOR_SPLIT);

        // Create a memecoin and approve the manager to take it
        vm.startPrank(owner);
        uint newTokenId = _createERC721(owner);
        flaunch.approve(address(stakingManager), newTokenId);

        vm.expectRevert(StakingManager.InvalidCreatorSplit.selector);
        stakingManager.initialize({
            _flaunchToken: ITreasuryManager.FlaunchToken({
                flaunch: flaunch,
                tokenId: newTokenId
            }),
            _owner: owner,
            _data: abi.encode(StakingManager.InitializeParams(address(stakingToken), minEscrowDuration, minStakeDuration, _creatorSplit))
        });

        vm.stopPrank();
    }

    function test_CannotInitializeWithUnownedToken() public freshManager {
        vm.expectRevert();
        stakingManager.initialize({
            _flaunchToken: ITreasuryManager.FlaunchToken({
                flaunch: flaunch,
                tokenId: 123
            }),
            _owner: owner,
            _data: abi.encode(StakingManager.InitializeParams(address(stakingToken), minEscrowDuration, minStakeDuration, creatorSplit))
        });
    }

    function test_CannotInitializeIfTokenIdAlreadySet() public {
        // Flaunch another memecoin to mint a tokenId
        uint newTokenId = _createERC721(address(this));

        // Deploy our {StakingManager} implementation and transfer our tokenId
        flaunch.approve(address(stakingManager), newTokenId);

        vm.expectRevert(abi.encodeWithSelector(
            SingleTokenManager.TokenAlreadySet.selector,
            ITreasuryManager.FlaunchToken(flaunch, tokenId)
        ));
        stakingManager.initialize({
            _flaunchToken: ITreasuryManager.FlaunchToken({
                flaunch: flaunch,
                tokenId: newTokenId
            }),
            _owner: owner,
            _data: abi.encode(StakingManager.InitializeParams(address(stakingToken), minEscrowDuration, minStakeDuration, creatorSplit))
        });
    }

    /**
     * escrowWithdraw
     */

    function test_CanEscrowWithdrawSuccessfully() public {
        vm.warp(stakingManager.escrowLockedUntil() + 1);

        vm.startPrank(owner);
        
        vm.expectEmit();
        emit StakingManager.EscrowWithdrawal(tokenId, owner);
        stakingManager.escrowWithdraw();

        vm.stopPrank();

        assertEq(stakingManager.isStakingActive(), false);
        assertEq(flaunch.ownerOf(tokenId), owner);
    }

    function test_CannotEscrowWithdrawIfNotOwner() public {
        vm.warp(stakingManager.escrowLockedUntil() + 1);
        
        vm.startPrank(nonOwner);
        
        vm.expectRevert(TreasuryManager.NotManagerOwner.selector);
        stakingManager.escrowWithdraw();

        vm.stopPrank();
    }

    function test_CannotEscrowWithdrawIfStakingIsNotActive() public {
        vm.warp(stakingManager.escrowLockedUntil() + 1);

        vm.startPrank(owner);
        stakingManager.escrowWithdraw();

        vm.expectRevert(StakingManager.StakingDisabled.selector);
        stakingManager.escrowWithdraw();
        vm.stopPrank();
    }

    function test_CannotEscrowWithdrawIfEscrowIsNotUnlocked() public {
        vm.startPrank(owner);
        vm.expectRevert(StakingManager.EscrowLocked.selector);
        stakingManager.escrowWithdraw();
        vm.stopPrank();
    }

    /**
     * creatorClaim
     */

    function test_CanCreatorClaimSuccessfully() public {
        _allocateFees(10 ether);
        // trigger withdraw fees
        _mintTokensToStake(1 wei);
        stakingManager.stake(1 wei);

        vm.startPrank(owner);

        uint prevBalance = owner.balance;

        vm.expectEmit();
        emit StakingManager.CreatorClaim(tokenId, owner, 10 ether);
        stakingManager.creatorClaim();

        assertEq(owner.balance - prevBalance, 10 ether);

        vm.stopPrank();
    }
    
    function test_CannotCreatorClaimIfNotOwner() public {
        vm.startPrank(nonOwner);
        vm.expectRevert(TreasuryManager.NotManagerOwner.selector);
        stakingManager.creatorClaim();
        vm.stopPrank();
    }
    
    /**
     * extendEscrowDuration
     */

    function test_CanExtendEscrowDurationSuccessfully() public {
        vm.startPrank(owner);

        uint prevEscrowLockedUntil = stakingManager.escrowLockedUntil();

        vm.expectEmit();
        emit StakingManager.EscrowDurationExtended(tokenId, prevEscrowLockedUntil + 10 days);
        stakingManager.extendEscrowDuration(10 days);

        vm.stopPrank();

        assertEq(stakingManager.escrowLockedUntil(), prevEscrowLockedUntil + 10 days);
    }

    function test_CannotExtendEscrowDurationIfNotOwner() public {
        vm.startPrank(nonOwner);

        vm.expectRevert(TreasuryManager.NotManagerOwner.selector);
        stakingManager.extendEscrowDuration(10 days);

        vm.stopPrank();
    }

    function test_CannotExtendEscrowDurationIfStakingIsNotActive() public {
        vm.startPrank(owner);
        vm.warp(stakingManager.escrowLockedUntil() + 1);
        stakingManager.escrowWithdraw();

        vm.expectRevert(StakingManager.StakingDisabled.selector);
        stakingManager.extendEscrowDuration(10 days);

        vm.stopPrank();
    }

    /**
     * stake
     */

    function test_CanStakeSuccessfully(uint _amount) public {
        vm.assume(_amount > 0);
        _mintTokensToStake(_amount);

        uint prevBalance = stakingToken.balanceOf(address(this));

        vm.expectEmit();
        emit StakingManager.Stake(tokenId, address(this), _amount);
        stakingManager.stake(_amount);

        assertEq(stakingManager.totalDeposited(), _amount);
        assertEq(stakingToken.balanceOf(address(this)), prevBalance - _amount);
        assertEq(stakingToken.balanceOf(address(stakingManager)), _amount);

        (uint amount, uint timelockedUntil, uint ethRewardsPerTokenSnapshotX128, ) = stakingManager.userPositions(address(this));
        assertEq(amount, _amount);
        assertEq(timelockedUntil, block.timestamp + minStakeDuration);
        assertEq(ethRewardsPerTokenSnapshotX128, stakingManager.globalEthRewardsPerTokenX128());
    }

    // Handle correctly setting `ethOwed`
    function test_CanStakeAgainSuccessfully(uint _amountFirstStake, uint _amountSecondStake) public {
        // Restrict amount to maintain precision during calculations
        vm.assume(_amountFirstStake > 0 && _amountFirstStake < type(uint128).max);
        vm.assume(_amountSecondStake > 0 && _amountSecondStake < type(uint128).max);
        // avoid overflow in tests
        vm.assume(_amountSecondStake < type(uint).max - _amountFirstStake);

        _mintTokensToStake(_amountFirstStake);
        stakingManager.stake(_amountFirstStake);

        (, , , uint ethOwed) = stakingManager.userPositions(address(this));
        assertEq(ethOwed, 0);
        
        // distribute rewards
        _allocateFees(10 ether);

        // stake again
        _mintTokensToStake(_amountSecondStake);
        stakingManager.stake(_amountSecondStake);

        (, , , ethOwed) = stakingManager.userPositions(address(this));
        // after deducting the creator's share
        assertApproxEqAbs(
            ethOwed,
            9 ether,
            1 wei // allow error upto few wei
        );
    }

    function test_CannotStakeIfStakingIsNotActive() public {
        vm.startPrank(owner);
        vm.warp(stakingManager.escrowLockedUntil() + 1);
        stakingManager.escrowWithdraw();
        vm.stopPrank();

        vm.expectRevert(StakingManager.StakingDisabled.selector);
        stakingManager.stake(1 wei);
    }

    /**
     * unstake
     */

    function test_CanUnstakeSuccessfully(uint _amount) public {
        vm.assume(_amount > 0);
        // Restrict amount to maintain precision during calculations
        vm.assume(_amount < type(uint128).max);

        _mintTokensToStake(_amount);
        stakingManager.stake(_amount);

        // distribute rewards
        _allocateFees(10 ether);
        
        // jump to make position unlocked
        (, uint timelockedUntil, ,) = stakingManager.userPositions(address(this));
        vm.warp(timelockedUntil + 1);

        uint prevBalance = address(this).balance;

        vm.expectEmit();
        emit StakingManager.Unstake(tokenId, address(this), _amount);
        stakingManager.unstake(_amount);

        assertEq(stakingToken.balanceOf(address(this)), _amount);
        assertEq(stakingToken.balanceOf(address(stakingManager)), 0);
        
        (uint amount, , , ) = stakingManager.userPositions(address(this));
        assertEq(amount, 0);
        assertEq(stakingManager.totalDeposited(), 0);
        assertApproxEqAbs(
            address(this).balance - prevBalance,
            9 ether,
            1 wei // allow error upto few wei
        );
    }

    function test_CannotUnstakeIfStakeIsLocked(uint _amount) public {
        vm.assume(_amount > 0);

        _mintTokensToStake(_amount);
        stakingManager.stake(_amount);

        vm.expectRevert(StakingManager.StakeLocked.selector);
        stakingManager.unstake(_amount);
    }

    function test_CannotUnstakeIfInsufficientBalance(uint _amount) public {
        vm.assume(_amount > 0);

        // stake 1 less than the amount to unstake
        _mintTokensToStake(_amount - 1);
        stakingManager.stake(_amount - 1);

        // jump to make position unlocked
        (, uint timelockedUntil, ,) = stakingManager.userPositions(address(this));
        vm.warp(timelockedUntil + 1);

        vm.expectRevert(StakingManager.InsufficientBalance.selector);
        stakingManager.unstake(_amount);
    }

    /**
     * claim
     */

    function test_CanClaimSuccessfully() public {
        _mintTokensToStake(100 ether);
        // First: stake 10 coins
        stakingManager.stake(10 ether);

        // distribute 10 ETH in fees
        _allocateFees(10 ether);

        // Second: stake 90 coins
        stakingManager.stake(90 ether);

        // distribute 90 ETH in fees
        _allocateFees(90 ether);

        // jump to make position unlocked
        (, uint timelockedUntil, ,) = stakingManager.userPositions(address(this));
        vm.warp(timelockedUntil + 1);
        
        // claim
        uint prevBalance = address(this).balance;

        vm.expectEmit();
        emit StakingManager.Claim(tokenId, address(this), 90 ether - 2 wei);
        stakingManager.claim();

        // ensure that the user received 90 ether, after deducting the creator's share
        assertApproxEqAbs(
            address(this).balance - prevBalance,
            90 ether,
            2 wei // allow error upto few wei
        );

        (, , uint pendingETHRewards) = stakingManager.getUserStakeInfo(address(this));
        assertEq(pendingETHRewards, 0);
        (, , uint ethRewardsPerTokenSnapshotX128, ) = stakingManager.userPositions(address(this));
        assertEq(ethRewardsPerTokenSnapshotX128, stakingManager.globalEthRewardsPerTokenX128());
    }

    /**
     * Internal Helpers
     */
    function _createERC721(address _recipient) internal returns (uint tokenId_) {
        // Flaunch another memecoin to mint a tokenId
        address memecoin = positionManager.flaunch(
            PositionManager.FlaunchParams({
                name: 'Token Name',
                symbol: 'TOKEN',
                tokenUri: 'https://flaunch.gg/',
                initialTokenFairLaunch: supplyShare(50),
                premineAmount: 0,
                creator: _recipient,
                creatorFeeAllocation: 0,
                flaunchAt: 0,
                initialPriceParams: abi.encode(5000e6),
                feeCalculatorParams: abi.encode(1_000)
            })
        );

        // Get the tokenId from the memecoin address
        return flaunch.tokenId(memecoin);
    }

    function _allocateFees(uint _amount) internal {
        // Mint ETH to the flETH contract to facilitate unwrapping
        deal(address(this), _amount);
        WETH.deposit{value: _amount}();
        WETH.transfer(address(positionManager), _amount);

        // Allocate our fees. The PoolId does not matter.
        positionManager.allocateFeesMock(PoolId.wrap('test'), address(stakingManager), _amount);
    }

    function _mintTokensToStake(uint _amount) internal {
        stakingToken.mint(address(this), _amount);
        stakingToken.approve(address(stakingManager), type(uint).max);
    }

    /**
     * Deploys a fresh {StakingManager} so that we the tokenId won't already be set.
     */
    modifier freshManager {
        // Deploy a new {StakingManager} implementation as we will be using a new tokenId
        stakingManager = StakingManager(treasuryManagerFactory.deployManager(managerImplementation));

        _;
    }
}