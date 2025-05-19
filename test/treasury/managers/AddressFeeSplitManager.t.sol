// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from '@uniswap/v4-core/src/types/PoolId.sol';

import {Flaunch} from '@flaunch/Flaunch.sol';
import {PositionManager} from '@flaunch/PositionManager.sol';
import {FeeSplitManager} from '@flaunch/treasury/managers/FeeSplitManager.sol';
import {AddressFeeSplitManager} from '@flaunch/treasury/managers/AddressFeeSplitManager.sol';
import {TreasuryManagerFactory} from '@flaunch/treasury/managers/TreasuryManagerFactory.sol';

import {ITreasuryManager} from '@flaunch-interfaces/ITreasuryManager.sol';

import {FlaunchTest} from 'test/FlaunchTest.sol';


contract AddressFeeSplitManagerTest is FlaunchTest {

    // The treasury manager
    AddressFeeSplitManager addressFeeSplitManager;
    address managerImplementation;
    uint VALID_CREATOR_SHARE = 10_00000;

    bytes internal constant EMPTY_BYTES = abi.encode('');

    // Some recipients to test with
    address recipient1 = address(0x2);
    address recipient2 = address(0x3);
    address recipient3 = address(0x4);
    address recipient4 = address(0x5);
    address recipient5 = address(0x6);

    function setUp() public {
        _deployPlatform();

        managerImplementation = address(new AddressFeeSplitManager(address(treasuryManagerFactory)));
        treasuryManagerFactory.approveManager(managerImplementation);
    }

    function test_CanInitializeSuccessfully(uint _creatorShare) public {
        vm.assume(_creatorShare <= 100_00000);

        // Set up our revenue split
        AddressFeeSplitManager.RecipientShare[] memory recipientShares = new AddressFeeSplitManager.RecipientShare[](2);
        recipientShares[0] = AddressFeeSplitManager.RecipientShare({recipient: recipient1, share: 50_00000});
        recipientShares[1] = AddressFeeSplitManager.RecipientShare({recipient: recipient2, share: 50_00000});

        // Set up our {TreasuryManagerFactory} and approve our implementation
        _deployWithRecipients(recipientShares, _creatorShare);

        assertEq(addressFeeSplitManager.recipientShare(recipient1, EMPTY_BYTES), 50_00000);
        assertEq(addressFeeSplitManager.recipientShare(recipient2, EMPTY_BYTES), 50_00000);
        assertEq(addressFeeSplitManager.recipientShare(recipient3, EMPTY_BYTES), 0);

        assertEq(addressFeeSplitManager.creatorShare(), _creatorShare);
    }

    function test_CannotInitializeWithInvalidCreatorShare(uint _invalidShare) public {
        vm.assume(_invalidShare > 100_00000);

        // Set up our revenue split
        AddressFeeSplitManager.RecipientShare[] memory recipientShares = new AddressFeeSplitManager.RecipientShare[](2);
        recipientShares[0] = AddressFeeSplitManager.RecipientShare({recipient: recipient1, share: 50_00000});
        recipientShares[1] = AddressFeeSplitManager.RecipientShare({recipient: recipient2, share: 50_00000});

        // Initialize our token
        vm.expectRevert();
        _deployWithRecipients(recipientShares, _invalidShare);
    }

    function test_CannotInitializeWithInvalidShareTotal() public {
        // Set up our revenue split
        AddressFeeSplitManager.RecipientShare[] memory recipientShares = new AddressFeeSplitManager.RecipientShare[](2);
        recipientShares[0] = AddressFeeSplitManager.RecipientShare({recipient: recipient1, share: 40_00000});
        recipientShares[1] = AddressFeeSplitManager.RecipientShare({recipient: recipient2, share: 50_00000});

        // Set up our {TreasuryManagerFactory} and approve our implementation
        vm.expectRevert(abi.encodeWithSelector(
            FeeSplitManager.InvalidRecipientShareTotal.selector,
            90_00000, 100_00000
        ));

        // Initialize our token
        _deployWithRecipients(recipientShares, VALID_CREATOR_SHARE);
    }

    function test_CannotInitializeWithZeroAddressRecipient() public {
        // Set up our revenue split
        AddressFeeSplitManager.RecipientShare[] memory recipientShares = new AddressFeeSplitManager.RecipientShare[](2);
        recipientShares[0] = AddressFeeSplitManager.RecipientShare({recipient: address(0), share: 50_00000});
        recipientShares[1] = AddressFeeSplitManager.RecipientShare({recipient: recipient2, share: 50_00000});

        // Set up our {TreasuryManagerFactory} and approve our implementation
        vm.expectRevert(FeeSplitManager.InvalidRecipient.selector);

        // Initialize our token
        _deployWithRecipients(recipientShares, VALID_CREATOR_SHARE);
    }

    // @todo Allocate fees through a pool so we can test the creator share
    function test_CanInitializeWithMultipleRecipients() public {
        AddressFeeSplitManager.RecipientShare[] memory recipientShares = new AddressFeeSplitManager.RecipientShare[](5);
        recipientShares[0] = AddressFeeSplitManager.RecipientShare({recipient: recipient1, share: 30_00000});
        recipientShares[1] = AddressFeeSplitManager.RecipientShare({recipient: recipient2, share: 25_00000});
        recipientShares[2] = AddressFeeSplitManager.RecipientShare({recipient: recipient3, share: 20_00000});
        recipientShares[3] = AddressFeeSplitManager.RecipientShare({recipient: recipient4, share: 15_00000});
        recipientShares[4] = AddressFeeSplitManager.RecipientShare({recipient: recipient5, share: 10_00000});

        // Set up our {TreasuryManagerFactory} and approve our implementation
        _deployWithRecipients(recipientShares, 0);

        // Allocate ETH to the manager
        _allocateFees(10 ether);

        vm.expectEmit();
        emit AddressFeeSplitManager.RevenueClaimed(recipient1, 3 ether);

        vm.prank(recipient1);
        uint claimAmount = addressFeeSplitManager.claim();
        assertEq(claimAmount, 3 ether);

        vm.expectEmit();
        emit AddressFeeSplitManager.RevenueClaimed(recipient2, 2.5 ether);

        vm.prank(recipient2);
        claimAmount = addressFeeSplitManager.claim();
        assertEq(claimAmount, 2.5 ether);

        assertEq(address(recipient1).balance, 3 ether);
        assertEq(address(recipient2).balance, 2.5 ether);
        assertEq(address(recipient3).balance, 0);
        assertEq(address(recipient4).balance, 0);
        assertEq(address(recipient5).balance, 0);

        assertEq(addressFeeSplitManager.amountClaimed(recipient1), 3 ether);
        assertEq(addressFeeSplitManager.amountClaimed(recipient2), 2.5 ether);
        assertEq(addressFeeSplitManager.amountClaimed(recipient3), 0);
        assertEq(addressFeeSplitManager.amountClaimed(recipient4), 0);
        assertEq(addressFeeSplitManager.amountClaimed(recipient5), 0);

        assertEq(address(addressFeeSplitManager).balance, 4.5 ether);
        assertEq(addressFeeSplitManager.managerFees(), 10 ether);

        // Allocate more fees, but this time by a partial fee allocation and the remainder
        // being sent via a direct ETH transfer.
        _allocateFees(8 ether);
        deal(address(this), 2 ether);
        (bool _sent,) = payable(address(addressFeeSplitManager)).call{value: 2 ether}('');
        assertTrue(_sent, 'Unable to send AddressFeeSplitManager ETH');

        vm.prank(recipient3);
        addressFeeSplitManager.claim();

        vm.prank(recipient4);
        addressFeeSplitManager.claim();

        vm.expectEmit();
        emit AddressFeeSplitManager.RevenueClaimed(recipient1, 3 ether);

        vm.prank(recipient1);
        claimAmount = addressFeeSplitManager.claim();
        assertEq(claimAmount, 3 ether);

        // Ensure that we cannot claim multiple times to trick the system
        vm.prank(recipient1);
        addressFeeSplitManager.claim();

        assertEq(address(recipient1).balance, 6 ether);
        assertEq(address(recipient2).balance, 2.5 ether);
        assertEq(address(recipient3).balance, 4 ether);
        assertEq(address(recipient4).balance, 3 ether);
        assertEq(address(recipient5).balance, 0);

        assertEq(addressFeeSplitManager.amountClaimed(recipient1), 6 ether);
        assertEq(addressFeeSplitManager.amountClaimed(recipient2), 2.5 ether);
        assertEq(addressFeeSplitManager.amountClaimed(recipient3), 4 ether);
        assertEq(addressFeeSplitManager.amountClaimed(recipient4), 3 ether);
        assertEq(addressFeeSplitManager.amountClaimed(recipient5), 0);

        assertEq(address(addressFeeSplitManager).balance, 4.5 ether);
        assertEq(addressFeeSplitManager.managerFees(), 20 ether);

        // Try and claim as the test contract, who does not have an allocation
        uint zeroAllocation = addressFeeSplitManager.claim();
        assertEq(zeroAllocation, 0);
    }

    function test_CanInitializeWithCreatorShare() public {
        AddressFeeSplitManager.RecipientShare[] memory recipientShares = new AddressFeeSplitManager.RecipientShare[](4);
        recipientShares[0] = AddressFeeSplitManager.RecipientShare({recipient: recipient1, share: 30_00000});
        recipientShares[1] = AddressFeeSplitManager.RecipientShare({recipient: recipient2, share: 25_00000});
        recipientShares[2] = AddressFeeSplitManager.RecipientShare({recipient: recipient3, share: 20_00000});
        recipientShares[3] = AddressFeeSplitManager.RecipientShare({recipient: recipient4, share: 25_00000});

        // Set up our {TreasuryManagerFactory} and approve our implementation
        _deployWithRecipients(recipientShares, 20_00000);

        // Confirm that we can correctly determine the valid recipients. Only addresses that
        // have a recipient share should currently be valid.
        assertEq(addressFeeSplitManager.isValidRecipient(recipient1, EMPTY_BYTES), true, 'recipient1 not valid');
        assertEq(addressFeeSplitManager.isValidRecipient(recipient2, EMPTY_BYTES), true, 'recipient2 not valid');
        assertEq(addressFeeSplitManager.isValidRecipient(recipient3, EMPTY_BYTES), true, 'recipient3 not valid');
        assertEq(addressFeeSplitManager.isValidRecipient(recipient4, EMPTY_BYTES), true, 'recipient4 not valid');
        assertEq(addressFeeSplitManager.isValidRecipient(recipient5, EMPTY_BYTES), false, 'recipient5 not valid');
        assertEq(addressFeeSplitManager.isValidRecipient(address(this), EMPTY_BYTES), false, 'address(this) not valid');

        // Confirm the share is set
        assertEq(addressFeeSplitManager.creatorShare(), 20_00000);

        // Flaunch some tokens for a few users. We will just mint them to this address, but
        // we will then deposit them to specific recipients for our tests.
        uint tokenId1 = _createERC721(address(this));
        uint tokenId2 = _createERC721(address(this));
        uint tokenId3 = _createERC721(address(this));
        uint tokenId4 = _createERC721(address(this));

        // Set our approval for all tokens
        flaunch.setApprovalForAll(address(addressFeeSplitManager), true);

        // Deposit our tokens into the manager, with specific creators
        addressFeeSplitManager.deposit({_flaunchToken: ITreasuryManager.FlaunchToken(flaunch, tokenId1), _creator: recipient3, _data: abi.encode('')});
        addressFeeSplitManager.deposit({_flaunchToken: ITreasuryManager.FlaunchToken(flaunch, tokenId2), _creator: recipient5, _data: abi.encode('')});
        addressFeeSplitManager.deposit({_flaunchToken: ITreasuryManager.FlaunchToken(flaunch, tokenId3), _creator: recipient5, _data: abi.encode('')});
        addressFeeSplitManager.deposit({_flaunchToken: ITreasuryManager.FlaunchToken(flaunch, tokenId4), _creator: address(this), _data: abi.encode('')});

        // Confirm the tokens that are held by some of the users
        ITreasuryManager.FlaunchToken[] memory flaunchTokens;
        flaunchTokens = addressFeeSplitManager.tokens(recipient1);
        assertEq(flaunchTokens.length, 0);

        flaunchTokens = addressFeeSplitManager.tokens(recipient3);
        assertEq(flaunchTokens.length, 1);
        assertEq(flaunchTokens[0].tokenId, tokenId1);

        flaunchTokens = addressFeeSplitManager.tokens(recipient5);
        assertEq(flaunchTokens.length, 2);
        assertEq(flaunchTokens[0].tokenId, tokenId2);
        assertEq(flaunchTokens[1].tokenId, tokenId3);

        flaunchTokens = addressFeeSplitManager.tokens(address(this));
        assertEq(flaunchTokens.length, 1);
        assertEq(flaunchTokens[0].tokenId, tokenId4);

        // Confirm that we can get the creator
        assertEq(addressFeeSplitManager.creator(address(flaunch), 0), address(0));
        assertEq(addressFeeSplitManager.creator(address(flaunch), tokenId1), recipient3);
        assertEq(addressFeeSplitManager.creator(address(flaunch), tokenId2), recipient5);
        assertEq(addressFeeSplitManager.creator(address(flaunch), tokenId3), recipient5);
        assertEq(addressFeeSplitManager.creator(address(flaunch), tokenId4), address(this));

        // Allocate 10 eth through a direct transfer
        deal(address(this), 10 ether);
        (bool _sent,) = payable(address(addressFeeSplitManager)).call{value: 10 ether}('');
        assertTrue(_sent, 'Unable to send AddressFeeSplitManager ETH');

        // Confirm that we can correctly determine the valid recipients as we now have ERC721 holders
        assertEq(addressFeeSplitManager.isValidRecipient(recipient1, EMPTY_BYTES), true, 'recipient1 not valid');
        assertEq(addressFeeSplitManager.isValidRecipient(recipient2, EMPTY_BYTES), true, 'recipient2 not valid');
        assertEq(addressFeeSplitManager.isValidRecipient(recipient3, EMPTY_BYTES), true, 'recipient3 not valid');
        assertEq(addressFeeSplitManager.isValidRecipient(recipient4, EMPTY_BYTES), true, 'recipient4 not valid');
        assertEq(addressFeeSplitManager.isValidRecipient(recipient5, EMPTY_BYTES), true, 'recipient5 not valid');
        assertEq(addressFeeSplitManager.isValidRecipient(address(this), EMPTY_BYTES), true, 'address(this) not valid');

        // This should give the manager the total amount of the split and zero going to the
        // creators.
        assertEq(payable(address(addressFeeSplitManager)).balance, 10 ether);
        assertEq(addressFeeSplitManager.creatorFees(), 0);
        assertEq(addressFeeSplitManager.splitFees(), 10 ether);

        // None of the creators should have balances currently, but the recipient shares should have
        // the correct balance allocated.
        assertEq(addressFeeSplitManager.balances(recipient1), 3.0 ether);
        assertEq(addressFeeSplitManager.balances(recipient2), 2.5 ether);
        assertEq(addressFeeSplitManager.balances(recipient3), 2.0 ether);
        assertEq(addressFeeSplitManager.balances(recipient4), 2.5 ether);
        assertEq(addressFeeSplitManager.balances(recipient5), 0);
        assertEq(addressFeeSplitManager.balances(address(this)), 0);

        // Allocate some fees against the PoolId of a subset of our tokens. This will allocate fees
        // to the creators that will then be claimable by those specific creators.
        _allocatePoolFees(2 ether, tokenId1);  // recipient3
        _allocatePoolFees(2 ether, tokenId1);  // recipient3
        _allocatePoolFees(2 ether, tokenId2);  // recipient5
        _allocatePoolFees(2 ether, tokenId3);  // recipient5
        _allocatePoolFees(2 ether, tokenId4);  // address(this)

        // Allocate some fees against a PoolId that does not match the recipient. This will allocate
        // the fees against creators, but won't actually be claimable by any of the creators (leaving
        // it as dust within the contract).
        _allocatePoolFees(8 ether, 100);
        _allocatePoolFees(2 ether, 101);

        // This should give the manager updated amounts that total 30 ether from all of the fee
        // allocations that were made. The balance is currently just 10 ether as we have only
        // actually received the ETH from the direct transfer. The remaining amount is still held
        // in the FeeEscrow.
        assertEq(payable(address(addressFeeSplitManager)).balance, 10 ether, 'Invalid balance');

        // The `splitFees` will be different to the correct value, as they only show the amount that is held
        // in the manager currently. Pending fees in the {FeeEscrow} won't be shown in these calls.
        assertEq(addressFeeSplitManager.splitFees(), 10 ether, 'Invalid splitFees');

        // These functions will show both held and pending fees
        assertEq(addressFeeSplitManager.creatorFees(), 4 ether, 'Invalid creatorFees');  // 20% of 20 ether
        assertEq(addressFeeSplitManager.managerFees(), 26 ether, 'Invalid managerFees'); // 80% of 20 ether + 100% of 10 ether

        // Confirm our balances are correct
        // +--------------------------------------------------------------------+------------------+-----------------+
        // | Test                                                               | Fee Share        | Creator         |
        // +--------------------------------------------------------------------+------------------+-----------------+
        assertEq(addressFeeSplitManager.balances(recipient1), 7.8 ether);    // | 30% of 26 ether  |  0% of 4 ether  |
        assertEq(addressFeeSplitManager.balances(recipient2), 6.5 ether);    // | 25% of 26 ether  |  0% of 4 ether  |
        assertEq(addressFeeSplitManager.balances(recipient3), 6.0 ether);    // | 20% of 26 ether  | 20% of 4 ether  |
        assertEq(addressFeeSplitManager.balances(recipient4), 6.5 ether);    // | 25% of 26 ether  |  0% of 4 ether  |
        assertEq(addressFeeSplitManager.balances(recipient5), 0.8 ether);    // |  0% of 26 ether  | 20% of 4 ether  |
        assertEq(addressFeeSplitManager.balances(address(this)), 0.4 ether); // |  0% of 26 ether  | 20% of 2 ether  |
        // +--------------------------------------------------------------------+------------------+-----------------+

        // Allocate some additional pool fees
        _allocatePoolFees(5 ether, tokenId1);
        _allocatePoolFees(5 ether, tokenId2);

        // Make our claims
        uint claimAmount;
        vm.prank(recipient1);
        claimAmount = addressFeeSplitManager.claim();
        assertEq(claimAmount, 10.2 ether);

        vm.prank(recipient2);
        claimAmount = addressFeeSplitManager.claim();
        assertEq(claimAmount, 8.5 ether);

        vm.prank(recipient3);
        claimAmount = addressFeeSplitManager.claim();
        assertEq(claimAmount, 8.6 ether);

        vm.prank(recipient4);
        claimAmount = addressFeeSplitManager.claim();
        assertEq(claimAmount, 8.5 ether);

        vm.prank(recipient5);
        claimAmount = addressFeeSplitManager.claim();
        assertEq(claimAmount, 1.8 ether);

        vm.prank(address(this));
        claimAmount = addressFeeSplitManager.claim();
        assertEq(claimAmount, 0.4 ether);

        // Confirm that we have updated balances
        assertEq(addressFeeSplitManager.balances(recipient1), 0);
        assertEq(addressFeeSplitManager.balances(recipient2), 0);
        assertEq(addressFeeSplitManager.balances(recipient3), 0);
        assertEq(addressFeeSplitManager.balances(recipient4), 0);
        assertEq(addressFeeSplitManager.balances(recipient5), 0);
        assertEq(addressFeeSplitManager.balances(address(this)), 0);

        // Allocate some additional pool fees
        _allocatePoolFees(5 ether, tokenId2);
        _allocatePoolFees(5 ether, tokenId3);

        // Confirm that we have updated balances
        assertEq(addressFeeSplitManager.balances(recipient1), 2.4 ether);
        assertEq(addressFeeSplitManager.balances(recipient2), 2.0 ether);
        assertEq(addressFeeSplitManager.balances(recipient3), 1.6 ether);
        assertEq(addressFeeSplitManager.balances(recipient4), 2.0 ether);
        assertEq(addressFeeSplitManager.balances(recipient5), 2.0 ether);
        assertEq(addressFeeSplitManager.balances(address(this)), 0);

        // Confirm `tokenTotalClaimed`; this should equal 20% of 20 ether
        assertEq(addressFeeSplitManager.tokenTotalClaimed(address(flaunch), tokenId1), 1.8 ether, 'Invalid tokenId1 tokenTotalClaimed');
        assertEq(addressFeeSplitManager.tokenTotalClaimed(address(flaunch), tokenId2), 1.4 ether, 'Invalid tokenId2 tokenTotalClaimed');
        assertEq(addressFeeSplitManager.tokenTotalClaimed(address(flaunch), tokenId3), 0.4 ether, 'Invalid tokenId3 tokenTotalClaimed');
        assertEq(addressFeeSplitManager.tokenTotalClaimed(address(flaunch), tokenId4), 0.4 ether, 'Invalid tokenId4 tokenTotalClaimed');

        // Confirm `creatorTotalClaimed`; this should equal 20% of 20 ether
        assertEq(addressFeeSplitManager.creatorTotalClaimed(recipient1), 0);
        assertEq(addressFeeSplitManager.creatorTotalClaimed(recipient2), 0);
        assertEq(addressFeeSplitManager.creatorTotalClaimed(recipient3), 1.8 ether);
        assertEq(addressFeeSplitManager.creatorTotalClaimed(recipient4), 0);
        assertEq(addressFeeSplitManager.creatorTotalClaimed(recipient5), 1.8 ether);
        assertEq(addressFeeSplitManager.creatorTotalClaimed(address(this)), 0.4 ether);
    }

    function test_CanGetCreatorFee() public {
        AddressFeeSplitManager.RecipientShare[] memory recipientShares = new AddressFeeSplitManager.RecipientShare[](1);
        recipientShares[0] = AddressFeeSplitManager.RecipientShare({recipient: recipient1, share: 100_00000});

        // Set up our {TreasuryManagerFactory} and approve our implementation
        _deployWithRecipients(recipientShares, 20_00000);

        // The creator will always get a rounded up 20% value
        assertEq(addressFeeSplitManager.getCreatorFee(0), 0, 'Invalid creatorFee 1 -> 1');
        assertEq(addressFeeSplitManager.getCreatorFee(1), 1, 'Invalid creatorFee 1 -> 1');
        assertEq(addressFeeSplitManager.getCreatorFee(4), 1, 'Invalid creatorFee 4 -> 1');
        assertEq(addressFeeSplitManager.getCreatorFee(5), 1, 'Invalid creatorFee 5 -> 2');
        assertEq(addressFeeSplitManager.getCreatorFee(6), 2, 'Invalid creatorFee 6 -> 2');

        // The creator should always get 20%
        assertEq(addressFeeSplitManager.getCreatorFee(1 ether), 0.2 ether);
        assertEq(addressFeeSplitManager.getCreatorFee(2 ether), 0.4 ether);
    }

    function test_CanGetCreatorFeeWithZeroPercent() public {
        AddressFeeSplitManager.RecipientShare[] memory recipientShares = new AddressFeeSplitManager.RecipientShare[](1);
        recipientShares[0] = AddressFeeSplitManager.RecipientShare({recipient: recipient1, share: 100_00000});

        // Set up our {TreasuryManagerFactory} and approve our implementation
        _deployWithRecipients(recipientShares, 0);

        // The creator will always get zero
        assertEq(addressFeeSplitManager.getCreatorFee(1), 0);
        assertEq(addressFeeSplitManager.getCreatorFee(1 ether), 0);
        assertEq(addressFeeSplitManager.getCreatorFee(2 ether), 0);
    }

    function test_CanSplitAwkwardNumber() public {
        AddressFeeSplitManager.RecipientShare[] memory recipientShares = new AddressFeeSplitManager.RecipientShare[](4);
        recipientShares[0] = AddressFeeSplitManager.RecipientShare({recipient: recipient1, share: 1_00000});
        recipientShares[1] = AddressFeeSplitManager.RecipientShare({recipient: recipient2, share: 4_00000});
        recipientShares[2] = AddressFeeSplitManager.RecipientShare({recipient: recipient3, share: 5_00000});
        recipientShares[3] = AddressFeeSplitManager.RecipientShare({recipient: recipient4, share: 90_00000});

        // Set up our {TreasuryManagerFactory} and approve our implementation
        _deployWithRecipients(recipientShares, 0);

        // Allocate ETH to the manager
        _allocateFees(99);

        vm.prank(recipient1);
        addressFeeSplitManager.claim();

        vm.prank(recipient2);
        addressFeeSplitManager.claim();

        vm.prank(recipient3);
        addressFeeSplitManager.claim();

        vm.prank(recipient4);
        addressFeeSplitManager.claim();

        assertEq(address(recipient1).balance, 0);
        assertEq(addressFeeSplitManager.amountClaimed(recipient1), 0);

        assertEq(address(recipient2).balance, 3);
        assertEq(addressFeeSplitManager.amountClaimed(recipient2), 3);

        assertEq(address(recipient3).balance, 4);
        assertEq(addressFeeSplitManager.amountClaimed(recipient3), 4);

        assertEq(address(recipient4).balance, 89);
        assertEq(addressFeeSplitManager.amountClaimed(recipient4), 89);

        // Allocate ETH to the manager
        _allocateFees(1);

        vm.prank(recipient1);
        addressFeeSplitManager.claim();

        vm.prank(recipient2);
        addressFeeSplitManager.claim();

        vm.prank(recipient3);
        addressFeeSplitManager.claim();

        vm.prank(recipient4);
        addressFeeSplitManager.claim();

        assertEq(address(recipient1).balance, 1);
        assertEq(addressFeeSplitManager.amountClaimed(recipient1), 1);

        assertEq(address(recipient2).balance, 4);
        assertEq(addressFeeSplitManager.amountClaimed(recipient2), 4);

        assertEq(address(recipient3).balance, 5);
        assertEq(addressFeeSplitManager.amountClaimed(recipient3), 5);

        assertEq(address(recipient4).balance, 90);
        assertEq(addressFeeSplitManager.amountClaimed(recipient4), 90);
    }

    function _createERC721(address _recipient) internal returns (uint tokenId_) {
        // Flaunch another memecoin to mint a tokenId
        address memecoin = positionManager.flaunch(
            PositionManager.FlaunchParams({
                name: 'Token Name',
                symbol: 'TOKEN',
                tokenUri: 'https://flaunch.gg/',
                initialTokenFairLaunch: supplyShare(50),
                fairLaunchDuration: 30 minutes,
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

    function _deployWithRecipients(AddressFeeSplitManager.RecipientShare[] memory _recipientShares, uint _creatorShare) internal {
        // Initialize our token
        address payable manager = treasuryManagerFactory.deployAndInitializeManager({
            _managerImplementation: managerImplementation,
            _owner: address(this),
            _data: abi.encode(
                AddressFeeSplitManager.InitializeParams(_creatorShare, _recipientShares)
            )
        });

        addressFeeSplitManager = AddressFeeSplitManager(manager);
    }

    function _allocateFees(uint _amount) internal {
        // Mint ETH to the flETH contract to facilitate unwrapping
        deal(address(this), _amount);
        WETH.deposit{value: _amount}();
        WETH.transfer(address(positionManager), _amount);

        positionManager.allocateFeesMock({
            _poolId: PoolId.wrap(bytes32('1')),  // Can be mocked to anything
            _recipient: payable(address(addressFeeSplitManager)),
            _amount: _amount
        });
    }

    function _allocatePoolFees(uint _amount, uint _tokenId) internal {
        // Mint ETH to the flETH contract to facilitate unwrapping
        deal(address(this), _amount);
        WETH.deposit{value: _amount}();
        WETH.approve(address(feeEscrow), _amount);

        // Discover the PoolId from the tokenId
        PoolId poolId = addressFeeSplitManager.tokenPoolId(
            addressFeeSplitManager.flaunchTokenInternalIds(address(flaunch), _tokenId)
        );

        // Allocate our fees directly to the FeeEscrow
        feeEscrow.allocateFees({
            _poolId: poolId,
            _recipient: payable(address(addressFeeSplitManager)),
            _amount: _amount
        });
    }

}
