// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';

import {OnboardingManager} from '@flaunch/treasury/managers/OnboardingManager.sol';


/**
 * Extends the {OnboardingManager} to allow for other Flaunch ERC721's to stake their ownership
 * into the {RaidManager} and donate fees to the onboardee's earnings. This will help increase the
 * onboardee pot whilst also earning rewards.
 */
contract RaidManager is OnboardingManager {

    error TokenAlreadyRaiding();

    event RaidExited(uint _tokenId);
    event RaidJoined(uint _tokenId);

    /// Maintains a list of the raiders that have staked their token
    mapping (uint _tokenId => address _owner) public raiders;

    /**
     * Sets up the contract with the initial required contract addresses.
     *
     * @param _flaunch The {Flaunch} ERC721 contract address
     * @param _airdropClaim The {IMerkleAirdrop} contract that will distribute claims
     * @param _poolSwap The {IPoolSwap} contract that will facilitate market buys
     */
    constructor (address _flaunch, address _airdropClaim, address _poolSwap, PoolKey memory _flayPoolKey)
        OnboardingManager(_flaunch, _airdropClaim, _poolSwap, _flayPoolKey) {}

    /**
     * Allows an Flaunch ERC721 holder to stake their token against the onboardee raid and
     * donate their token revenue to the pot.
     *
     * @param _tokenId The Flaunch tokenId being transferred in
     */
    function joinRaid(uint _tokenId) public onlyNotClaimed {
        // Confirm not ended
        if (block.timestamp > claimWindowEnd) {
            revert OnboardingWindowClosed();
        }

        // Confirm that the raider is not already set. This should be prevented by the
        // subsequent transfer call, but this returns a better error detail.
        if (raiders[_tokenId] != address(0)) {
            revert TokenAlreadyRaiding();
        }

        // Transfer token into the contract
        flaunch.transferFrom(msg.sender, address(this), _tokenId);

        // Add the raider mapping
        raiders[_tokenId] = msg.sender;

        emit RaidJoined(_tokenId);
    }

    /**
     * Allows a raider to exit their Flaunch tokenId from the raid, transferring it back
     * into their wallet.
     *
     * @param _tokenId The Flaunch tokenId being transferred out
     */
    function exitRaid(uint _tokenId) public {
        // Confirm original owner
        if (msg.sender != raiders[_tokenId]) {
            revert InvalidClaimer();
        }

        // Remove the raider
        delete raiders[_tokenId];

        // Transfer the token back to the original owner
        flaunch.transferFrom(address(this), msg.sender, _tokenId);

        emit RaidExited(_tokenId);
    }

}
