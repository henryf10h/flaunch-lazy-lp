// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Testing utilities
import { FlaunchTest } from '../FlaunchTest.sol';

// Flaunch contracts
import { Memecoin } from '@flaunch/Memecoin.sol';
import { PositionManager } from '@flaunch/PositionManager.sol';

// Libraries
import { Predeploys } from '@optimism/src/libraries/Predeploys.sol';

// Target contracts
import { IERC7802, IERC165 } from '@optimism/interfaces/L2/IERC7802.sol';
import { ISuperchainERC20 } from '@optimism/interfaces/L2/ISuperchainERC20.sol';

import { IERC20 } from '@openzeppelin/contracts/token/ERC20/IERC20.sol';


/**
 * @title SuperchainERC20Test
 *
 * Contract for testing the SuperchainERC20 contract.
 *
 * @dev Copied from lib/@optimism and modified to support Memecoin.
 */
contract MemecoinSuperchainERC20Test is FlaunchTest {

    address internal constant ZERO_ADDRESS = address(0);
    address internal constant SUPERCHAIN_TOKEN_BRIDGE = Predeploys.SUPERCHAIN_TOKEN_BRIDGE;
    address internal constant MESSENGER = Predeploys.L2_TO_L2_CROSS_DOMAIN_MESSENGER;

    Memecoin public superchainERC20;

    /// @notice Sets up the test suite.
    function setUp() public {
        // Deploy the Flaunch platform
        _deployPlatform();

        // Deploy a memecoin
        address memecoin = positionManager.flaunch(
            PositionManager.FlaunchParams({
                name: 'Token Name',
                symbol: 'TOKEN',
                tokenUri: 'https://flaunch.gg/',
                initialTokenFairLaunch: supplyShare(50),
                fairLaunchDuration: 30 minutes,
                premineAmount: 0,
                creator: address(this),
                creatorFeeAllocation: 20_00,
                flaunchAt: 0,
                initialPriceParams: abi.encode(''),
                feeCalculatorParams: abi.encode(1_000)
            })
        );

        // Register the memecoin contract address against the `superchainERC20` used for testing
        superchainERC20 = Memecoin(memecoin);
    }

    /// @notice Helper function to setup a mock and expect a call to it.
    function _mockAndExpect(address _receiver, bytes memory _calldata, bytes memory _returned) internal {
        vm.mockCall(_receiver, _calldata, _returned);
        vm.expectCall(_receiver, _calldata);
    }

    /// @notice Tests the `mint` function reverts when the caller is not the bridge.
    function testFuzz_crosschainMint_callerNotBridge_reverts(address _caller, address _to, uint224 _amount) public {
        // Ensure the caller is not the bridge
        vm.assume(_caller != SUPERCHAIN_TOKEN_BRIDGE);

        // Expect the revert with `Unauthorized` selector
        vm.expectRevert(ISuperchainERC20.Unauthorized.selector);

        // Call the `mint` function with the non-bridge caller
        vm.prank(_caller);
        superchainERC20.crosschainMint(_to, _amount);
    }

    /// @notice Tests the `mint` succeeds and emits the `Mint` event.
    function testFuzz_crosschainMint_succeeds(address _to, uint128 _amount) public {
        // Ensure `_to` is not the zero address
        vm.assume(_to != ZERO_ADDRESS);

        // Get the total supply and balance of `_to` before the mint to compare later on the assertions
        uint _totalSupplyBefore = superchainERC20.totalSupply();
        uint _toBalanceBefore = superchainERC20.balanceOf(_to);

        // Look for the emit of the `Transfer` event
        vm.expectEmit(address(superchainERC20));
        emit IERC20.Transfer(ZERO_ADDRESS, _to, _amount);

        // Look for the emit of the `CrosschainMint` event
        vm.expectEmit(address(superchainERC20));
        emit IERC7802.CrosschainMint(_to, _amount, SUPERCHAIN_TOKEN_BRIDGE);

        // Call the `mint` function with the bridge caller
        vm.prank(SUPERCHAIN_TOKEN_BRIDGE);
        superchainERC20.crosschainMint(_to, _amount);

        // Check the total supply and balance of `_to` after the mint were updated correctly
        assertEq(superchainERC20.totalSupply(), _totalSupplyBefore + _amount);
        assertEq(superchainERC20.balanceOf(_to), _toBalanceBefore + _amount);
    }

    /// @notice Tests the `burn` function reverts when the caller is not the bridge.
    function testFuzz_crosschainBurn_callerNotBridge_reverts(address _caller, address _from, uint224 _amount) public {
        // Ensure the caller is not the bridge
        vm.assume(_caller != SUPERCHAIN_TOKEN_BRIDGE);

        // Expect the revert with `Unauthorized` selector
        vm.expectRevert(ISuperchainERC20.Unauthorized.selector);

        // Call the `burn` function with the non-bridge caller
        vm.prank(_caller);
        superchainERC20.crosschainBurn(_from, _amount);
    }

    /// @notice Tests the `burn` burns the amount and emits the `CrosschainBurn` event.
    function testFuzz_crosschainBurn_succeeds(address _from, uint128 _amount) public {
        // Ensure `_from` is not the zero address
        vm.assume(_from != ZERO_ADDRESS);

        // Mint some tokens to `_from` so then they can be burned
        vm.prank(SUPERCHAIN_TOKEN_BRIDGE);
        superchainERC20.crosschainMint(_from, _amount);

        // Get the total supply and balance of `_from` before the burn to compare later on the assertions
        uint _totalSupplyBefore = superchainERC20.totalSupply();
        uint _fromBalanceBefore = superchainERC20.balanceOf(_from);

        // Look for the emit of the `Transfer` event
        vm.expectEmit(address(superchainERC20));
        emit IERC20.Transfer(_from, ZERO_ADDRESS, _amount);

        // Look for the emit of the `CrosschainBurn` event
        vm.expectEmit(address(superchainERC20));
        emit IERC7802.CrosschainBurn(_from, _amount, SUPERCHAIN_TOKEN_BRIDGE);

        // Call the `burn` function with the bridge caller
        vm.prank(SUPERCHAIN_TOKEN_BRIDGE);
        superchainERC20.crosschainBurn(_from, _amount);

        // Check the total supply and balance of `_from` after the burn were updated correctly
        assertEq(superchainERC20.totalSupply(), _totalSupplyBefore - _amount);
        assertEq(superchainERC20.balanceOf(_from), _fromBalanceBefore - _amount);
    }

    /// @notice Tests that the `supportsInterface` function returns true for the `IERC7802` interface.
    function test_supportInterface_succeeds() public view {
        assertTrue(superchainERC20.supportsInterface(type(IERC165).interfaceId));
        assertTrue(superchainERC20.supportsInterface(type(IERC7802).interfaceId));
        assertTrue(superchainERC20.supportsInterface(type(IERC20).interfaceId));
    }

}
