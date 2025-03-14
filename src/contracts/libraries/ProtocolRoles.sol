// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;


/**
 * Holds global variable for the total token supply during flaunching.
 */
library ProtocolRoles {

    bytes32 public constant FLAUNCH = keccak256('Flaunch');
    bytes32 public constant POSITION_MANAGER = keccak256('PositionManager');

}
