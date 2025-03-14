// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from '@uniswap/v4-core/src/types/PoolId.sol';

import {Flaunch} from '@flaunch/Flaunch.sol';
import {PositionManager} from '@flaunch/PositionManager.sol';
import {RevenueSplitManager} from '@flaunch/treasury/managers/RevenueSplitManager.sol';
import {TreasuryManagerFactory} from '@flaunch/treasury/managers/TreasuryManagerFactory.sol';

import {ITreasuryManager} from '@flaunch-interfaces/ITreasuryManager.sol';

import {FlaunchTest} from 'test/FlaunchTest.sol';


contract RevenueSplitManagerTest is FlaunchTest {

    // The treasury manager
    RevenueSplitManager revenueSplitManager;
    address managerImplementation;

    // Some recipients to test with
    address recipient1 = address(0x2);
    address recipient2 = address(0x3);
    address recipient3 = address(0x4);
    address recipient4 = address(0x5);
    address recipient5 = address(0x6);

    // The exepected flaunch tokenId
    uint tokenId = 1;

    function setUp() public {
        _deployPlatform();
    }

    function test_CanInitializeSuccessfully() public {
        // Set up our revenue split
        RevenueSplitManager.RecipientShare[] memory recipientShares = new RevenueSplitManager.RecipientShare[](2);
        recipientShares[0] = RevenueSplitManager.RecipientShare({recipient: recipient1, share: 50_00});
        recipientShares[1] = RevenueSplitManager.RecipientShare({recipient: recipient2, share: 50_00});

        // Set up our {TreasuryManagerFactory} and approve our implementation
        _deployWithRecipients(recipientShares);

        // Confirm that the params have initialized the manager correctly
        (Flaunch _flaunch, uint _tokenId) = revenueSplitManager.flaunchToken();
        assertEq(address(_flaunch), address(flaunch));
        assertEq(_tokenId, tokenId);

        assertEq(revenueSplitManager.recipientShares(recipient1), 50_00);
        assertEq(revenueSplitManager.recipientShares(recipient2), 50_00);
        assertEq(revenueSplitManager.recipientShares(recipient3), 0);
    }

    function test_CannotInitializeWithInvalidShareTotal() public {
        // Set up our revenue split
        RevenueSplitManager.RecipientShare[] memory recipientShares = new RevenueSplitManager.RecipientShare[](2);
        recipientShares[0] = RevenueSplitManager.RecipientShare({recipient: recipient1, share: 40_00});
        recipientShares[1] = RevenueSplitManager.RecipientShare({recipient: recipient2, share: 50_00});

        _deployImplementation();

        // Set up our {TreasuryManagerFactory} and approve our implementation
        vm.expectRevert(abi.encodeWithSelector(
            RevenueSplitManager.InvalidRecipientShareTotal.selector,
            90_00, 100_00
        ));

        // Initialize our token
        revenueSplitManager.initialize({
            _flaunchToken: ITreasuryManager.FlaunchToken({
                flaunch: flaunch,
                tokenId: tokenId
            }),
            _owner: address(this),
            _data: abi.encode(
                RevenueSplitManager.InitializeParams(recipientShares)
            )
        });
    }

    function test_CannotInitializeWithZeroAddressRecipient() public {
        // Set up our revenue split
        RevenueSplitManager.RecipientShare[] memory recipientShares = new RevenueSplitManager.RecipientShare[](2);
        recipientShares[0] = RevenueSplitManager.RecipientShare({recipient: address(0), share: 50_00});
        recipientShares[1] = RevenueSplitManager.RecipientShare({recipient: recipient2, share: 50_00});

        _deployImplementation();

        // Set up our {TreasuryManagerFactory} and approve our implementation
        vm.expectRevert(RevenueSplitManager.InvalidRecipient.selector);

        // Initialize our token
        revenueSplitManager.initialize({
            _flaunchToken: ITreasuryManager.FlaunchToken({
                flaunch: flaunch,
                tokenId: tokenId
            }),
            _owner: address(this),
            _data: abi.encode(
                RevenueSplitManager.InitializeParams(recipientShares)
            )
        });
    }

    function test_CanInitializeWithMultipleRecipients() public {
        RevenueSplitManager.RecipientShare[] memory recipientShares = new RevenueSplitManager.RecipientShare[](5);
        recipientShares[0] = RevenueSplitManager.RecipientShare({recipient: recipient1, share: 30_00});
        recipientShares[1] = RevenueSplitManager.RecipientShare({recipient: recipient2, share: 25_00});
        recipientShares[2] = RevenueSplitManager.RecipientShare({recipient: recipient3, share: 20_00});
        recipientShares[3] = RevenueSplitManager.RecipientShare({recipient: recipient4, share: 15_00});
        recipientShares[4] = RevenueSplitManager.RecipientShare({recipient: recipient5, share: 10_00});

        // Set up our {TreasuryManagerFactory} and approve our implementation
        _deployWithRecipients(recipientShares);

        // Allocate ETH to the manager
        _allocateFees(10 ether);

        vm.expectEmit();
        emit RevenueSplitManager.RevenueClaimed(recipient1, 3 ether, 3 ether);

        vm.prank(recipient1);
        revenueSplitManager.claim();

        vm.expectEmit();
        emit RevenueSplitManager.RevenueClaimed(recipient2, 2.5 ether, 2.5 ether);

        vm.prank(recipient2);
        revenueSplitManager.claim();

        assertEq(address(recipient1).balance, 3 ether);
        assertEq(address(recipient2).balance, 2.5 ether);
        assertEq(address(recipient3).balance, 0);
        assertEq(address(recipient4).balance, 0);
        assertEq(address(recipient5).balance, 0);

        assertEq(revenueSplitManager.amountClaimed(recipient1), 3 ether);
        assertEq(revenueSplitManager.amountClaimed(recipient2), 2.5 ether);
        assertEq(revenueSplitManager.amountClaimed(recipient3), 0);
        assertEq(revenueSplitManager.amountClaimed(recipient4), 0);
        assertEq(revenueSplitManager.amountClaimed(recipient5), 0);

        assertEq(address(revenueSplitManager).balance, 4.5 ether);
        assertEq(revenueSplitManager.totalClaimed(), 10 ether);

        // Allocate more fees
        _allocateFees(10 ether);

        vm.prank(recipient3);
        revenueSplitManager.claim();

        vm.prank(recipient4);
        revenueSplitManager.claim();

        vm.expectEmit();
        emit RevenueSplitManager.RevenueClaimed(recipient1, 3 ether, 6 ether);

        vm.prank(recipient1);
        revenueSplitManager.claim();

        // Ensure that we cannot claim multiple times to trick the system
        vm.prank(recipient1);
        revenueSplitManager.claim();

        assertEq(address(recipient1).balance, 6 ether);
        assertEq(address(recipient2).balance, 2.5 ether);
        assertEq(address(recipient3).balance, 4 ether);
        assertEq(address(recipient4).balance, 3 ether);
        assertEq(address(recipient5).balance, 0);

        assertEq(revenueSplitManager.amountClaimed(recipient1), 6 ether);
        assertEq(revenueSplitManager.amountClaimed(recipient2), 2.5 ether);
        assertEq(revenueSplitManager.amountClaimed(recipient3), 4 ether);
        assertEq(revenueSplitManager.amountClaimed(recipient4), 3 ether);
        assertEq(revenueSplitManager.amountClaimed(recipient5), 0);

        assertEq(address(revenueSplitManager).balance, 4.5 ether);
        assertEq(revenueSplitManager.totalClaimed(), 20 ether);

        // Try and claim as the test contract, who does not have an allocation
        vm.expectRevert(RevenueSplitManager.InvalidRecipient.selector);
        revenueSplitManager.claim();
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
                initialPriceParams: abi.encode(''),
                feeCalculatorParams: abi.encode(1_000)
            })
        );

        // Get the tokenId from the memecoin address
        return flaunch.tokenId(memecoin);
    }

    function _deployWithRecipients(RevenueSplitManager.RecipientShare[] memory _recipientShares) internal {
        _deployImplementation();

        // Initialize our token
        revenueSplitManager.initialize({
            _flaunchToken: ITreasuryManager.FlaunchToken({
                flaunch: flaunch,
                tokenId: tokenId
            }),
            _owner: address(this),
            _data: abi.encode(
                RevenueSplitManager.InitializeParams(_recipientShares)
            )
        });
    }

    function _deployImplementation() internal {
        managerImplementation = address(new RevenueSplitManager(address(treasuryManagerFactory)));
        treasuryManagerFactory.approveManager(managerImplementation);

        // Get the tokenId from the memecoin address
        tokenId = _createERC721(address(this));

        // Deploy our {RevenueManager} implementation and transfer our tokenId
        address payable implementation = treasuryManagerFactory.deployManager(managerImplementation);
        flaunch.approve(implementation, tokenId);

        // Set our revenue manager
        revenueSplitManager = RevenueSplitManager(implementation);
    }

    function _allocateFees(uint _amount) internal {
        // Mint ETH to the flETH contract to facilitate unwrapping
        deal(address(this), _amount);
        WETH.deposit{value: _amount}();
        WETH.transfer(address(positionManager), _amount);

        positionManager.allocateFeesMock({
            _poolId: PoolId.wrap(bytes32('1')),  // Can be mocked to anything
            _recipient: payable(address(revenueSplitManager)),
            _amount: _amount
        });
    }
}
