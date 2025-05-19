// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from '@uniswap/v4-core/src/types/PoolId.sol';

import {Flaunch} from '@flaunch/Flaunch.sol';
import {PositionManager} from '@flaunch/PositionManager.sol';
import {RevenueManager} from '@flaunch/treasury/managers/RevenueManager.sol';
import {TreasuryManagerFactory} from '@flaunch/treasury/managers/TreasuryManagerFactory.sol';
import {TreasuryManager} from '@flaunch/treasury/managers/TreasuryManager.sol';

import {ITreasuryManager} from '@flaunch-interfaces/ITreasuryManager.sol';

import {FlaunchTest} from 'test/FlaunchTest.sol';


contract RevenueManagerTest is FlaunchTest {

    /// Set our treasury manager contracts
    RevenueManager revenueManager;
    TreasuryManagerFactory factory;
    address managerImplementation;

    /// Define some useful testing addresses
    address payable internal owner = payable(address(0x123));
    address payable internal creator = payable(address(0x456));
    address payable internal protocolRecipient = payable(address(0x789));

    /// Set a default, valid protocol fee for testing
    uint internal VALID_PROTOCOL_FEE = 5_00; // 5%

    /// Set up our tokenId mapping for test reference
    uint internal tokenId;

    function setUp() public {
        // Deploy our platform
        _deployPlatform();

        managerImplementation = address(new RevenueManager(address(treasuryManagerFactory)));
        treasuryManagerFactory.approveManager(managerImplementation);

        // Deploy our {RevenueManager} implementation and initialize
        address payable implementation = treasuryManagerFactory.deployAndInitializeManager({
            _managerImplementation: managerImplementation,
            _owner: owner,
            _data: abi.encode(
                RevenueManager.InitializeParams(protocolRecipient, VALID_PROTOCOL_FEE)
            )
        });

        // Set our revenue manager
        revenueManager = RevenueManager(implementation);

        // Create a token and deposit it into our manager
        tokenId = _createERC721(address(this));
        flaunch.approve(address(revenueManager), tokenId);

        revenueManager.deposit({
            _flaunchToken: ITreasuryManager.FlaunchToken({
                flaunch: flaunch,
                tokenId: tokenId
            }),
            _creator: creator,
            _data: abi.encode('')
        });

        vm.stopPrank();
    }

    /**
     * We need to be able to initialize our {RevenueManager} with a range of parameters
     * and ensure that they are set in the contract correctly.
     */
    function test_CanInitialize(address payable _creator, address payable _protocolRecipient, uint _protocolFee) public freshManager {
        vm.assume(_protocolFee <= 100_00);
        vm.assume(_creator != address(0));

        // Flaunch another memecoin to mint a tokenId
        uint newTokenId = _createERC721(address(this));

        // Deploy our {RevenueManager} implementation and transfer our tokenId
        flaunch.approve(address(revenueManager), newTokenId);

        // Define our initialization parameters
        RevenueManager.InitializeParams memory params = RevenueManager.InitializeParams(
            _protocolRecipient, _protocolFee
        );

        vm.expectEmit();
        emit RevenueManager.ManagerInitialized(address(this), params);

        revenueManager.initialize({
            _owner: address(this),
            _data: abi.encode(params)
        });

        assertEq(revenueManager.nextInternalId(), 1);

        vm.expectEmit();
        emit TreasuryManager.TreasuryEscrowed(address(flaunch), newTokenId, _creator, address(this));
        revenueManager.deposit({
            _flaunchToken: ITreasuryManager.FlaunchToken({
                flaunch: flaunch,
                tokenId: newTokenId
            }),
            _creator: _creator,
            _data: abi.encode('')
        });

        // Confirm that the {RevenueManager} owns the ERC721
        assertEq(flaunch.ownerOf(newTokenId), address(revenueManager));

        // We need to ensure that our first internalId is not zero
        assertEq(revenueManager.flaunchTokenInternalIds(address(flaunch), newTokenId), 1);
        assertEq(revenueManager.nextInternalId(), 2);

        // Confirm that initial values are set
        assertEq(revenueManager.managerOwner(), address(this));
        assertEq(revenueManager.creator(address(flaunch), newTokenId), _creator);
        assertEq(revenueManager.protocolRecipient(), _protocolRecipient);
        assertEq(revenueManager.protocolFee(), _protocolFee);
    }

    /**
     * If the user does not own the ERC721 then they would not be able
     * to transfer it to the Manager. For this reason, trying to initialize
     * with the unowned token should revert.
     */
    function test_CannotDepositUnownedToken() public freshManager {
        vm.startPrank(address(1));

        vm.expectRevert();
        revenueManager.deposit({
            _flaunchToken: ITreasuryManager.FlaunchToken({
                flaunch: flaunch,
                tokenId: 1
            }),
            _creator: creator,
            _data: abi.encode('')
        });

        vm.stopPrank();
    }

    /**
     * The manager should be able to handle multiple tokens from multiple creators.
     */
    function test_CanInitializeWithMultipleTokens() public {
        // Flaunch multiple tokens from multiple creators
        uint tokenId1 = _createERC721(address(this));
        uint tokenId2 = _createERC721(address(this));
        uint tokenId3 = _createERC721(address(this));
        uint tokenId4 = _createERC721(address(this));

        flaunch.approve(address(revenueManager), tokenId1);
        flaunch.approve(address(revenueManager), tokenId2);
        flaunch.approve(address(revenueManager), tokenId3);
        flaunch.approve(address(revenueManager), tokenId4);

        vm.stopPrank();

        // Deposit each of our tokens to a range of user EOAs
        revenueManager.deposit({
            _flaunchToken: ITreasuryManager.FlaunchToken(flaunch, tokenId1),
            _creator: address(1),
            _data: abi.encode('')
        });

        revenueManager.deposit({
            _flaunchToken: ITreasuryManager.FlaunchToken(flaunch, tokenId2),
            _creator: address(1),
            _data: abi.encode('')
        });

        revenueManager.deposit({
            _flaunchToken: ITreasuryManager.FlaunchToken(flaunch, tokenId3),
            _creator: address(2),
            _data: abi.encode('')
        });

        revenueManager.deposit({
            _flaunchToken: ITreasuryManager.FlaunchToken(flaunch, tokenId4),
            _creator: address(3),
            _data: abi.encode('')
        });

        // Confirm our creator mappings
        assertEq(revenueManager.creator(address(flaunch), tokenId1), address(1));
        assertEq(revenueManager.creator(address(flaunch), tokenId2), address(1));
        assertEq(revenueManager.creator(address(flaunch), tokenId3), address(2));
        assertEq(revenueManager.creator(address(flaunch), tokenId4), address(3));

        // Allocate fees (3 eth total)
        _allocateFees(address(flaunch), tokenId1, 1 ether);
        _allocateFees(address(flaunch), tokenId2, 1 ether);
        _allocateFees(address(flaunch), tokenId3, 1 ether);

        // Before any claim, we have no available claim as we have not yet withdrawn
        assertEq(revenueManager.balances(revenueManager.protocolRecipient()), revenueManager.getProtocolFee(3 ether));
        assertEq(revenueManager.protocolTotalClaimed(), 0);

        // Make a claim, calling from the protocol address
        vm.prank(revenueManager.protocolRecipient());
        revenueManager.claim();

        // We should now have an increased amount of ETH and have 5% of claims as protocol
        assertEq(revenueManager.balances(revenueManager.protocolRecipient()), 0);
        assertEq(revenueManager.protocolTotalClaimed(), 0.15 ether);

        // Claim as creator 1 - pool 1
        vm.startPrank(address(1));
        ITreasuryManager.FlaunchToken[] memory flaunchTokens = new ITreasuryManager.FlaunchToken[](1);
        flaunchTokens[0] = ITreasuryManager.FlaunchToken(flaunch, tokenId1);

        revenueManager.claim(flaunchTokens);

        assertEq(revenueManager.creatorTotalClaimed(address(1)), 0.95 ether);
        assertEq(revenueManager.tokenTotalClaimed(address(flaunch), tokenId1), 0.95 ether);
        assertEq(revenueManager.tokenTotalClaimed(address(flaunch), tokenId2), 0);
        vm.stopPrank();

        // Allocate more fees
        _allocateFees(address(flaunch), tokenId3, 1 ether);

        // Confirm the creators expected balance from an external user call
        assertEq(revenueManager.balances(address(2)), 1.9 ether);

        // Claim as creator 2
        vm.startPrank(address(2));
        flaunchTokens[0] = ITreasuryManager.FlaunchToken(flaunch, tokenId3);

        // Confirm the creators expected balance and make the call without specification
        assertEq(revenueManager.balances(address(2)), 1.9 ether);

        revenueManager.claim();

        assertEq(revenueManager.creatorTotalClaimed(address(2)), 1.9 ether);
        assertEq(revenueManager.tokenTotalClaimed(address(flaunch), tokenId3), 1.9 ether);

        // The protocol now has fees from 1 ether ready to claim, and 3 ether already claimed
        assertEq(revenueManager.balances(revenueManager.protocolRecipient()), revenueManager.getProtocolFee(1 ether));
        assertEq(revenueManager.protocolTotalClaimed(), revenueManager.getProtocolFee(3 ether));
        vm.stopPrank();

        // Claim as creator 1 - pool 1 & pool 2
        vm.startPrank(address(1));
        flaunchTokens = new ITreasuryManager.FlaunchToken[](2);
        flaunchTokens[0] = ITreasuryManager.FlaunchToken(flaunch, tokenId1);
        flaunchTokens[1] = ITreasuryManager.FlaunchToken(flaunch, tokenId2);

        revenueManager.claim(flaunchTokens);

        assertEq(revenueManager.creatorTotalClaimed(address(1)), 1.9 ether);
        assertEq(revenueManager.tokenTotalClaimed(address(flaunch), tokenId1), 0.95 ether);
        assertEq(revenueManager.tokenTotalClaimed(address(flaunch), tokenId2), 0.95 ether);
        vm.stopPrank();

        // Claim as protocol
        vm.prank(revenueManager.protocolRecipient());
        revenueManager.claim();

        assertEq(revenueManager.balances(revenueManager.protocolRecipient()), 0);
        assertEq(revenueManager.protocolTotalClaimed(), revenueManager.getProtocolFee(4 ether));

        // Make an empty protocol claim
        vm.prank(revenueManager.protocolRecipient());
        revenueManager.claim();

        assertEq(revenueManager.balances(revenueManager.protocolRecipient()), 0);
        assertEq(revenueManager.protocolTotalClaimed(), revenueManager.getProtocolFee(4 ether));

        // Make an empty user claim
        vm.startPrank(address(1));
        flaunchTokens = new ITreasuryManager.FlaunchToken[](2);
        flaunchTokens[0] = ITreasuryManager.FlaunchToken(flaunch, tokenId1);
        flaunchTokens[1] = ITreasuryManager.FlaunchToken(flaunch, tokenId2);

        revenueManager.claim(flaunchTokens);

        assertEq(revenueManager.creatorTotalClaimed(address(1)), 1.9 ether);
        assertEq(revenueManager.tokenTotalClaimed(address(flaunch), tokenId1), 0.95 ether);
        assertEq(revenueManager.tokenTotalClaimed(address(flaunch), tokenId2), 0.95 ether);
        vm.stopPrank();

        // Try and make a claim without being either an owner or creator
        uint unknownClaim = revenueManager.claim();
        assertEq(unknownClaim, 0);
        /**/
    }

    /**
     * We don't allow the creator to be a zero address, so we need to ensure
     * that a call with a zero address will revert.
     */
    function test_CannotDepositWithInvalidCreator() public {

        // Flaunch another memecoin to mint a tokenId
        uint newTokenId = _createERC721(address(this));

        // Deploy our {RevenueManager} implementation and transfer our tokenId
        flaunch.approve(address(revenueManager), newTokenId);

        vm.expectRevert(RevenueManager.InvalidCreatorAddress.selector);
        revenueManager.deposit({
            _flaunchToken: ITreasuryManager.FlaunchToken({
                flaunch: flaunch,
                tokenId: newTokenId
            }),
            _creator: address(0),
            _data: abi.encode('')
        });
    }

    /**
     * A protocol fee must be a value between 0 and 100_00 to be valid,
     * so we need to ensure that other values aren't accepted.
     */
    function test_CannotInitializeWithInvalidProtocolFee(uint _protocolFee) public freshManager {
        // Assume an invalid protocol fee
        vm.assume(_protocolFee > 100_00);

        // Flaunch another memecoin to mint a tokenId
        uint newTokenId = _createERC721(address(this));

        // Deploy our {RevenueManager} implementation and transfer our tokenId
        flaunch.approve(address(revenueManager), newTokenId);

        vm.expectRevert(RevenueManager.InvalidProtocolFee.selector);
        revenueManager.initialize({
            _owner: address(this),
            _data: abi.encode(
                RevenueManager.InitializeParams(protocolRecipient, _protocolFee)
            )
        });
    }

    /**
     * The owner of the revenue manager should be able to update the protocol
     * recipient. This test ensures that the correct events are fired and that
     * the updated address is reflected on the contract.
     */
    function test_CanSetProtocolRecipient(address payable _protocolRecipient) public {
        // We only expect an event if the protocol recipient is not a zero address
        if (_protocolRecipient != address(0)) {
            vm.expectEmit();
            emit RevenueManager.ProtocolRecipientUpdated(_protocolRecipient);
        }

        // Set the new protocol recipient
        vm.prank(owner);
        revenueManager.setProtocolRecipient(_protocolRecipient);

        // Confirm that the recipient is set
        assertEq(revenueManager.protocolRecipient(), _protocolRecipient);
    }

    /**
     * The `owner` of the {RevenueManager} is defined during the `initialize`
     * call, and not the actual address that calls it. For this reason we need
     * to ensure that this test cannot set the protocol owner (as it wasn't
     * defined during the call) and any other address that is not the defined
     * `owner`.
     */
    function test_CannotSetProtocolRecipientIfNotOwner(address _caller) public {
        // Ensure that the caller is not the owner
        vm.assume(_caller != owner);

        vm.startPrank(_caller);

        vm.expectRevert(TreasuryManager.NotManagerOwner.selector);
        revenueManager.setProtocolRecipient(protocolRecipient);

        vm.stopPrank();
    }

    /**
     * The `owner` should be able to set the creator. This cannot be a zero address.
     */
    function test_CanSetCreator(address payable _creator) public {
        // Ensure the creator address is not a zero address
        vm.assume(_creator != address(0));

        vm.expectEmit();
        emit RevenueManager.CreatorUpdated(address(flaunch), tokenId, _creator);

        // Set the new creator
        vm.prank(owner);
        revenueManager.setCreator({
            _flaunchToken: ITreasuryManager.FlaunchToken({
                flaunch: flaunch,
                tokenId: tokenId
            }),
            _creator: _creator
        });

        // Confirm that the new creator is set
        assertEq(revenueManager.creator(address(flaunch), tokenId), _creator);
    }

    /**
     * If a zero address creator is set, then the call should revert.
     */
    function test_CannotSetZeroAddressCreator() public {
        // Set the new creator
        vm.prank(owner);
        vm.expectRevert(RevenueManager.InvalidCreatorAddress.selector);
        revenueManager.setCreator({
            _flaunchToken: ITreasuryManager.FlaunchToken({
                flaunch: flaunch,
                tokenId: tokenId
            }),
            _creator: payable(address(0))
        });
    }

    /**
     * The `owner` of the {RevenueManager} is defined during the `initialize`
     * call, and not the actual address that calls it. For this reason we need
     * to ensure that this test cannot set the protocol owner (as it wasn't
     * defined during the call) and any other address that is not the defined
     * `owner`.
     */
    function test_CannotSetCreatorIfNotOwner(address payable _caller) public {
        // Ensure that the caller is not the owner
        vm.assume(_caller != owner);

        vm.startPrank(_caller);

        vm.expectRevert(TreasuryManager.NotManagerOwner.selector);
        revenueManager.setCreator({
            _flaunchToken: ITreasuryManager.FlaunchToken({
                flaunch: flaunch,
                tokenId: tokenId
            }),
            _creator: _caller
        });

        vm.stopPrank();
    }

    /**
     * Inherited from the base {TreasuryManager}, the owner should be able to rescue
     * the ERC721 from the contract. This test needs to ensure that the ERC721 is
     * correctly transferred to the owner, which can then be routed however the
     * external protocol desires.
     */
    function test_CanRescueERC721(address _recipient) public {
        // Transferring to zero address would raise errors
        vm.assume(_recipient != address(0));

        // Confirm our starting owner of the ERC721 is the {RevenueManager}
        assertEq(flaunch.ownerOf(tokenId), address(revenueManager));

        // Track the reclaim event
        vm.expectEmit();
        emit TreasuryManager.TreasuryReclaimed(address(flaunch), tokenId, owner, _recipient);

        vm.prank(owner);
        revenueManager.rescue(
            ITreasuryManager.FlaunchToken(flaunch, tokenId),
            _recipient
        );

        // Confirm the recipient is now the owner
        assertEq(flaunch.ownerOf(tokenId), _recipient);
    }

    /**
     * We should have a revert if the caller tries to rescue an ERC721 that
     * is not held by the {RevenueManager}.
     */
    function test_CannotRescueUnknownERC721() public {
        vm.startPrank(owner);

        vm.expectRevert();
        revenueManager.rescue(
            ITreasuryManager.FlaunchToken(flaunch, 123),
            owner
        );

        vm.stopPrank();
    }

    /**
     * If anyone other than the owner tries to rescue a stored ERC721 then we
     * need to revert as only the owner should have permission to do this.
     */
    function test_CannotRescueERC721IfNotOwner(address _caller) public {
        // Ensure that the caller is not the owner
        vm.assume(_caller != owner);

        vm.startPrank(_caller);

        vm.expectRevert(TreasuryManager.NotManagerOwner.selector);
        revenueManager.rescue(
            ITreasuryManager.FlaunchToken(flaunch, tokenId),
            _caller
        );

        vm.stopPrank();
    }

    function test_CanGetAllCreatorTokens() public {
        address user1 = address(420);
        address user2 = address(421);
        address user3 = address(422);

        // Create a token and deposit it into our manager
        uint tokenId1 = _createERC721(user1);
        uint tokenId2 = _createERC721(user2);
        uint tokenId3 = _createERC721(user2);

        vm.startPrank(user1);
        flaunch.approve(address(revenueManager), tokenId1);

        revenueManager.deposit({
            _flaunchToken: ITreasuryManager.FlaunchToken({
                flaunch: flaunch,
                tokenId: tokenId1
            }),
            _creator: user1,
            _data: abi.encode('')
        });
        vm.stopPrank();

        vm.startPrank(user2);
        flaunch.approve(address(revenueManager), tokenId2);
        flaunch.approve(address(revenueManager), tokenId3);

        revenueManager.deposit({
            _flaunchToken: ITreasuryManager.FlaunchToken({
                flaunch: flaunch,
                tokenId: tokenId2
            }),
            _creator: user1,
            _data: abi.encode('')
        });

        revenueManager.deposit({
            _flaunchToken: ITreasuryManager.FlaunchToken({
                flaunch: flaunch,
                tokenId: tokenId3
            }),
            _creator: user2,
            _data: abi.encode('')
        });
        vm.stopPrank();

        ITreasuryManager.FlaunchToken[] memory user1Tokens = revenueManager.tokens(user1);
        ITreasuryManager.FlaunchToken[] memory user2Tokens = revenueManager.tokens(user2);
        ITreasuryManager.FlaunchToken[] memory user3Tokens = revenueManager.tokens(user3);

        assertEq(user1Tokens.length, 2);
        assertEq(user2Tokens.length, 1);
        assertEq(user3Tokens.length, 0);

        assertEq(address(user1Tokens[0].flaunch), address(flaunch));
        assertEq(user1Tokens[0].tokenId, tokenId1);
        assertEq(address(user1Tokens[1].flaunch), address(flaunch));
        assertEq(user1Tokens[1].tokenId, tokenId2);
        assertEq(address(user2Tokens[0].flaunch), address(flaunch));
        assertEq(user2Tokens[0].tokenId, tokenId3);
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

    function _allocateFees(address _flaunch, uint _tokenId, uint _amount) internal {
        // Allocate the claim. The PoolId does not matter.
        if (_amount == 0) {
            return;
        }

        // Mint ETH to the flETH contract to facilitate unwrapping
        deal(address(this), _amount);
        WETH.deposit{value: _amount}();
        WETH.transfer(address(this), _amount);

        WETH.approve(address(feeEscrow), type(uint).max);

        // Allocate our fees
        feeEscrow.allocateFees(
            revenueManager.getPoolId(ITreasuryManager.FlaunchToken(Flaunch(_flaunch), _tokenId)),
            address(revenueManager),
            _amount
        );
    }

    /**
     * Deploys a fresh {RevenueManager} so that we the tokenId won't already be set.
     */
    modifier freshManager {
        // Deploy a new {RevenueManager} implementation as we will be using a new tokenId
        revenueManager = RevenueManager(treasuryManagerFactory.deployManager(managerImplementation));

        _;
    }

}
