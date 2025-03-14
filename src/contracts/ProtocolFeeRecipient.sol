// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {EnumerableSetLib} from '@solady/utils/EnumerableSetLib.sol';
import {Ownable} from '@solady/auth/Ownable.sol';

import {PositionManager} from '@flaunch/PositionManager.sol';


/**
 * Acts as a middleware for PositionManager fee recipients to allow additional control
 * over when fees are claimed and how they are managed.
 */
contract ProtocolFeeRecipient is Ownable {

    using EnumerableSetLib for EnumerableSetLib.AddressSet;

    error EthTransferFailed();

    /// Emitted when a PositionManager is enabled or disabled
    event PositionManagerUpdated(address _positionManager, bool _enabled);

    /// The `PositionManager`s that will be claimed against
    EnumerableSetLib.AddressSet internal _positionManagers;

    /**
     * Sets the sender as the owner of the contract.
     */
    constructor () {
        _initializeOwner(msg.sender);
    }

    /**
     * The total amount of fees available to be claimed by this contract.
     *
     * @return amount_ The amount of ETH available to claim
     */
    function available() public view returns (uint amount_) {
        // Amount of ETH held in the contract
        amount_ += payable(address(this)).balance;

        // Amount of ETH available to claim from PositionManagers
        for (uint i; i < _positionManagers.length(); ++i) {
            amount_ += PositionManager(payable(_positionManagers.at(i))).balances(address(this));
        }
    }

    /**
     * Claims the available amount to a designated recipient.
     *
     * @param _recipient The recipient of the claimed ETH
     *
     * @return amount_ The amount of ETH received in the claim
     */
    function claim(address payable _recipient) public onlyOwner returns (uint amount_) {
        // Withdraw fees from PositionManager
        for (uint i; i < _positionManagers.length(); ++i) {
            PositionManager(payable(_positionManagers.at(i))).withdrawFees(address(this), true);
        }

        // Find the total amount being claimed by capturing the current ETH balance
        amount_ = payable(address(this)).balance;

        // Transfer all ETH to the recipient
        (bool _sent,) = _recipient.call{value: amount_}('');
        if (!_sent) revert EthTransferFailed();
    }

    /**
     * Sets or removes a PositionManager from the internal array.
     *
     * @param _positionManager The PositionManager to be manipulated in the EnumerableSet
     * @param _enable If the PositionManager is being enabled (true) or disabled (false)
     */
    function setPositionManager(address _positionManager, bool _enable) public onlyOwner {
        if (_enable && !_positionManagers.contains(_positionManager)) {
            _positionManagers.add(_positionManager);
            emit PositionManagerUpdated(_positionManager, true);
        } else if (!_enable && _positionManagers.contains(_positionManager)) {
            _positionManagers.remove(_positionManager);
            emit PositionManagerUpdated(_positionManager, false);
        }
    }

    /**
     * Allows the contract to receive ETH from fees.
     */
    receive () external payable {}

}
