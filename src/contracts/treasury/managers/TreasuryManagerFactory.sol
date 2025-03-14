// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from '@solady/auth/Ownable.sol';
import {LibClone} from '@solady/utils/LibClone.sol';

import {AccessControl} from '@openzeppelin/contracts/access/AccessControl.sol';

import {TreasuryManager} from '@flaunch/treasury/managers/TreasuryManager.sol';

import {ITreasuryManagerFactory} from '@flaunch-interfaces/ITreasuryManagerFactory.sol';


/**
 * Allows the contract owner to manage approved {ITreasuryAction} contracts.
 */
contract TreasuryManagerFactory is AccessControl, ITreasuryManagerFactory, Ownable {

    error UnknownManagerImplemention();

    event ManagerImplementationApproved(address indexed _managerImplementation);
    event ManagerDeployed(address indexed _manager, address indexed _managerImplementation);
    event ManagerImplementationUnapproved(address indexed _managerImplementation);

    /// Mapping to store approved action contract addresses
    mapping (address _managerImplementation => bool _approved) public approvedManagerImplementation;

    /// Mapping of deployments to their implementations
    mapping (address _manager => address _managerImplementation) public managerImplementation;

    /**
     * Sets the contract owner.
     *
     * @dev This contract should be created in the {PositionManager} constructor call.
     */
    constructor (address _protocolOwner) {
        _initializeOwner(_protocolOwner);

        // Set our protocol owner to have the default admin of protocol roles
        _grantRole(DEFAULT_ADMIN_ROLE, _protocolOwner);
    }

    /**
     * Deploys an approved manager implementation.
     *
     * @param _managerImplementation The address of the approved implementation
     *
     * @return manager_ The freshly deployed {TreasuryManager} contract address
     */
    function deployManager(address _managerImplementation) public returns (address payable manager_) {
        // Ensure that the implementation is approved
        if (!approvedManagerImplementation[_managerImplementation]) {
            revert UnknownManagerImplemention();
        }

        // Deploy a new implementation of the manager and return the address
        manager_ = payable(LibClone.clone(_managerImplementation));

        // Store the implementation for the manager. This allows us to both lookup the
        // implementation type for a manager, and also to validate that it's legit.
        managerImplementation[manager_] = _managerImplementation;
        emit ManagerDeployed(manager_, _managerImplementation);
    }

    /**
     * Approves a manager implementation.
     *
     * @dev This will not revert if the implementation is already approved
     *
     * @param _managerImplementation The implementation to approve
     */
    function approveManager(address _managerImplementation) public onlyOwner {
        approvedManagerImplementation[_managerImplementation] = true;
        emit ManagerImplementationApproved(_managerImplementation);
    }

    /**
     * Remove a manager implementation from approval.
     *
     * @dev This will revert if the contract is no already approved
     *
     * @param _managerImplementation The implementation to unapprove
     */
    function unapproveManager(address _managerImplementation) public onlyOwner {
        if (!approvedManagerImplementation[_managerImplementation]) {
            revert UnknownManagerImplemention();
        }

        approvedManagerImplementation[_managerImplementation] = false;
        emit ManagerImplementationUnapproved(_managerImplementation);
    }

    /**
     * Override to return true to make `_initializeOwner` prevent double-initialization.
     *
     * @return bool Set to `true` to prevent owner being reinitialized.
     */
    function _guardInitializeOwner() internal pure override returns (bool) {
        return true;
    }

}
