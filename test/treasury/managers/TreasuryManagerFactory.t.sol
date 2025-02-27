// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PositionManager} from '@flaunch/PositionManager.sol';
import {TreasuryManagerFactory} from '@flaunch/treasury/managers/TreasuryManagerFactory.sol';

import {TreasuryManagerMock} from 'test/mocks/TreasuryManagerMock.sol';
import {FlaunchTest} from 'test/FlaunchTest.sol';


contract TreasuryManagerFactoryTest is FlaunchTest {

    TreasuryManagerFactory factory;

    /// Define some EOA addresses to test with
    address owner = address(0x123);
    address nonOwner = address(0x456);

    address managerImplementation;
    uint tokenId;
    bytes data;

    function setUp() public {
        // Deploy our platform
        _deployPlatform();

        // Update our {TreasuryManagerFactory} deployment to use an explicit owner
        factory = new TreasuryManagerFactory(owner);

        // Deploy a mocked manager implementation
        managerImplementation = address(new TreasuryManagerMock(address(flaunch)));

        // Flaunch a memecoin that we can test with
        address memecoin = positionManager.flaunch(
            PositionManager.FlaunchParams({
                name: 'Token Name',
                symbol: 'TOKEN',
                tokenUri: 'https://flaunch.gg/',
                initialTokenFairLaunch: supplyShare(50),
                premineAmount: 0,
                creator: owner,
                creatorFeeAllocation: 0,
                flaunchAt: 0,
                initialPriceParams: abi.encode(''),
                feeCalculatorParams: abi.encode(1_000)
            })
        );

        // Store the memecoin information
        tokenId = flaunch.tokenId(memecoin);

        // Create some test data that we can pass
        data = abi.encode('Test initialization');
    }

    function test_approveManager() public {
        vm.expectEmit();
        emit TreasuryManagerFactory.ManagerImplementationApproved(managerImplementation);

        vm.prank(owner);
        factory.approveManager(managerImplementation);
        assertTrue(factory.approvedManagerImplementation(managerImplementation));
    }

    function test_approveManager_notOwner() public {
        vm.startPrank(nonOwner);

        vm.expectRevert(UNAUTHORIZED);
        factory.approveManager(managerImplementation);

        vm.stopPrank();
    }

    function test_unapproveManager() public {
        vm.startPrank(owner);
        factory.approveManager(managerImplementation);

        vm.expectEmit();
        emit TreasuryManagerFactory.ManagerImplementationUnapproved(managerImplementation);

        factory.unapproveManager(managerImplementation);
        vm.stopPrank();

        assertFalse(factory.approvedManagerImplementation(managerImplementation));
    }

    function test_unapproveManager_notOwner() public {
        vm.startPrank(nonOwner);

        vm.expectRevert(UNAUTHORIZED);
        factory.unapproveManager(managerImplementation);

        vm.stopPrank();
    }

    function test_unapproveManager_unknownManager() public {
        vm.startPrank(owner);

        vm.expectRevert(TreasuryManagerFactory.UnknownManagerImplemention.selector);
        factory.unapproveManager(managerImplementation);

        vm.stopPrank();
    }

    function test_deployManager() public {
        vm.startPrank(owner);
        factory.approveManager(managerImplementation);

        // We know the address in advance for this test, so we can assert the expected value
        vm.expectEmit();
        emit TreasuryManagerFactory.ManagerDeployed(0x514dd0Bcaf5994Ef889f482B79d39D18B6E4363F, managerImplementation);

        // Deploy our new manager
        address payable _manager = factory.deployManager(managerImplementation);

        // Confirm that the implementation is as expected
        assertEq(factory.managerImplementation(_manager), managerImplementation);

        // Ensure that we can initialize our manager after deployment
        flaunch.approve(_manager, tokenId);
        TreasuryManagerMock(_manager).initialize(tokenId, owner, data);
        vm.stopPrank();

        // Confirm that the manager is now the token owner
        assertEq(flaunch.ownerOf(tokenId), _manager);
    }

    function test_deployManager_notApproved() public {
        vm.expectRevert(TreasuryManagerFactory.UnknownManagerImplemention.selector);
        factory.deployManager(managerImplementation);
    }

    function test_deployManager_duplicateTokenId() public {
        vm.startPrank(owner);

        factory.approveManager(managerImplementation);
        address payable _manager = factory.deployManager(managerImplementation);

        flaunch.approve(_manager, tokenId);
        TreasuryManagerMock(_manager).initialize(tokenId, owner, data);

        vm.expectRevert();
        TreasuryManagerMock(_manager).initialize(tokenId, owner, data);

        vm.stopPrank();
    }

}
