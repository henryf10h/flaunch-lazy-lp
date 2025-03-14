// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import {PoolId} from '@uniswap/v4-core/src/types/PoolId.sol';
import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';

import {Flaunch} from '@flaunch/Flaunch.sol';
import {OnboardingManager} from '@flaunch/treasury/managers/OnboardingManager.sol';
import {PositionManager} from '@flaunch/PositionManager.sol';
import {SingleTokenManager} from '@flaunch/treasury/managers/SingleTokenManager.sol';
import {TreasuryManager} from '@flaunch/treasury/managers/TreasuryManager.sol';

import {ITreasuryManager} from '@flaunch-interfaces/ITreasuryManager.sol';

import {FlaunchTest} from 'test/FlaunchTest.sol';


contract OnboardingManagerTest is FlaunchTest {

    /// Treasury management contracts
    OnboardingManager onboardingManager;
    address managerImplementation;

    /// Store our flaunched tokenId
    uint tokenId;

    /// Store our flay token information
    uint flayTokenId;

    /// Define some helper addresses used during testing
    address payable owner = payable(address(123));
    address payable nonOwner = payable(address(456));
    address payable onboardee = payable(address(789));

    /// Set some default test parameters
    uint onboardeeAllocation = 75_00; // 75%
    uint claimWindowEnd = block.timestamp + 3600;
    PoolKey flayPoolKey;

    function setUp() public {
        // Deploy the Flaunch protocol
        _deployPlatform();

        // Define our Base $FLAY PoolKey
        flayTokenId = _createERC721(address(this));
        flayPoolKey = positionManager.poolKey(flaunch.memecoin(flayTokenId));

        // Set up our {TreasuryManagerFactory} and approve our onboarding implementation
        managerImplementation = address(new OnboardingManager(address(treasuryManagerFactory), payable(address(flayBurner)), address(snapshotAirdrop)));
        treasuryManagerFactory.approveManager(managerImplementation);

        // Approve the implementation to be an airdrop contract
        snapshotAirdrop.setApprovedAirdropCreators(managerImplementation, true);

        // Deploy our {OnboardingManager} implementation
        vm.startPrank(owner);
        address payable implementation = treasuryManagerFactory.deployManager(managerImplementation);
        onboardingManager = OnboardingManager(implementation);

        // Create a memecoin and approve the manager to take it
        tokenId = _createERC721(owner);
        flaunch.approve(address(onboardingManager), tokenId);

        // Initialize a testing token
        onboardingManager.initialize({
            _flaunchToken: ITreasuryManager.FlaunchToken({
                flaunch: flaunch,
                tokenId: tokenId
            }),
            _owner: owner,
            _data: abi.encode(
                OnboardingManager.InitializeParams(onboardee, onboardeeAllocation, claimWindowEnd)
            )
        });

        vm.stopPrank();
    }

    /**
     * initialize
     */

    function test_CanInitialize(
        address payable _onboardee,
        uint _onboardeeAllocation,
        uint _claimWindowEnd
    ) public freshManager {
        // Ensure our OnboardeeAllocation does not surpass a max value
        vm.assume(_onboardeeAllocation <= 100_00);

        // Ensure the claimWindowEnd is set in the future
        vm.assume(_claimWindowEnd > block.timestamp);

        // Create a memecoin and approve the manager to take it
        uint newTokenId = _createERC721(owner);

        vm.startPrank(owner);

        flaunch.approve(address(onboardingManager), newTokenId);

        // Define our initialization parameters
        OnboardingManager.InitializeParams memory params = OnboardingManager.InitializeParams({
            onboardee: _onboardee,
            onboardeeAllocation: _onboardeeAllocation,
            claimWindowEnd: _claimWindowEnd
        });

        vm.expectEmit();
        emit TreasuryManager.TreasuryEscrowed(address(flaunch), newTokenId, owner, owner);
        emit OnboardingManager.ManagerInitialized(address(flaunch), newTokenId, params);

        // Initialize a testing token
        onboardingManager.initialize({
            _flaunchToken: ITreasuryManager.FlaunchToken({
                flaunch: flaunch,
                tokenId: newTokenId
            }),
            _owner: owner,
            _data: abi.encode(params)
        });

        vm.stopPrank();

        (Flaunch _flaunch, uint _tokenId) = onboardingManager.flaunchToken();
        assertEq(address(_flaunch), address(flaunch));
        assertEq(_tokenId, newTokenId);

        assertEq(onboardingManager.onboardee(), _onboardee);
        assertEq(onboardingManager.onboardeeAllocation(), _onboardeeAllocation);
        assertEq(onboardingManager.claimWindowEnd(), _claimWindowEnd);

        assertEq(address(onboardingManager.airdropClaim()), address(snapshotAirdrop));
    }

    function test_CannotInitializeWithInvalidOnboardeeAllocation(uint _onboardeeAllocation) public freshManager {
        // Ensure our OnboardeeAllocation does not surpass a max value
        vm.assume(_onboardeeAllocation > 100_00);

        // Create a memecoin and approve the manager to take it
        uint newTokenId = _createERC721(owner);

        vm.startPrank(owner);

        flaunch.approve(address(onboardingManager), newTokenId);

        // Define our initialization parameters
        OnboardingManager.InitializeParams memory params = OnboardingManager.InitializeParams({
            onboardee: onboardee,
            onboardeeAllocation: _onboardeeAllocation,
            claimWindowEnd: claimWindowEnd
        });

        // Initialize a testing token
        vm.expectRevert(OnboardingManager.InvalidOnboardeeAllocation.selector);
        onboardingManager.initialize({
            _flaunchToken: ITreasuryManager.FlaunchToken({
                flaunch: flaunch,
                tokenId: newTokenId
            }),
            _owner: owner,
            _data: abi.encode(params)
        });

        vm.stopPrank();
    }

    function test_CannotInitializeWithUnownedToken() public freshManager {
        vm.expectRevert();
        onboardingManager.initialize({
            _flaunchToken: ITreasuryManager.FlaunchToken({
                flaunch: flaunch,
                tokenId: 123
            }),
            _owner: address(this),
            _data: abi.encode(onboardee, onboardeeAllocation, claimWindowEnd)
        });
    }

    function test_CannotInitializeIfTokenAlreadySet() public {
        // Flaunch another memecoin to mint a tokenId
        uint newTokenId = _createERC721(address(this));

        // Deploy our {OnboardingManager} implementation and transfer our tokenId
        flaunch.approve(address(onboardingManager), newTokenId);

        vm.expectRevert(abi.encodeWithSelector(
            SingleTokenManager.TokenAlreadySet.selector,
            ITreasuryManager.FlaunchToken(flaunch, tokenId)
        ));
        onboardingManager.initialize({
            _flaunchToken: ITreasuryManager.FlaunchToken({
                flaunch: flaunch,
                tokenId: newTokenId
            }),
            _owner: address(this),
            _data: abi.encode(onboardee, onboardeeAllocation, claimWindowEnd)
        });
    }

    /**
     * claim
     */

    function test_CanClaim(uint _claimTimestamp) public {
        // Ensure that our claim timestamp is within the window
        vm.assume(_claimTimestamp <= claimWindowEnd);
        vm.warp(_claimTimestamp);

        // Allocate 1e18 fees
        _allocateFees(1 ether);

        vm.startPrank(onboardee);

        // Make our claim as the onboardee
        onboardingManager.claim();

        // Confirm ownership of ERC721
        assertEq(flaunch.ownerOf(tokenId), onboardee);

        // Confirm onboardee allocation
        assertEq(onboardee.balance, 0.75 ether);

        // Confirm airdrop allocation, which will remain as flETH
        assertEq(flETH.balanceOf(address(snapshotAirdrop)), 0.25 ether);

        vm.stopPrank();
    }

    function test_CanClaimWithZeroFees(uint _claimTimestamp) public {
        // Ensure that our claim timestamp is within the window
        vm.assume(_claimTimestamp <= claimWindowEnd);
        vm.warp(_claimTimestamp);

        vm.startPrank(onboardee);

        // Make our claim as the onboardee
        onboardingManager.claim();

        // Confirm ownership of ERC721
        assertEq(flaunch.ownerOf(tokenId), onboardee);

        // Confirm onboardee allocation
        assertEq(onboardee.balance, 0);

        // Confirm airdrop allocation, which will remain as flETH
        assertEq(flETH.balanceOf(address(snapshotAirdrop)), 0);

        vm.stopPrank();
    }

    function test_CanClaimWithZeroOnboardeeAllocation(uint _claimTimestamp) public freshManager {
        // Ensure that our claim timestamp is within the window
        vm.assume(_claimTimestamp <= claimWindowEnd);
        vm.warp(_claimTimestamp);

        // Set our onboardee allocation to zero
        uint newTokenId = _createERC721(address(this));
        flaunch.approve(address(onboardingManager), newTokenId);

        // Initialize a testing token
        onboardingManager.initialize({
            _flaunchToken: ITreasuryManager.FlaunchToken({
                flaunch: flaunch,
                tokenId: newTokenId
            }),
            _owner: owner,
            _data: abi.encode(
                OnboardingManager.InitializeParams(onboardee, 0, claimWindowEnd)
            )
        });

        // Allocate 1e18 fees
        _allocateFees(1 ether);

        vm.startPrank(onboardee);

        // Make our claim as the onboardee
        onboardingManager.claim();

        // Confirm ownership of ERC721
        assertEq(flaunch.ownerOf(newTokenId), onboardee);

        // Confirm onboardee allocation
        assertEq(onboardee.balance, 0);

        // Confirm airdrop allocation, which will remain as flETH
        assertEq(flETH.balanceOf(address(snapshotAirdrop)), 1 ether);

        vm.stopPrank();
    }

    function test_CannotClaimIfNotOnboardee(address _caller) public {
        // Ensure that our claim timestamp is within the window
        vm.assume(_caller != onboardee);

        // Allocate 1e18 fees
        _allocateFees(1 ether);

        vm.startPrank(_caller);

        // Make our claim as the onboardee
        vm.expectRevert(OnboardingManager.InvalidClaimer.selector);
        onboardingManager.claim();

        vm.stopPrank();

    }
    function test_CannotClaimIfWindowEnded(uint _claimTimestamp) public {
        // Ensure that our claim timestamp is outside the window
        vm.assume(_claimTimestamp > claimWindowEnd);
        vm.warp(_claimTimestamp);

        // Allocate 1e18 fees
        _allocateFees(1 ether);

        vm.startPrank(onboardee);

        // Make our claim as the onboardee
        vm.expectRevert(OnboardingManager.OnboardingWindowClosed.selector);
        onboardingManager.claim();

        vm.stopPrank();
    }

    function test_CannotClaimIfUnableToReceiveEth() public {
        // ..
    }

    /**
     * release
     */

    function test_CanRelease(uint32 _claimTimestamp) public {
        // Ensure that our claim timestamp is outside the window
        vm.assume(_claimTimestamp > claimWindowEnd);
        vm.warp(_claimTimestamp);

        // Allocate 1e18 fees
        _allocateFees(1 ether);

        vm.prank(owner);
        onboardingManager.release();

        // Confirm that the token is burned
        vm.expectRevert();
        flaunch.ownerOf(tokenId);

        // Confirm that the onboardee has received nothing
        assertEq(payable(address(onboardee)).balance, 0);

        // Confirm that the BURN address has received some $FLAY token
        /*
        TODO:
        assertGt(
            IERC20(flaunch.memecoin(flayTokenId)).balanceOf(onboardingManager.BURN_ADDRESS()),
            0
        );
        */
    }

    function test_CanReleaseWithZeroBalance(uint _claimTimestamp) public {
        // Ensure that our claim timestamp is outside the window
        vm.assume(_claimTimestamp > claimWindowEnd);
        vm.warp(_claimTimestamp);

        // Allocate no fees

        vm.prank(owner);
        onboardingManager.release();

        // Confirm that the token is burned, which will revert with `TokenDoesNotExist`
        vm.expectRevert();
        flaunch.ownerOf(tokenId);

        // Confirm that they received no fees
        assertEq(payable(address(owner)).balance, 0);
    }

    function test_CannotReleaseBeforeWindowEnded(uint _claimTimestamp) public {
        // Ensure that our claim timestamp is within the window
        vm.assume(_claimTimestamp <= claimWindowEnd);

        // Allocate 1e18 fees
        _allocateFees(1 ether);

        vm.startPrank(owner);

        vm.expectRevert(OnboardingManager.OnboardingWindowNotClosed.selector);
        onboardingManager.release();

        vm.stopPrank();
    }


    /**
     * setOnboardee
     */

    function test_CanSetOnboardee(address payable _onboardee) public {
        // Ensure the protocol fee is within a valid range
        vm.assume(_onboardee != address(0));

        vm.expectEmit();
        emit OnboardingManager.OnboardeeUpdated(_onboardee);

        // Set the new protocol fee
        vm.prank(owner);
        onboardingManager.setOnboardee(_onboardee);

        // Confirm that the new fee is set
        assertEq(onboardingManager.onboardee(), _onboardee);
    }

    function test_CanSetZeroAddressOnboardee() public {
        vm.startPrank(owner);

        onboardingManager.setOnboardee(payable(address(0)));

        vm.stopPrank();
    }

    function test_CannotSetOnboardeeIfNotOwner(address _caller) public {
        // Ensure that the caller is not the owner
        vm.assume(_caller != owner);

        vm.startPrank(_caller);

        vm.expectRevert(TreasuryManager.NotManagerOwner.selector);
        onboardingManager.setOnboardee(payable(address(123)));

        vm.stopPrank();
    }

    function test_CannotRescueToken(address _caller, uint _tokenId) public {
        vm.startPrank(_caller);

        vm.expectRevert(OnboardingManager.CannotRescueToken.selector);
        onboardingManager.rescue(
            ITreasuryManager.FlaunchToken(flaunch, _tokenId),
            _caller
        );

        vm.stopPrank();
    }

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
        positionManager.allocateFeesMock(PoolId.wrap('test'), address(onboardingManager), _amount);
    }

    /**
     * Deploys a fresh {OnboardingManager} so that we the tokenId won't already be set.
     */
    modifier freshManager {
        // Deploy a new {OnboardingManager} implementation as we will be using a new tokenId
        onboardingManager = OnboardingManager(treasuryManagerFactory.deployManager(managerImplementation));

        _;
    }

}
