// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {OnboardingManager} from '@flaunch/treasury/managers/OnboardingManager.sol';
import {RaidManager} from '@flaunch/treasury/managers/RaidManager.sol';

import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';

import {PositionManager} from '@flaunch/PositionManager.sol';

import {FlaunchTest} from 'test/FlaunchTest.sol';


contract RaidManagerTest is FlaunchTest {

    // Define some test users
    address payable public user0 = payable(address(1112));
    address payable public user1 = payable(address(1113));

    // Define some test tokens
    uint public token0;
    uint public token1;
    uint public token2;

    address managerImplementation;
    RaidManager public raidManager;

    PoolKey flayPoolKey;

    function setUp() public {
        // Deploy our platform
        _deployPlatform();

        // Flaunch a couple of tokens that we can test with
        token0 = _createERC721(user0);
        token1 = _createERC721(user0);
        token2 = _createERC721(user1);

        vm.startPrank(user0);
        flaunch.approve(address(raidManager), token0);
        flaunch.approve(address(raidManager), token1);
        vm.stopPrank();

        vm.prank(user1);
        flaunch.approve(address(raidManager), token2);

        // Define our Base $FLAY PoolKey
        uint flayTokenId = _createERC721(address(this));
        flayPoolKey = positionManager.poolKey(flaunch.memecoin(flayTokenId));

        // Set up our {TreasuryManagerFactory} and approve our raiding implementation
        managerImplementation = address(new RaidManager(address(flaunch), address(0), address(0), flayPoolKey));
        treasuryManagerFactory.approveManager(managerImplementation);

        // Deploy our {OnboardingManager} implementation
        address payable implementation = treasuryManagerFactory.deployManager(managerImplementation);
        raidManager = RaidManager(implementation);

        // Initialize a testing token
        vm.startPrank(user1);
        raidManager.initialize({
            _tokenId: token2,
            _owner: address(this),
            _data: abi.encode(
                OnboardingManager.InitializeParams({
                    onboardee: payable(address(123)),
                    onboardeeAllocation: 50_00,
                    claimWindowEnd: block.timestamp + 30 days
                })
            )
        });
        vm.stopPrank();
    }

    function test_CanJoinRaid() public {
        vm.expectEmit();
        emit RaidManager.RaidJoined(token0);

        vm.prank(user0);
        raidManager.joinRaid(token0);

        assertEq(flaunch.ownerOf(token0), address(raidManager));
        assertEq(raidManager.raiders(token0), user0);
    }

    function test_CannotJoinRaidAfterWindowEnd(uint _delay) public {
        vm.assume(_delay > raidManager.claimWindowEnd());
        vm.warp(_delay);

        vm.startPrank(user0);

        vm.expectRevert(OnboardingManager.OnboardingWindowClosed.selector);
        raidManager.joinRaid(token0);

        vm.stopPrank();
    }

    function test_CannotJoinRaidIfTokenAlreadyRaiding() public {
        vm.startPrank(user0);
        raidManager.joinRaid(token0);

        vm.expectRevert(RaidManager.TokenAlreadyRaiding.selector);
        raidManager.joinRaid(token0);

        raidManager.joinRaid(token1);
        vm.stopPrank();
    }

    function test_CannotJoinRaidWithSomeoneElsesToken() public {
        vm.startPrank(user1);
        vm.expectRevert();
        raidManager.joinRaid(token0);
        vm.stopPrank();
    }

    function test_CanExitRaid() public {
        // Add our token to the raid
        vm.startPrank(user0);
        raidManager.joinRaid(token0);

        vm.expectEmit();
        emit RaidManager.RaidExited(token0);

        raidManager.exitRaid(token0);

        assertEq(flaunch.ownerOf(token0), user0);
        assertEq(raidManager.raiders(token0), address(0));
    }

    function test_CannotExitRaidIfNotTokenRaider() public {
        // Add our token to the raid
        vm.prank(user0);
        raidManager.joinRaid(token0);

        vm.expectRevert(OnboardingManager.InvalidClaimer.selector);
        vm.prank(user1);
        raidManager.exitRaid(token0);
    }

    function test_CannotExitRaidIfTokenNotRaider() public {
        vm.expectRevert();
        vm.prank(user0);
        raidManager.exitRaid(token0);
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

}
