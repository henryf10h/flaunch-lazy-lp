// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from '@uniswap/v4-core/src/interfaces/IPoolManager.sol';
import {PoolId} from '@uniswap/v4-core/src/types/PoolId.sol';

import {FeeDistributor} from '@flaunch/hooks/FeeDistributor.sol';
import {ProtocolFeeRecipient} from '@flaunch/ProtocolFeeRecipient.sol';

import {PositionManagerMock} from './mocks/PositionManagerMock.sol';
import {FlaunchTest} from './FlaunchTest.sol';


contract ProtocolFeeRecipientTest is FlaunchTest {

    ProtocolFeeRecipient protocolFeeRecipient;

    constructor () {
        _deployPlatform();

        // Deploy our {ProtocolFeeRecipient}
        protocolFeeRecipient = new ProtocolFeeRecipient();

        // Deposit some flETH that we can use during tests so that we can unwrap it
        deal(address(this), type(uint128).max);
        flETH.deposit{value: type(uint128).max}(0);
    }

    function test_CanGetAvailable(uint64 _eth, uint64 _pm1, uint64 _pm2) public {
        deal(address(protocolFeeRecipient), _eth);

        PositionManagerMock pmm1 = _deployPositionManagerMock(0x046705475b26a3cFF04Ce91f658b4AE2f8Eb2fDC);
        PositionManagerMock pmm2 = _deployPositionManagerMock(0x123705475B26A3cFf04CE91f658b4ae2f8eb2fdc);

        protocolFeeRecipient.setPositionManager(address(pmm1), true);
        protocolFeeRecipient.setPositionManager(address(pmm2), true);

        PoolId mockPoolId = PoolId.wrap('PoolId');

        if (_pm1 != 0) {
            flETH.transfer(address(pmm1), _pm1);
            pmm1.allocateFeesMock(mockPoolId, address(protocolFeeRecipient), _pm1);
        }

        if (_pm2 != 0) {
            flETH.transfer(address(pmm2), _pm2);
            pmm2.allocateFeesMock(mockPoolId, address(protocolFeeRecipient), _pm2);
        }

        // We should be able to see the total amount available
        assertEq(protocolFeeRecipient.available(), uint(_eth) + _pm1 + _pm2);

        // We should only hold the ETH value, and not have claimed any fees
        assertEq(payable(address(protocolFeeRecipient)).balance, uint(_eth));
    }

    function test_CanClaim(uint64 _eth, uint64 _pm1, uint64 _pm2) public {
        // Set a recipient and ensure they start with zero ETH
        address payable _recipient = payable(address(420));
        deal(_recipient, 0);

        deal(address(protocolFeeRecipient), _eth);

        PositionManagerMock pmm1 = _deployPositionManagerMock(0x046705475b26a3cFF04Ce91f658b4AE2f8Eb2fDC);
        PositionManagerMock pmm2 = _deployPositionManagerMock(0x123705475B26A3cFf04CE91f658b4ae2f8eb2fdc);

        protocolFeeRecipient.setPositionManager(address(pmm1), true);
        protocolFeeRecipient.setPositionManager(address(pmm2), true);

        PoolId mockPoolId = PoolId.wrap('PoolId');

        if (_pm1 != 0) {
            flETH.transfer(address(pmm1), _pm1);
            pmm1.allocateFeesMock(mockPoolId, address(protocolFeeRecipient), _pm1);
        }

        if (_pm2 != 0) {
            flETH.transfer(address(pmm2), _pm2);
            pmm2.allocateFeesMock(mockPoolId, address(protocolFeeRecipient), _pm2);
        }

        // We should be able to see the total amount available
        uint available = protocolFeeRecipient.available();

        // Make our claim
        uint sentAmount = protocolFeeRecipient.claim(_recipient);

        // Confirm that we have claimed the correct amount
        assertEq(sentAmount, available, 'sentAmount != available');
        assertEq(sentAmount, uint(_eth) + _pm1 + _pm2, 'sentAmount != sum of fuzz');

        // Confirm that our recipient received the full amount of eth
        assertEq(payable(address(_recipient)).balance, sentAmount, 'Incorrect recipient ETH received');
    }

    function test_CanAddPositionManager(address _positionManager) public {
        vm.expectEmit();
        emit ProtocolFeeRecipient.PositionManagerUpdated(_positionManager, true);

        protocolFeeRecipient.setPositionManager(_positionManager, true);
    }

    function test_CanRemovePositionManager(address _positionManager) public {
        protocolFeeRecipient.setPositionManager(_positionManager, true);

        vm.expectEmit();
        emit ProtocolFeeRecipient.PositionManagerUpdated(_positionManager, false);

        protocolFeeRecipient.setPositionManager(_positionManager, false);
    }

    function _deployPositionManagerMock(address _deploymentAddress) internal returns (PositionManagerMock) {
        FeeDistributor.FeeDistribution memory feeDistribution = FeeDistributor.FeeDistribution({
            swapFee: 1_00,
            referrer: 5_00,
            protocol: 10_00,
            active: true
        });

        deployCodeTo('PositionManagerMock.sol', abi.encode(
            address(WETH),
            address(poolManager),
            feeDistribution,
            address(initialPrice),
            address(this),
            address(this),
            governance,
            address(feeExemptions),
            actionManager,
            bidWall,
            fairLaunch
        ), _deploymentAddress);

        return PositionManagerMock(payable(_deploymentAddress));
    }

}
