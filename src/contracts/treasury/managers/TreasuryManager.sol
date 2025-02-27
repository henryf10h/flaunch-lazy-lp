// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from '@solady/auth/Ownable.sol';

import {Flaunch} from '@flaunch/Flaunch.sol';

import {ITreasuryManager} from '@flaunch-interfaces/ITreasuryManager.sol';


/**
 * Acts as a middleware for revenue claims, allowing external protocols to build on top of Flaunch
 * and be able to have more granular control over the revenue yielded.
 */
abstract contract TreasuryManager is ITreasuryManager, Ownable {

    error TokenTimelocked(uint _unlockedAt);

    event TreasuryEscrowed(uint indexed _tokenId, address _owner, address _sender);
    event TreasuryReclaimed(uint indexed _tokenId, address _sender, address _recipient);
    event TreasuryTimelocked(uint indexed _tokenId, uint _unlockedAt);

    /// ERC721 Flaunch contract address
    Flaunch public immutable flaunch;

    /// Creates a standardised timelock mechanism for tokens
    mapping (uint _tokenId => uint _unlockedAt) public tokenTimelock;

    /**
     * Sets up the contract with the initial required contract addresses.
     *
     * @param _flaunch The {Flaunch} ERC721 contract address
     */
    constructor (address _flaunch) {
        flaunch = Flaunch(_flaunch);
    }

    /**
     * Escrow an ERC721 token by transferring it to this contract and recording the original
     * owner.
     *
     * @param _tokenId The ID of the token to escrow
     * @param _owner The address to have ownership over the tokens
     * @param _data Additional manager initialization data
     */
    function initialize(uint _tokenId, address _owner, bytes calldata _data) public {
        // Set the original owner if one is not already set. The `Ownable` library enforces
        // that `newOwner` cannot be set to the zero address.
        if (owner() == address(0)) {
            _initializeOwner(_owner);
        }

        // Transfer the token from the msg.sender to the contract
        flaunch.transferFrom(msg.sender, address(this), _tokenId);
        emit TreasuryEscrowed(_tokenId, _owner, msg.sender);

        _initialize(_tokenId, _data);
    }

    /**
     * An internal initialization function that is overwritten by the managers that extend
     * this contract.
     *
     * @param _tokenId The tokenId being passed in to the manager
     * @param _data Additional data bytes that can be unpacked
     */
    function _initialize(uint _tokenId, bytes calldata _data) internal virtual {
        // ..
    }

    /**
     * Rescues the ERC721, extracting it from the manager and transferring it to a recipient.
     *
     * @dev Only the owner can make this call.
     *
     * @param _tokenId The tokenId to rescue
     * @param _recipient The recipient to receive the ERC721
     */
    function rescue(uint _tokenId, address _recipient) public virtual onlyOwner {
        // Ensure that the token is either not timelocked (zero value) or the timelock
        // has passed.
        uint unlockedAt = tokenTimelock[_tokenId];
        if (block.timestamp < unlockedAt) {
            revert TokenTimelocked(unlockedAt);
        }

        // Remove the timelock on the token
        delete tokenTimelock[_tokenId];

        // Transfer the token from the msg.sender to the contract. If the token is not
        // held by this contract then this call will revert.
        flaunch.transferFrom(address(this), _recipient, _tokenId);

        emit TreasuryReclaimed(_tokenId, owner(), _recipient);
    }

    /**
     * Override to return true to make `_initializeOwner` prevent double-initialization.
     *
     * @return bool Set to `true` to prevent owner being reinitialized.
     */
    function _guardInitializeOwner() internal pure override returns (bool) {
        return true;
    }

    /**
     * Allows the contract to receive ETH when withdrawn from the flETH token.
     */
    receive () external payable {}

}
