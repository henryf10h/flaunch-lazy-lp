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

    event RaidExited(address _flaunch, uint _tokenId);
    event RaidJoined(address _flaunch, uint _tokenId);

    /// Maintains a list of the raiders that have staked their token
    mapping (address _flaunch => mapping(uint _tokenId => address _owner)) public raiders;

    /**
     * Sets up the contract with the initial required contract addresses.
     *
     * @param _treasuryManagerFactory The {TreasuryManagerFactory} that will launch this implementation
     * @param _flayBurner The {FlayBurner} contract address
     * @param _airdropClaim The {IMerkleAirdrop} contract that will distribute claims
     */
    constructor (address _treasuryManagerFactory, address payable _flayBurner, address _airdropClaim)
        OnboardingManager(_treasuryManagerFactory, _flayBurner, _airdropClaim) {}

    /**
     * Allows an Flaunch ERC721 holder to stake their token against the onboardee raid and
     * donate their token revenue to the pot.
     *
     * @param _flaunchToken The Flaunch token being transferred in
     */
    function joinRaid(FlaunchToken calldata _flaunchToken) public onlyNotClaimed {
        // Confirm not ended
        if (block.timestamp > claimWindowEnd) {
            revert OnboardingWindowClosed();
        }

        // Confirm that the raider is not already set. This should be prevented by the
        // subsequent transfer call, but this returns a better error detail.
        if (raiders[address(_flaunchToken.flaunch)][_flaunchToken.tokenId] != address(0)) {
            revert TokenAlreadyRaiding();
        }

        // Transfer token into the contract
        _flaunchToken.flaunch.transferFrom(msg.sender, address(this), _flaunchToken.tokenId);

        // Add the raider mapping
        raiders[address(_flaunchToken.flaunch)][_flaunchToken.tokenId] = msg.sender;

        emit RaidJoined(address(_flaunchToken.flaunch), _flaunchToken.tokenId);
    }

    /**
     * Allows a raider to exit their Flaunch tokenId from the raid, transferring it back
     * into their wallet.
     *
     * @param _flaunchToken The Flaunch token being transferred out
     */
    function exitRaid(FlaunchToken calldata _flaunchToken) public {
        // Confirm original owner
        if (msg.sender != raiders[address(_flaunchToken.flaunch)][_flaunchToken.tokenId]) {
            revert InvalidClaimer();
        }

        // Remove the raider
        delete raiders[address(_flaunchToken.flaunch)][_flaunchToken.tokenId];

        // Transfer the token back to the original owner
        _flaunchToken.flaunch.transferFrom(address(this), msg.sender, _flaunchToken.tokenId);

        emit RaidExited(address(_flaunchToken.flaunch), _flaunchToken.tokenId);
    }

}
