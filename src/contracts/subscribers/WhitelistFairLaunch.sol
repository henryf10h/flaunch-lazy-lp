// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from '@solady/auth/Ownable.sol';

import {BalanceDelta} from '@uniswap/v4-core/src/types/BalanceDelta.sol';
import {IHooks} from '@uniswap/v4-core/src/libraries/Hooks.sol';
import {IPoolManager} from '@uniswap/v4-core/src/interfaces/IPoolManager.sol';
import {PoolId} from '@uniswap/v4-core/src/types/PoolId.sol';

import {BaseSubscriber} from '@flaunch/subscribers/Base.sol';
import {FairLaunch} from '@flaunch/hooks/FairLaunch.sol';


/**
 * This allows a Fair Launch to be whitelisted so that only specific addresses can
 * purchase the token during the Fair Launch.
 *
 * This hooks into the `afterSwap` key to check the parameters passed, and if we see
 * that the fair launch has been whitelisted then we validate the call and revert if
 * it does not pass.
 */
contract WhitelistFairLaunch is BaseSubscriber, Ownable {

    error CallerNotWhitelisted();
    error CallerNotWhitelistZap();
    error WhitelistAlreadyExists();

    event WhitelistCreated(PoolId _poolId, bytes32 _root, string _ipfs, uint _maxTokens);
    event WhitelistPoolSwapUpdated(address _whitelistPoolSwap);
    event WhitelistZapUpdated(address _whitelistZap, bool _approved);

    /**
     * Holds whitelist information for a flaunch
     *
     * @member root The whitelist merkle root
     * @member ipfs The IPFS hash of the whitelist merkle tree
     * @member active If the whitelist is active
     * @member exists Simple boolean flag to test merkle exists now, or ever
     */
    struct WhitelistMerkle {
        bytes32 root;
        string ipfs;
        uint maxTokens;
        bool active;
        bool exists;
    }

    /// The {FairLaunch} contract
    FairLaunch public immutable fairLaunch;

    /// Specify a whitelisted {IPoolSwap} contract that will validate the whitelist
    address public whitelistPoolSwap;

    /// Stores our whitelist zaps
    mapping (address _whitelistZap => bool _approved) public whitelistZaps;

    /// Stores our whitelist claim lists
    mapping (PoolId _poolId => WhitelistMerkle _merkle) public whitelistMerkles;

    /**
     * Sets our {Notifier} to parent contract to lock down calls, as well as assigning the
     * {FairLaunch} contract address.
     *
     * @param _notifier The {Notifier} contract
     * @param _fairLaunch The {FairLaunch} contract address
     */
    constructor (address _notifier, address _fairLaunch) BaseSubscriber(_notifier) {
        _initializeOwner(msg.sender);

        fairLaunch = FairLaunch(_fairLaunch);
    }

    /**
     * Called when the contract is subscribed to the Notifier.
     *
     * We ensure that we have the {WhitelistPoolSwap} contract.
     *
     * @dev This must return `true` to be subscribed.
     */
    function subscribe(bytes memory /* _data */) public view override onlyNotifier returns (bool) {
        return whitelistPoolSwap != address(0);
    }

    /**
     * Called when `afterSwap` is fired to ensure that the caller is the expected whitelisted
     * pool swap contract.
     *
     * The pool swap contract that makes the whitelist approved call will have already validated
     * that the caller is in the `whitelistMerkle` by comparing the provided proof. This will
     * protect other swap contracts from calling this and bypassing whitelist checks.
     *
     * @param _poolId The PoolId that has triggered the subscriber
     * @param _key The notification key that has been triggered
     * @param _data The data passed after the swap
     */
    function notify(PoolId _poolId, bytes4 _key, bytes calldata _data) public override onlyNotifier {
        // We only want to deal with the `afterSwap` key
        if (_key != IHooks.afterSwap.selector) {
            return;
        }

        // Check if the pool currently has a whitelist attached
        WhitelistMerkle storage whitelistMerkle = whitelistMerkles[_poolId];
        if (!whitelistMerkle.active) {
            return;
        }

        /**
         * Check if the memecoin has exceeded the current Fair Launch period. If it has, then
         * we can mark the whitelist as inactive.
         *
         * This prevents overbuying, as the `endsAt` will be updated to the `block.timestamp`
         * at which the Fair Launch period is ended, even if it's past the original `endsAt`
         * timestamp.
         *
         * For this reason we also check if the supply is not zero, as this means that the
         * Fair Launch was not ended due to over buy / full buy in the same transaction, as
         * in this instance we should also check the whitelist. values will equal 0 when we
         * are notified in the `afterSwap` hook subscription.
         */
        FairLaunch.FairLaunchInfo memory fairLaunchInfo = fairLaunch.fairLaunchInfo(_poolId);
        if (block.timestamp >= fairLaunchInfo.endsAt && fairLaunchInfo.supply != 0) {
            // Disable the whitelist to prevent future processing
            whitelistMerkle.active = false;
            return;
        }

        // Decode our parameters to get the sender of the swap transaction
        (address sender,,) = abi.decode(
            _data,
            (address, IPoolManager.SwapParams, BalanceDelta)
        );

        // Ensure that the sender is our whitelist swap contract
        if (sender != whitelistPoolSwap) {
            revert CallerNotWhitelisted();
        }
    }

    /**
     * Allows an approved whitelist zap to set the whitelist for a PoolId.
     *
     * @dev This does allow the whitelist to be updated, but zaps should likely not use
     * this functionality as it will overwrite the existing whitelist.
     *
     * @param _poolId The PoolId that is being assigned the whitelist
     * @param _root The whitelist merkle root
     * @param _ipfs The IPFS hash of the whitelist merkle tree
     * @param _maxTokens The amount of tokens a user can buy during whitelist
     */
    function setWhitelist(PoolId _poolId, bytes32 _root, string calldata _ipfs, uint _maxTokens) public {
        // Ensure that only approved whitelist zaps can make this call
        if (!whitelistZaps[msg.sender]) {
            revert CallerNotWhitelistZap();
        }

        // Ensure that the PoolId does not already have a whitelist set
        if (whitelistMerkles[_poolId].exists) {
            revert WhitelistAlreadyExists();
        }

        // Set our whitelist
        whitelistMerkles[_poolId] = WhitelistMerkle(_root, _ipfs, _maxTokens, true, true);
        emit WhitelistCreated(_poolId, _root, _ipfs, _maxTokens);
    }

    /**
     * Sets the {WhitelistPoolSwap} contract address that will perform whitelisted swaps.
     *
     * @dev This can only be called by the contract Owner.
     *
     * @param _whitelistPoolSwap The new {WhitelistPoolSwap} address
     */
    function setWhitelistPoolSwap(address _whitelistPoolSwap) public onlyOwner {
        whitelistPoolSwap = _whitelistPoolSwap;
        emit WhitelistPoolSwapUpdated(_whitelistPoolSwap);
    }

    /**
     * Updates the approved contract addresses that can add whitelists.
     *
     * @dev This can only be called by the contract Owner.
     *
     * @param _whitelistZap The address of the contract to update
     * @param _approved If the address should be approved (`true`) or unapproved (`false`)
     */
    function setWhitelistZap(address _whitelistZap, bool _approved) public onlyOwner {
        whitelistZaps[_whitelistZap] = _approved;
        emit WhitelistZapUpdated(_whitelistZap, _approved);
    }

}
