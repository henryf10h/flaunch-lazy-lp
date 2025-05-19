// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IL2ToL2CrossDomainMessenger} from "@optimism/interfaces/L2/IL2ToL2CrossDomainMessenger.sol";
import {Predeploys} from '@optimism/src/libraries/Predeploys.sol';

import {Flaunch} from '@flaunch/Flaunch.sol';
import {PositionManager} from '@flaunch/PositionManager.sol';

import {IMemecoin} from '@flaunch-interfaces/IMemecoin.sol';

import {FlaunchTest} from './FlaunchTest.sol';


contract FlaunchBridgeTest is FlaunchTest {

    /// This will be the token ID of the flaunched token
    uint TOKEN_ID = 1;

    /// Define an alternative chain
    uint INITIAL_CHAIN_ID = 1;
    uint ALTERNATIVE_CHAIN_ID = 420691337;

    /// The memecoin used for testing
    IMemecoin internal memecoin;

    function setUp() public {
        _deployPlatform();

        // Set our default chainId
        INITIAL_CHAIN_ID = block.chainid;

        // Mock our messenger send to prevent errors
        vm.mockCall(
            Predeploys.L2_TO_L2_CROSS_DOMAIN_MESSENGER,
            abi.encodeWithSelector(IL2ToL2CrossDomainMessenger.sendMessage.selector),
            abi.encode('')
        );

        vm.mockCall(
            Predeploys.L2_TO_L2_CROSS_DOMAIN_MESSENGER,
            abi.encodeWithSelector(IL2ToL2CrossDomainMessenger.crossDomainMessageSource.selector),
            abi.encode(uint(123))
        );

        // Deploy a memecoin through flaunching
        address memecoinAddress = positionManager.flaunch(
            PositionManager.FlaunchParams({
                name: 'Token Name',
                symbol: 'TOKEN',
                tokenUri: 'https://flaunch.gg/',
                initialTokenFairLaunch: supplyShare(50),
                fairLaunchDuration: 30 minutes,
                premineAmount: 0,
                creator: address(this),
                creatorFeeAllocation: 50_00,
                flaunchAt: 0,
                initialPriceParams: abi.encode(''),
                feeCalculatorParams: abi.encode(1_000)
            })
        );

        // Cast our address to a memecoin we can reference in tests
        memecoin = IMemecoin(memecoinAddress);
    }

    function test_CanInitializeBridge_Success() public {
        // Confirm that the bridging status is initially pending
        assertEq(
            flaunch.bridgingStarted(TOKEN_ID, ALTERNATIVE_CHAIN_ID),
            0,
            "Bridging started should be zero before initialization."
        );

        assertEq(
            flaunch.bridgingFinalized(TOKEN_ID, ALTERNATIVE_CHAIN_ID),
            false,
            "Bridging should not be finalized by default."
        );

        vm.expectEmit();
        emit Flaunch.TokenBridging(TOKEN_ID, ALTERNATIVE_CHAIN_ID, address(memecoin));

        flaunch.initializeBridge(TOKEN_ID, ALTERNATIVE_CHAIN_ID);

        // Confirm that the bridging status has updated
        assertEq(
            flaunch.bridgingStarted(TOKEN_ID, ALTERNATIVE_CHAIN_ID),
            block.timestamp,
            "Bridging started should show current timestamp after initialization."
        );

        assertEq(
            flaunch.bridgingFinalized(TOKEN_ID, ALTERNATIVE_CHAIN_ID),
            false,
            "Bridging should still not be finalized."
        );
    }

    function test_CannotInitializeBridge_AlreadyBridged() public {
        flaunch.initializeBridge(TOKEN_ID, ALTERNATIVE_CHAIN_ID);

        vm.expectRevert(Flaunch.TokenAlreadyBridging.selector);
        flaunch.initializeBridge(TOKEN_ID, ALTERNATIVE_CHAIN_ID);
    }

    function test_CannotInitializeBridge_DoesNotExist() public {
        vm.expectRevert(Flaunch.UnknownMemecoin.selector);
        flaunch.initializeBridge(TOKEN_ID + 1, ALTERNATIVE_CHAIN_ID);
    }

    function test_CanFinalizeBridge_Success() public isValidMessenger isValidSender {
        Flaunch.MemecoinMetadata memory memecoinMetadata = Flaunch.MemecoinMetadata({
            name: memecoin.name(),
            symbol: memecoin.symbol(),
            tokenUri: memecoin.tokenURI()
        });

        uint tokenId = TOKEN_ID + 1;

        vm.chainId(ALTERNATIVE_CHAIN_ID);

        vm.expectEmit();
        emit Flaunch.TokenBridged(tokenId, ALTERNATIVE_CHAIN_ID, 0x1A727A1caeE6449862aEF80DC3b47E1759ad3967, 123);

        flaunch.finalizeBridge(tokenId, memecoinMetadata);

        // Additional assertions
        IMemecoin bridgedMemecoin = IMemecoin(0x1A727A1caeE6449862aEF80DC3b47E1759ad3967);
        assertEq(bridgedMemecoin.name(), memecoin.name());
        assertEq(bridgedMemecoin.symbol(), memecoin.symbol());
        assertEq(bridgedMemecoin.tokenURI(), memecoin.tokenURI());

        assertEq(
            flaunch.bridgingFinalized(tokenId, ALTERNATIVE_CHAIN_ID),
            true,
            "Bridging should now be finalized after function successfully called."
        );

        // We should now receive a revert if we try to initialize the same contract again
        vm.chainId(INITIAL_CHAIN_ID);

        vm.expectRevert(abi.encodeWithSelector(Flaunch.TokenAlreadyBridged.selector));
        flaunch.initializeBridge(tokenId, ALTERNATIVE_CHAIN_ID);
    }

    function test_CanRebridgeAfterBridgingWindow(uint _invalidTimeDelta, uint _validTimeDelta) public {
        // Set our two testing timestamps; one which is below the window and one which is
        // equal to, or above, the window.
        vm.assume(_invalidTimeDelta < flaunch.MAX_BRIDGING_WINDOW());
        vm.assume(_validTimeDelta >= flaunch.MAX_BRIDGING_WINDOW());

        // Initialize our token bridge
        flaunch.initializeBridge(TOKEN_ID, ALTERNATIVE_CHAIN_ID);

        // Capture our initial block timestamp
        uint startTimestamp = block.timestamp;

        // Confirm that the bridging status has updated
        assertEq(flaunch.bridgingStarted(TOKEN_ID, ALTERNATIVE_CHAIN_ID), block.timestamp);

        vm.warp(startTimestamp + _invalidTimeDelta);

        vm.expectRevert(abi.encodeWithSelector(Flaunch.TokenAlreadyBridging.selector));
        flaunch.initializeBridge(TOKEN_ID, ALTERNATIVE_CHAIN_ID);

        vm.warp(startTimestamp + _validTimeDelta);

        flaunch.initializeBridge(TOKEN_ID, ALTERNATIVE_CHAIN_ID);

        assertEq(flaunch.bridgingStarted(TOKEN_ID, ALTERNATIVE_CHAIN_ID), startTimestamp + _validTimeDelta);
    }

    modifier isValidMessenger {
        vm.startPrank(Predeploys.L2_TO_L2_CROSS_DOMAIN_MESSENGER);
        _;
    }

    modifier isValidSender {
        vm.mockCall(
            Predeploys.L2_TO_L2_CROSS_DOMAIN_MESSENGER,
            abi.encodeWithSelector(IL2ToL2CrossDomainMessenger.crossDomainMessageSender.selector),
            abi.encode(address(flaunch))
        );

        _;
    }

}
