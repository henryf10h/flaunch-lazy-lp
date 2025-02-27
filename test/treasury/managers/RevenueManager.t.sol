// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId, PoolIdLibrary} from '@uniswap/v4-core/src/types/PoolId.sol';

import {PositionManager} from '@flaunch/PositionManager.sol';
import {TreasuryManagerFactory} from '@flaunch/treasury/managers/TreasuryManagerFactory.sol';
import {TreasuryManager} from '@flaunch/treasury/managers/TreasuryManager.sol';
import {RevenueManager} from '@flaunch/treasury/managers/RevenueManager.sol';

import {FlaunchTest} from 'test/FlaunchTest.sol';


contract RevenueManagerTest is FlaunchTest {

    /// Set our treasury manager contracts
    RevenueManager revenueManager;
    TreasuryManagerFactory factory;
    address managerImplementation;

    /// Define some useful testing addresses
    address payable internal owner = payable(address(0x123));
    address payable internal nonOwner = payable(address(0x456));
    address payable internal protocolRecipient = payable(address(0x789));

    /// Set a default, valid protocol fee for testing
    uint internal VALID_PROTOCOL_FEE = 5_00; // 5%

    /// Set up our tokenId mapping for test reference
    uint internal tokenId;

    function setUp() public {
        // Deploy our platform
        _deployPlatform();

        // Set up our {TreasuryManagerFactory} and approve our implementation
        vm.startPrank(owner);
        factory = new TreasuryManagerFactory(owner);
        managerImplementation = address(new RevenueManager(address(flaunch)));
        factory.approveManager(managerImplementation);

        // Get the tokenId from the memecoin address
        tokenId = _createERC721(owner);

        // Deploy our {RevenueManager} implementation and transfer our tokenId
        address payable implementation = factory.deployManager(managerImplementation);
        flaunch.approve(implementation, tokenId);

        // Set our revenue manager
        revenueManager = RevenueManager(implementation);

        // Initialize a testing token
        revenueManager.initialize({
            _tokenId: tokenId,
            _owner: owner,
            _data: abi.encode(
                RevenueManager.InitializeParams(nonOwner, protocolRecipient, VALID_PROTOCOL_FEE)
            )
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
            _creator, _protocolRecipient, _protocolFee
        );

        vm.expectEmit();
        emit TreasuryManager.TreasuryEscrowed(newTokenId, address(this), address(this));
        emit RevenueManager.ManagerInitialized(newTokenId, params);

        revenueManager.initialize({
            _tokenId: newTokenId,
            _owner: address(this),
            _data: abi.encode(params)
        });

        // Confirm that initial values are set
        assertEq(revenueManager.tokenId(), newTokenId);
        assertEq(revenueManager.owner(), address(this));
        assertEq(revenueManager.creator(), _creator);
        assertEq(revenueManager.protocolRecipient(), _protocolRecipient);
        assertEq(revenueManager.protocolFee(), _protocolFee);
    }

    /**
     * If the user does not own the ERC721 then they would not be able
     * to transfer it to the Manager. For this reason, trying to initialize
     * with the unowned token should revert.
     */
    function test_CannotInitializeWithUnownedToken() public freshManager {
        vm.expectRevert();
        revenueManager.initialize({
            _tokenId: 123,
            _owner: owner,
            _data: abi.encode(
                RevenueManager.InitializeParams(nonOwner, protocolRecipient, VALID_PROTOCOL_FEE)
            )
        });
    }

    /**
     * If a token is already registered to the Manager then it cannot receive
     * another as the logic does not work for more than one tokenId.
     */
    function test_CannotInitializeIfTokenIdAlreadySet() public {
        // Flaunch another memecoin to mint a tokenId
        uint newTokenId = _createERC721(address(this));

        // Deploy our {RevenueManager} implementation and transfer our tokenId
        flaunch.approve(address(revenueManager), newTokenId);

        vm.expectRevert(abi.encodeWithSelector(RevenueManager.TokenIdAlreadySet.selector, tokenId));
        revenueManager.initialize({
            _tokenId: newTokenId,
            _owner: address(this),
            _data: abi.encode(
                RevenueManager.InitializeParams(payable(address(this)), protocolRecipient, VALID_PROTOCOL_FEE)
            )
        });
    }

    /**
     * We don't allow the creator to be a zero address, so we need to ensure
     * that a call with a zero address will revert.
     */
    function test_CannotInitializeWithInvalidCreator(address payable _protocolRecipient, uint _protocolFee) public freshManager {
        vm.assume(_protocolFee <= 100_00);

        // Flaunch another memecoin to mint a tokenId
        uint newTokenId = _createERC721(address(this));

        // Deploy our {RevenueManager} implementation and transfer our tokenId
        flaunch.approve(address(revenueManager), newTokenId);

        vm.expectRevert(RevenueManager.InvalidCreatorAddress.selector);
        revenueManager.initialize({
            _tokenId: newTokenId,
            _owner: address(this),
            _data: abi.encode(
                RevenueManager.InitializeParams(payable(address(0)), _protocolRecipient, _protocolFee)
            )
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
            _tokenId: newTokenId,
            _owner: address(this),
            _data: abi.encode(
                RevenueManager.InitializeParams(payable(address(this)), protocolRecipient, _protocolFee)
            )
        });
    }

    /**
     * A claim should be able to split revenue between an end-owner creator and
     * an optional protocol. This test needs to ensure this optional split as
     * well as varied protocol fee amounts.
     */
    function test_CanClaim() public {
        /**
         * Protocol fee:       0%
         * Protocol recipient: true
         */

         _assertClaimAmounts({
            protocolFee: 0,
            protocolRecipientSet: true,
            claimAmount: 1 ether,
            creatorAmount: 1 ether,
            protocolAmount: 0
        });

        /**
         * Protocol fee:       100%
         * Protocol recipient: true
         */

         _assertClaimAmounts({
            protocolFee: 100_00,
            protocolRecipientSet: true,
            claimAmount: 1 ether,
            creatorAmount: 0,
            protocolAmount: 1 ether
        });

        /**
         * Protocol fee:       50%
         * Protocol recipient: true
         */

         _assertClaimAmounts({
            protocolFee: 50_00,
            protocolRecipientSet: true,
            claimAmount: 1 ether,
            creatorAmount: 0.5 ether,
            protocolAmount: 0.5 ether
        });

        /**
         * Protocol fee:       50%
         * Protocol recipient: false
         */

         _assertClaimAmounts({
            protocolFee: 50_00,
            protocolRecipientSet: false,
            claimAmount: 1 ether,
            creatorAmount: 1 ether,
            protocolAmount: 0
        });

        /**
         * Protocol fee:       50%
         * Protocol recipient: true
         *
         * @dev If the value is indivisible, then the creator benefits.
         */

         _assertClaimAmounts({
            protocolFee: 50_00,
            protocolRecipientSet: true,
            claimAmount: 3,
            creatorAmount: 2,
            protocolAmount: 1
        });
    }

    /**
     * When revenue is claimed, we want to record running, onchain totals for the claim
     * amounts of both the end-owner creator and the protocol. This test needs to ensure that
     * both of these values are tracked correctly.
     */
    function test_CanTrackClaimedFees() public {
        // Set a protocol recipient and set the fee to 25% for the protocol
        vm.startPrank(owner);
        revenueManager.setProtocolFee(25_00);
        revenueManager.setProtocolRecipient(protocolRecipient);
        vm.stopPrank();

        _assertClaimTotals(1 ether, 0.75 ether, 0.25 ether);
        _assertClaimTotals(0.4 ether, 1.05 ether, 0.35 ether);
        _assertClaimTotals(0.2 ether, 1.2 ether, 0.4 ether);

        // Increase the protocol fee
        vm.prank(owner);
        revenueManager.setProtocolFee(100_00);

        _assertClaimTotals(1 ether, 1.2 ether, 1.4 ether);

        // Remove the protocol recipient
        vm.prank(owner);
        revenueManager.setProtocolRecipient(payable(address(0)));

        _assertClaimTotals(0.55 ether, 1.75 ether, 1.4 ether);
    }

    /**
     * Claim calls should be able to be made, even if there is nothing to claim.
     * This test needs to ensure that the call doesn't revert, but instead just
     * returns zero values.
     */
    function test_CanClaimZeroFees() public {
        (uint creatorAmount, uint protocolAmount) = revenueManager.claim();
        assertEq(creatorAmount, 0);
        assertEq(protocolAmount, 0);
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

        vm.expectRevert(UNAUTHORIZED);
        revenueManager.setProtocolRecipient(protocolRecipient);

        vm.stopPrank();
    }

    /**
     * The `owner` should be able to set the protocol fee. This value must
     * fall within a valid value range.
     */
    function test_CanSetProtocolFee(uint _protocolFee) public {
        // Ensure the protocol fee is within a valid range
        vm.assume(_protocolFee <= 100_00);

        vm.expectEmit();
        emit RevenueManager.ProtocolFeeUpdated(_protocolFee);

        // Set the new protocol fee
        vm.prank(owner);
        revenueManager.setProtocolFee(_protocolFee);

        // Confirm that the new fee is set
        assertEq(revenueManager.protocolFee(), _protocolFee);
    }

    /**
     * If a protocol fee over 100% is set, then the call should revert.
     */
    function test_CannotSetInvalidProtocolFee(uint _protocolFee) public {
        // Ensure that the protocol fee is invalid
        vm.assume(_protocolFee > 100_00);

        // Set the new protocol fee
        vm.prank(owner);
        vm.expectRevert(RevenueManager.InvalidProtocolFee.selector);
        revenueManager.setProtocolFee(_protocolFee);
    }

    /**
     * The `owner` of the {RevenueManager} is defined during the `initialize`
     * call, and not the actual address that calls it. For this reason we need
     * to ensure that this test cannot set the protocol owner (as it wasn't
     * defined during the call) and any other address that is not the defined
     * `owner`.
     */
    function test_CannotSetProtocolFeeIfNotOwner(address _caller) public {
        // Ensure that the caller is not the owner
        vm.assume(_caller != owner);

        vm.startPrank(_caller);

        vm.expectRevert(UNAUTHORIZED);
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
        emit RevenueManager.CreatorUpdated(_creator);

        // Set the new creator
        vm.prank(owner);
        revenueManager.setCreator(_creator);

        // Confirm that the new creator is set
        assertEq(revenueManager.creator(), _creator);
    }

    /**
     * If a zero address creator is set, then the call should revert.
     */
    function test_CannotSetZeroAddressCreator() public {
        // Set the new creator
        vm.prank(owner);
        vm.expectRevert(RevenueManager.InvalidCreatorAddress.selector);
        revenueManager.setCreator(payable(address(0)));
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

        vm.expectRevert(UNAUTHORIZED);
        revenueManager.setCreator(_caller);

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
        emit TreasuryManager.TreasuryReclaimed(tokenId, owner, _recipient);

        vm.prank(owner);
        revenueManager.rescue(tokenId, _recipient);

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
        revenueManager.rescue(123, owner);

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

        vm.expectRevert(UNAUTHORIZED);
        revenueManager.rescue(tokenId, _caller);

        vm.stopPrank();
    }

    /**
     * If we rescue an ERC721 we need to ensure that another token cannot be added to take it's
     * place as this could result in corrupted data. This is true even if the same token tries to
     * be added back in.
     */
    function test_CannotAddNewERC721AfterRescue() public {
        vm.prank(owner);
        revenueManager.rescue(tokenId, address(this));

        flaunch.approve(address(revenueManager), tokenId);
        vm.expectRevert(abi.encodeWithSelector(RevenueManager.TokenIdAlreadySet.selector, tokenId));
        revenueManager.initialize({
            _tokenId: tokenId,
            _owner: address(this),
            _data: abi.encode(
                RevenueManager.InitializeParams(payable(address(this)), protocolRecipient, VALID_PROTOCOL_FEE)
            )
        });
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

    function _assertClaimAmounts(
        uint protocolFee,
        bool protocolRecipientSet,
        uint claimAmount,
        uint creatorAmount,
        uint protocolAmount
    ) internal {
        // Allocate the claim. The PoolId does not matter.
        if (claimAmount != 0) {
            // Mint ETH to the flETH contract to facilitate unwrapping
            deal(address(this), claimAmount);
            WETH.deposit{value: claimAmount}();
            WETH.transfer(address(positionManager), claimAmount);

            // Allocate our fees
            positionManager.allocateFeesMock(PoolId.wrap('test'), address(revenueManager), claimAmount);
        }

        // Set our protocol recipient and fee
        vm.startPrank(owner);
        revenueManager.setProtocolFee(protocolFee);
        revenueManager.setProtocolRecipient(protocolRecipientSet ? protocolRecipient : payable(address(0)));
        vm.stopPrank();

        vm.expectEmit();
        emit RevenueManager.RevenueClaimed({
            _creator: nonOwner,
            _creatorAmount: creatorAmount,
            _creatorSuccess: true,
            _protocol: protocolRecipientSet ? protocolRecipient : payable(address(0)),
            _protocolAmount: protocolAmount,
            _protocolSuccess: protocolAmount != 0
        });

        // Execute our claim
        (uint creatorClaim, uint protocolClaim) = revenueManager.claim();

        // Assert the returned claim amounts
        assertEq(creatorAmount, creatorClaim);
        assertEq(protocolAmount, protocolClaim);
    }

    function _assertClaimTotals(uint claimAmount, uint creatorTotal, uint protocolTotal) internal {
        // Mint ETH to the flETH contract to facilitate unwrapping
        deal(address(this), claimAmount);
        WETH.deposit{value: claimAmount}();
        WETH.transfer(address(positionManager), claimAmount);

        // Allocate the claim. The PoolId does not matter.
        positionManager.allocateFeesMock(PoolId.wrap('test'), address(revenueManager), claimAmount);

        // Execute our claim
        revenueManager.claim();

        // Assert the returned claim amounts
        assertEq(revenueManager.creatorTotalClaim(), creatorTotal);
        assertEq(revenueManager.protocolTotalClaim(), protocolTotal);
    }

    /**
     * Deploys a fresh {RevenueManager} so that we the tokenId won't already be set.
     */
    modifier freshManager {
        // Deploy a new {RevenueManager} implementation as we will be using a new tokenId
        revenueManager = RevenueManager(factory.deployManager(managerImplementation));

        _;
    }

}
