// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import 'forge-std/console.sol';

import {PoolId} from '@uniswap/v4-core/src/types/PoolId.sol';

import {Flaunch} from '@flaunch/Flaunch.sol';
import {PositionManager} from '@flaunch/PositionManager.sol';
import {FeeSplitManager} from '@flaunch/treasury/managers/FeeSplitManager.sol';
import {ERC721OwnerFeeSplitManager} from '@flaunch/treasury/managers/ERC721OwnerFeeSplitManager.sol';
import {TreasuryManagerFactory} from '@flaunch/treasury/managers/TreasuryManagerFactory.sol';

import {ITreasuryManager} from '@flaunch-interfaces/ITreasuryManager.sol';

import {ERC721Mock} from 'test/mocks/ERC721Mock.sol';
import {FlaunchTest} from 'test/FlaunchTest.sol';


contract ERC721OwnerFeeSplitManagerTest is FlaunchTest {

    // The treasury manager
    ERC721OwnerFeeSplitManager feeSplitManager;
    address managerImplementation;

    bytes constant EMPTY_BYTES = abi.encode('');

    // Set up some ERC721Mock contracts
    ERC721Mock erc1;
    ERC721Mock erc2;
    ERC721Mock erc3;

    function setUp() public {
        _deployPlatform();

        erc1 = new ERC721Mock('ERC1', '1');
        erc2 = new ERC721Mock('ERC2', '2');
        erc3 = new ERC721Mock('ERC3', '3');

        managerImplementation = address(
            new ERC721OwnerFeeSplitManager(address(treasuryManagerFactory))
        );

        treasuryManagerFactory.approveManager(managerImplementation);
    }

    function test_CanInitializeSuccessfully() public {
        // Set up our revenue split
        ERC721OwnerFeeSplitManager.ERC721Share[] memory recipientShares = new ERC721OwnerFeeSplitManager.ERC721Share[](3);
        recipientShares[0] = ERC721OwnerFeeSplitManager.ERC721Share(address(erc1), 20_00000, 10);
        recipientShares[1] = ERC721OwnerFeeSplitManager.ERC721Share(address(erc2), 50_00000, 10);
        recipientShares[2] = ERC721OwnerFeeSplitManager.ERC721Share(address(erc3), 30_00000, 20);

        // Set up our {TreasuryManagerFactory} and approve our implementation
        _deployWithRecipients(recipientShares);

        (address erc721, uint share, uint totalSupply) = feeSplitManager.erc721Shares(address(erc1));
        assertEq(erc721, address(erc1));
        assertEq(share, 20_00000);
        assertEq(totalSupply, 10);

        (erc721, share, totalSupply) = feeSplitManager.erc721Shares(address(erc2));
        assertEq(erc721, address(erc2));
        assertEq(share, 50_00000);
        assertEq(totalSupply, 10);

        (erc721, share, totalSupply) = feeSplitManager.erc721Shares(address(erc3));
        assertEq(erc721, address(erc3));
        assertEq(share, 30_00000);
        assertEq(totalSupply, 20);

        (erc721, share, totalSupply) = feeSplitManager.erc721Shares(address(1));
        assertEq(erc721, address(0));
        assertEq(share, 0);
        assertEq(totalSupply, 0);
    }

    function test_CannotInitializeWithInvalidShareTotal() public {
        // Set up our revenue split
        ERC721OwnerFeeSplitManager.ERC721Share[] memory recipientShares = new ERC721OwnerFeeSplitManager.ERC721Share[](3);
        recipientShares[0] = ERC721OwnerFeeSplitManager.ERC721Share(address(erc1), 20_00000, 10);
        recipientShares[1] = ERC721OwnerFeeSplitManager.ERC721Share(address(erc2), 40_00000, 10);
        recipientShares[2] = ERC721OwnerFeeSplitManager.ERC721Share(address(erc3), 30_00000, 20);

        // Set up our {TreasuryManagerFactory} and approve our implementation
        vm.expectRevert(abi.encodeWithSelector(
            FeeSplitManager.InvalidRecipientShareTotal.selector,
            90_00000, 100_00000
        ));

        // Initialize our token
        _deployWithRecipients(recipientShares);
    }

    function test_CannotInitializeWithZeroAddressRecipient() public {
        // Set up our revenue split
        ERC721OwnerFeeSplitManager.ERC721Share[] memory recipientShares = new ERC721OwnerFeeSplitManager.ERC721Share[](3);
        recipientShares[0] = ERC721OwnerFeeSplitManager.ERC721Share(address(erc1), 20_00000, 10);
        recipientShares[1] = ERC721OwnerFeeSplitManager.ERC721Share(address(erc2), 50_00000, 10);
        recipientShares[2] = ERC721OwnerFeeSplitManager.ERC721Share(address(0), 30_00000, 20);

        // Set up our {TreasuryManagerFactory} and approve our implementation
        vm.expectRevert(ERC721OwnerFeeSplitManager.InvalidInitializeParams.selector);

        // Initialize our token
        _deployWithRecipients(recipientShares);
    }

    function test_CannotInitializeWithZeroShareRecipient() public {
        // Set up our revenue split
        ERC721OwnerFeeSplitManager.ERC721Share[] memory recipientShares = new ERC721OwnerFeeSplitManager.ERC721Share[](3);
        recipientShares[0] = ERC721OwnerFeeSplitManager.ERC721Share(address(erc1), 20_00000, 10);
        recipientShares[1] = ERC721OwnerFeeSplitManager.ERC721Share(address(erc2), 50_00000, 10);
        recipientShares[2] = ERC721OwnerFeeSplitManager.ERC721Share(address(erc3), 0, 20);

        // Set up our {TreasuryManagerFactory} and approve our implementation
        vm.expectRevert(ERC721OwnerFeeSplitManager.InvalidInitializeParams.selector);

        // Initialize our token
        _deployWithRecipients(recipientShares);
    }

    function test_CannotInitializeWithZeroTotalSupplyRecipient() public {
        // Set up our revenue split
        ERC721OwnerFeeSplitManager.ERC721Share[] memory recipientShares = new ERC721OwnerFeeSplitManager.ERC721Share[](3);
        recipientShares[0] = ERC721OwnerFeeSplitManager.ERC721Share(address(erc1), 20_00000, 0);
        recipientShares[1] = ERC721OwnerFeeSplitManager.ERC721Share(address(erc2), 50_00000, 10);
        recipientShares[2] = ERC721OwnerFeeSplitManager.ERC721Share(address(erc3), 30_00000, 20);

        // Set up our {TreasuryManagerFactory} and approve our implementation
        vm.expectRevert(ERC721OwnerFeeSplitManager.InvalidInitializeParams.selector);

        // Initialize our token
        _deployWithRecipients(recipientShares);
    }

    function test_CanInitializeWithMultipleRecipients() public {
        ERC721OwnerFeeSplitManager.ERC721Share[] memory recipientShares = new ERC721OwnerFeeSplitManager.ERC721Share[](3);
        recipientShares[0] = ERC721OwnerFeeSplitManager.ERC721Share(address(erc1), 20_00000, 10);
        recipientShares[1] = ERC721OwnerFeeSplitManager.ERC721Share(address(erc2), 50_00000, 10);
        recipientShares[2] = ERC721OwnerFeeSplitManager.ERC721Share(address(erc3), 30_00000, 20);

        // Set up our {TreasuryManagerFactory} and approve our implementation
        _deployWithRecipients(recipientShares);

        // Mint some NFTs to our user
        erc1.mint(address(this), 0);
        erc1.mint(address(this), 1);
        erc2.mint(address(this), 0);
        erc3.mint(address(this), 0);

        // Allocate ETH to the manager
        _allocateFees(10 ether);

        // Build a claim of all our tokens
        address[] memory claimErc721 = new address[](3);
        claimErc721[0] = address(erc1);
        claimErc721[1] = address(erc2);
        claimErc721[2] = address(erc3);

        uint[][] memory claimTokenIds = new uint[][](3);
        claimTokenIds[0] = new uint[](2);
        claimTokenIds[0][0] = 0;
        claimTokenIds[0][1] = 1;
        claimTokenIds[1] = new uint[](1);
        claimTokenIds[1][0] = 0;
        claimTokenIds[2] = new uint[](1);
        claimTokenIds[2][0] = 0;

        feeSplitManager.claim(
            abi.encode(
                ERC721OwnerFeeSplitManager.ClaimParams(claimErc721, claimTokenIds)
            )
        );

        // Our manager should hold 10 ether, minus the creator fee
        assertEq(payable(address(feeSplitManager)).balance, 9.16 ether);

        // As the creator, we have taken a percentage (todo: check this)
        assertEq(payable(address(this)).balance, 0.84 ether);

        // Confirm the total fees available for each side
        assertEq(feeSplitManager.creatorFees(), 2 ether, 'Invalid creatorFees');
        assertEq(feeSplitManager.managerFees(), 8 ether, 'Invalid managerFees');

        assertEq(feeSplitManager.amountClaimed(address(erc1), 0), 160000000000000000);
        assertEq(feeSplitManager.amountClaimed(address(erc1), 1), 160000000000000000);
        assertEq(feeSplitManager.amountClaimed(address(erc1), 2), 0);
        assertEq(feeSplitManager.amountClaimed(address(erc2), 0), 400000000000000000);
        assertEq(feeSplitManager.amountClaimed(address(erc2), 1), 0);
        assertEq(feeSplitManager.amountClaimed(address(erc3), 0), 120000000000000000);
        assertEq(feeSplitManager.amountClaimed(address(erc3), 1), 0);

        // Mint a new NFT and make a claim against an existing and a new
        erc2.mint(address(this), 1);

        // Build a claim of a subset of tokens
        claimErc721 = new address[](1);
        claimErc721[0] = address(erc2);

        claimTokenIds = new uint[][](1);
        claimTokenIds[0] = new uint[](2);
        claimTokenIds[0][0] = 0; // Already claimed
        claimTokenIds[0][1] = 1; // Not yet claimed

        feeSplitManager.claim(
            abi.encode(
                ERC721OwnerFeeSplitManager.ClaimParams(claimErc721, claimTokenIds)
            )
        );

        assertEq(payable(address(feeSplitManager)).balance, 8.76 ether);
        assertEq(payable(address(this)).balance, 1.24 ether);

        assertEq(feeSplitManager.creatorFees(), 2 ether, 'Invalid creatorFees');
        assertEq(feeSplitManager.managerFees(), 8 ether, 'Invalid managerFees');

        assertEq(feeSplitManager.amountClaimed(address(erc1), 0), 0.16 ether);
        assertEq(feeSplitManager.amountClaimed(address(erc1), 1), 0.16 ether);
        assertEq(feeSplitManager.amountClaimed(address(erc1), 2), 0);
        assertEq(feeSplitManager.amountClaimed(address(erc2), 0), 0.4 ether);
        assertEq(feeSplitManager.amountClaimed(address(erc2), 1), 0.4 ether);
        assertEq(feeSplitManager.amountClaimed(address(erc3), 0), 0.12 ether);
        assertEq(feeSplitManager.amountClaimed(address(erc3), 1), 0);

        // Allocate more fees. Since `deal` will overwrite the balance held, we just want
        // to increase the balance by 2 ether so that we can continue to monitor change.
        _allocateFees(8 ether);
        deal(address(this), payable(address(this)).balance + 2 ether);
        (bool _sent,) = payable(address(feeSplitManager)).call{value: 2 ether}('');
        assertTrue(_sent, 'Unable to send FeeSplitManager ETH');

        feeSplitManager.claim(
            abi.encode(
                ERC721OwnerFeeSplitManager.ClaimParams(claimErc721, claimTokenIds)
            )
        );

        assertEq(payable(address(feeSplitManager)).balance, 17.92 ether, 'a');
        assertEq(payable(address(this)).balance, 0.84 ether, 'b');

        assertEq(feeSplitManager.creatorFees(), 3.6 ether, 'Invalid creatorFees');
        assertEq(feeSplitManager.managerFees(), 16.4 ether, 'Invalid managerFees');

        assertEq(feeSplitManager.amountClaimed(address(erc1), 0), 0.16 ether);
        assertEq(feeSplitManager.amountClaimed(address(erc1), 1), 0.16 ether);
        assertEq(feeSplitManager.amountClaimed(address(erc1), 2), 0);
        assertEq(feeSplitManager.amountClaimed(address(erc2), 0), 0.82 ether);
        assertEq(feeSplitManager.amountClaimed(address(erc2), 1), 0.82 ether);
        assertEq(feeSplitManager.amountClaimed(address(erc3), 0), 0.12 ether);
        assertEq(feeSplitManager.amountClaimed(address(erc3), 1), 0);
    }

    function test_CanGenerateCode() public pure {
        // Build a claim of all our tokens
        address[] memory claimErc721 = new address[](1);
        claimErc721[0] = 0x4D0aa036c067B82961fc739774B6a3EA0D7Fc945;

        uint[][] memory claimTokenIds = new uint[][](1);
        claimTokenIds[0] = new uint[](2);
        claimTokenIds[0][0] = 7;
        claimTokenIds[0][1] = 8;

        // Twade  : 0x00000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000040000000000000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000000000000000000000010000000000000000000000004d0aa036c067b82961fc739774b6a3ea0d7fc94500000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000000500000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000030000000000000000000000000000000000000000000000000000000000000004
        // Caps 1 : 0x00000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000040000000000000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000000000000000000000010000000000000000000000004d0aa036c067b82961fc739774b6a3ea0d7fc945000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000003000000000000000000000000000000000000000000000000000000000000000500000000000000000000000000000000000000000000000000000000000000060000000000000000000000000000000000000000000000000000000000000007
        // Caps 2 : 0x00000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000040000000000000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000000000000000000000010000000000000000000000004d0aa036c067b82961fc739774b6a3ea0d7fc94500000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000070000000000000000000000000000000000000000000000000000000000000008

        console.logBytes(
            abi.encode(
                ERC721OwnerFeeSplitManager.ClaimParams(claimErc721, claimTokenIds)
            )
        );
    }

    function test_ValidateClaimParamsHandlesInvalidCases() public {
        // Setup the manager with valid share configuration
        ERC721OwnerFeeSplitManager.ERC721Share[] memory recipientShares = new ERC721OwnerFeeSplitManager.ERC721Share[](3);
        recipientShares[0] = ERC721OwnerFeeSplitManager.ERC721Share(address(erc1), 20_00000, 10);
        recipientShares[1] = ERC721OwnerFeeSplitManager.ERC721Share(address(erc2), 50_00000, 10);
        recipientShares[2] = ERC721OwnerFeeSplitManager.ERC721Share(address(erc3), 30_00000, 20);
        _deployWithRecipients(recipientShares);

        // Mint some NFTs
        erc1.mint(address(this), 1);
        erc1.mint(address(this), 2);
        erc2.mint(address(this), 1);

        // Test case 1: Different array lengths of erc721 and tokenIds fails
        address[] memory erc721s = new address[](2);
        erc721s[0] = address(erc1);
        erc721s[1] = address(erc2);

        uint[][] memory tokenIds = new uint[][](1);
        tokenIds[0] = new uint[](1);
        tokenIds[0][0] = 1;

        bytes memory invalidParams = abi.encode(
            ERC721OwnerFeeSplitManager.ClaimParams(erc721s, tokenIds)
        );

        vm.expectRevert(ERC721OwnerFeeSplitManager.InvalidClaimParams.selector);
        feeSplitManager.isValidRecipient(address(this), invalidParams);

        // Test case 2: Duplicate tokenId in the same erc721 in the ClaimParams fails
        erc721s = new address[](1);
        erc721s[0] = address(erc1);

        tokenIds = new uint[][](1);
        tokenIds[0] = new uint[](2);
        tokenIds[0][0] = 1;
        tokenIds[0][1] = 1; // Duplicate tokenId

        invalidParams = abi.encode(
            ERC721OwnerFeeSplitManager.ClaimParams(erc721s, tokenIds)
        );

        vm.expectRevert(abi.encodeWithSelector(
            ERC721OwnerFeeSplitManager.DuplicateTokenId.selector,
            address(erc1),
            1
        ));
        feeSplitManager.isValidRecipient(address(this), invalidParams);

        // Test case 3: Duplicate erc721 with the same tokenId in the ClaimParams fails
        erc721s = new address[](2);
        erc721s[0] = address(erc1);
        erc721s[1] = address(erc1); // Duplicate ERC721 address

        tokenIds = new uint[][](2);
        tokenIds[0] = new uint[](1);
        tokenIds[0][0] = 1;
        tokenIds[1] = new uint[](1);
        tokenIds[1][0] = 1; // Same tokenId as before

        invalidParams = abi.encode(
            ERC721OwnerFeeSplitManager.ClaimParams(erc721s, tokenIds)
        );

        vm.expectRevert(abi.encodeWithSelector(
            ERC721OwnerFeeSplitManager.DuplicateTokenId.selector,
            address(erc1),
            1
        ));
        feeSplitManager.isValidRecipient(address(this), invalidParams);

        // Test case 4: Duplicate erc721 with different tokenId in ClaimParams passes
        erc721s = new address[](2);
        erc721s[0] = address(erc1);
        erc721s[1] = address(erc1); // Duplicate ERC721 address

        tokenIds = new uint[][](2);
        tokenIds[0] = new uint[](1);
        tokenIds[0][0] = 1;
        tokenIds[1] = new uint[](1);
        tokenIds[1][0] = 2; // Different tokenId

        bytes memory validParams = abi.encode(
            ERC721OwnerFeeSplitManager.ClaimParams(erc721s, tokenIds)
        );

        // This should pass validation but fail because we don't own the NFTs
        assertFalse(feeSplitManager.isValidRecipient(address(0x123), validParams));

        // Let's verify more thoroughly that it passed validation by checking with a real owner
        bool result = feeSplitManager.isValidRecipient(address(this), validParams);
        
        // Should be true since the validation passed and we're the owner of both tokens
        assertTrue(result);

        // Test case 5: Empty erc721 array should fail
        erc721s = new address[](0);
        tokenIds = new uint[][](0);

        invalidParams = abi.encode(
            ERC721OwnerFeeSplitManager.ClaimParams(erc721s, tokenIds)
        );

        vm.expectRevert(ERC721OwnerFeeSplitManager.InvalidClaimParams.selector);
        feeSplitManager.isValidRecipient(address(this), invalidParams);
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

    function _deployWithRecipients(ERC721OwnerFeeSplitManager.ERC721Share[] memory _recipientShares) internal {
        // Initialize our token
        address payable manager = treasuryManagerFactory.deployAndInitializeManager({
            _managerImplementation: managerImplementation,
            _owner: address(this),
            _data: abi.encode(
                ERC721OwnerFeeSplitManager.InitializeParams(20_00000, _recipientShares)
            )
        });

        feeSplitManager = ERC721OwnerFeeSplitManager(manager);
    }

    function _allocateFees(uint _amount) internal {
        // Mint ETH to the flETH contract to facilitate unwrapping
        deal(address(this), _amount);
        WETH.deposit{value: _amount}();
        WETH.transfer(address(positionManager), _amount);

        positionManager.allocateFeesMock({
            _poolId: PoolId.wrap(bytes32('1')),  // Can be mocked to anything
            _recipient: payable(address(feeSplitManager)),
            _amount: _amount
        });
    }

    function _allocatePoolFees(uint _amount, uint _tokenId) internal {
        // Mint ETH to the flETH contract to facilitate unwrapping
        deal(address(this), _amount);
        WETH.deposit{value: _amount}();
        WETH.approve(address(feeEscrow), _amount);

        // Discover the PoolId from the tokenId
        PoolId poolId = feeSplitManager.tokenPoolId(
            feeSplitManager.flaunchTokenInternalIds(address(flaunch), _tokenId)
        );

        // Allocate our fees directly to the FeeEscrow
        feeEscrow.allocateFees({
            _poolId: poolId,
            _recipient: payable(address(feeSplitManager)),
            _amount: _amount
        });
    }

}
