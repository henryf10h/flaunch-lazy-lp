// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Flaunch} from '@flaunch/Flaunch.sol';


/**
 * Acts as a middleware for revenue claims, allowing external protocols to build on top of Flaunch
 * and be able to have more granular control over the revenue yielded.
 */
interface ITreasuryManager {

    /**
     * ..
     */
    struct FlaunchToken {
        Flaunch flaunch;
        uint tokenId;
    }

    /**
     * Initializes the token by setting the contract ownership and transferring the ERC721
     * into the manager. It then processes extended logic.
     *
     * @dev The {TreasuryManager} implementation will use an internal `_initialize` call for
     * their own logic.
     */
    function initialize(FlaunchToken calldata _flaunchToken, address _owner, bytes calldata _data) external;

    /**
     * Allows the ERC721 to be rescued from the manager by the owner of the contract.
     *
     * @dev This is designed as a last-resort call, rather than an expected flow.
     */
    function rescue(FlaunchToken calldata _flaunchToken, address _recipient) external;

}
