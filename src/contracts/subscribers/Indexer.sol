// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from '@solady/auth/Ownable.sol';

import {IHooks} from '@uniswap/v4-core/src/libraries/Hooks.sol';
import {PoolId, PoolIdLibrary} from '@uniswap/v4-core/src/types/PoolId.sol';
import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';

import {Flaunch} from '@flaunch/Flaunch.sol';


/**
 * Creates an evolving list of pools on Flaunch and maps its corresponding token
 * information for onchain lookups.
 */
contract IndexerSubscriber is Ownable {

    using PoolIdLibrary for PoolKey;

    error InvalidTokenId(address _flaunch, uint _tokenId);

    /**
     * Contains index information for a token.
     *
     * @member flaunch The {Flaunch} contract that launched the token
     * @member memecoin The ERC20 memecoin address
     * @member memecoinTreasury The contract address for the memecoin treasury
     * @member tokenId The ERC721 {Flaunch} token created with the memecoin
     */
    struct Index {
        address flaunch;
        address memecoin;
        address memecoinTreasury;
        uint tokenId;
    }

    /**
     * Contains information required for created a legacy index.
     *
     * @member flaunch The {Flaunch} contract that launched the token
     * @member tokenId The ERC721 {Flaunch} token IDs created with the memecoin
     */
    struct AddIndexParams {
        address flaunch;
        uint[] tokenIds;
    }

    /// Maps a PoolId to the token index information
    mapping (PoolId _poolId => Index _index) public poolIndex;

    /// Maps each notifier to the flaunch contract that it will represent
    mapping (address _notifier => address _flaunch) internal _notifierFlaunch;

    /**
     * Registers the owner of the contract.
     */
    constructor () {
        _initializeOwner(msg.sender);
    }

    /**
     * Called when the contract is subscribed to the Notifier.
     *
     * We have no subscription requirements, so we can just confirm immediately.
     *
     * @dev This must return `true` to be subscribed.
     */
    function subscribe(bytes memory /* _data */) public pure returns (bool) {
        return true;
    }

    /**
     * Whenever a token is flaunched, we will index the token information onchain.
     *
     * @dev Called when `afterInitialize` is triggered.
     *
     * @param _poolId The poolId that has been initialized
     * @param _key The notification key
     * @param _data Contains the tokenId, as well as unused params
     */
    function notify(PoolId _poolId, bytes4 _key, bytes calldata _data) public {
        // We only want to deal with the `afterInitialize` key
        if (_key != IHooks.afterInitialize.selector) {
            return;
        }

        // If the notifier has not been allocated a flaunch contract, then we cannot
        // proceed with our indexing.
        if (_notifierFlaunch[msg.sender] == address(0)) {
            return;
        }

        // Register our flaunch contract relative to the notifier
        Flaunch flaunch = Flaunch(_notifierFlaunch[msg.sender]);

        // Unpack our tokenId from our passed initialization data
        (uint tokenId) = abi.decode(_data, (uint));

        // Store our token information, relative to the PoolId
        poolIndex[_poolId] = Index({
            flaunch: address(flaunch),
            memecoin: flaunch.memecoin(tokenId),
            memecoinTreasury: flaunch.memecoinTreasury(tokenId),
            tokenId: tokenId
        });
    }

    /**
     * For tokens that were flaunched before this Notifier was put in place, we allow the
     * information to be back-filled. The data is validated before being written and will
     * revert if it is deemed invalid.
     *
     * @param _params Information to add legacy indexes
     */
    function addIndex(AddIndexParams[] calldata _params) public {
        // Declare our global variables
        AddIndexParams memory params;
        Flaunch flaunch;
        PoolId poolId;
        uint tokenId;

        // Iterate over all tokens to sync them
        uint paramsLength = _params.length;
        for (uint i; i < paramsLength; ++i) {
            params = _params[i];
            flaunch = Flaunch(params.flaunch);

            // Iterate over our tokenIds
            uint tokenIdsLength = params.tokenIds.length;
            for (uint k; k < tokenIdsLength; ++k) {
                tokenId = params.tokenIds[k];

                /**
                 * Validate the data provided by checking the token information and confirming
                 * that it matches the tokenId provided. We can do this because our protocol has
                 * a uni-directional lookup which is why this subscriber is created to make it
                 * multi-directional.
                 */

                // Confirm that the memecoin correctly matches the tokenId
                address memecoin = flaunch.memecoin(tokenId);
                if (flaunch.tokenId(memecoin) != tokenId) {
                    revert InvalidTokenId(address(flaunch), tokenId);
                }

                // Find the PoolKey by the memecoin address
                poolId = flaunch.positionManager().poolKey(memecoin).toId();

                // Store our validated index data
                poolIndex[poolId] = Index({
                    flaunch: address(flaunch),
                    memecoin: memecoin,
                    memecoinTreasury: flaunch.memecoinTreasury(tokenId),
                    tokenId: tokenId
                });
            }
        }
    }

    /**
     * Allows our owner to set {Flaunch} contracts for each {Notifier}.
     *
     * @param _notifier The {Notifier} contract address
     * @param _flaunch The {Flaunch} contract of the Notifier
     */
    function setNotifierFlaunch(address _notifier, address _flaunch) public onlyOwner {
        _notifierFlaunch[_notifier] = _flaunch;
    }

}
