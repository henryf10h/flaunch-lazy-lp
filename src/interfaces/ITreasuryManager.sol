// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Flaunch} from '@flaunch/Flaunch.sol';


/**
 * Acts as a middleware for revenue claims, allowing external protocols to build on top of Flaunch
 * and be able to have more granular control over the revenue yielded.
 */
interface ITreasuryManager {

    /**
     * The Flaunch Token definition.
     *
     * @param flaunch The flaunch contract used to launch the token
     * @param tokenId The tokenId of the Flaunch ERC721
     */
    struct FlaunchToken {
        Flaunch flaunch;
        uint tokenId;
    }

    /**
     * Initializes the token by setting the contract ownership for the manager. It then processes
     * extended logic.
     *
     * @dev The {TreasuryManager} implementation will use an internal `_initialize` call for
     * their own logic.
     */
    function initialize(address _owner, bytes calldata _data) external;

    /**
     * Transfers the ERC721 into the manager. It then processes extended logic.
     *
     * @dev The {TreasuryManager} implementation will use an internal `_deposit` call for
     * their own logic.
     */
    function deposit(FlaunchToken calldata _flaunchToken, address _creator, bytes calldata _data) external;

    /**
     * Allows the ERC721 to be rescued from the manager by the owner of the contract.
     *
     * @dev This is designed as a last-resort call, rather than an expected flow.
     */
    function rescue(FlaunchToken calldata _flaunchToken, address _recipient) external;

}
