// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;


interface ITreasuryManagerFactory {

    function approvedManagerImplementation(address _managerImplementation) external returns (bool _approved);

    function managerImplementation(address _manager) external returns (address _managerImplementation);

    function deployManager(address _managerImplementation) external returns (address payable manager_);

    function approveManager(address _managerImplementation) external;

    function unapproveManager(address _managerImplementation) external;

}