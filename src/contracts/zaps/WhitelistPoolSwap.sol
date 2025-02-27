// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {MerkleProofLib} from '@solady/utils/MerkleProofLib.sol';

import {BalanceDelta} from '@uniswap/v4-core/src/types/BalanceDelta.sol';
import {IPoolManager} from '@uniswap/v4-core/src/interfaces/IPoolManager.sol';
import {PoolId, PoolIdLibrary} from '@uniswap/v4-core/src/types/PoolId.sol';
import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';

import {WhitelistFairLaunch} from '@flaunch/subscribers/WhitelistFairLaunch.sol';
import {PoolSwap} from '@flaunch/zaps/PoolSwap.sol';


/**
 * Handles swaps against Uniswap V4 pools whilst also checking an optional whitelist.
 */
contract WhitelistPoolSwap is PoolSwap {

    using PoolIdLibrary for PoolKey;

    error MerkleVerificationFailed();
    error TooManyTokensClaimed();

    /// The {WhitelistFairLaunch} that holds the whitelist merkles
    WhitelistFairLaunch public immutable whitelistFairLaunch;

    /// Stores the amount of tokens a user has claimed from each whitelist
    mapping (PoolId _poolId => mapping (address _recipient => uint _tokensClaimed)) public tokensClaimed;

    /**
     * Register our Uniswap V4 {PoolManager}.
     *
     * @param _manager The Uniswap V4 {PoolManager}
     */
    constructor (IPoolManager _manager, address _whitelistFairLaunch) PoolSwap(_manager) {
        whitelistFairLaunch = WhitelistFairLaunch(_whitelistFairLaunch);
    }

    /**
     * Actions a swap using the SwapParams provided against the PoolKey without a referrer.
     *
     * @param _key The PoolKey to swap against
     * @param _params The parameters for the swap
     * @param _merkleProof The merkle proof for the whitelist spot
     *
     * @return The BalanceDelta of the swap
     */
    function swap(
        PoolKey memory _key,
        IPoolManager.SwapParams memory _params,
        bytes32[] memory _merkleProof
    ) public payable virtual returns (BalanceDelta) {
        return swap(_key, _params, _merkleProof, address(0));
    }

    /**
     * Actions a swap using the SwapParams provided against the PoolKey with a referrer.
     *
     * @param _key The PoolKey to swap against
     * @param _params The parameters for the swap
     * @param _merkleProof The merkle proof for the whitelist spot
     * @param _referrer The referrer of the swap
     *
     * @return delta_ The BalanceDelta of the swap
     */
    function swap(
        PoolKey memory _key,
        IPoolManager.SwapParams memory _params,
        bytes32[] memory _merkleProof,
        address _referrer
    ) public payable virtual returns (BalanceDelta delta_) {
        PoolId poolId = _key.toId();
        (bytes32 root,, uint maxTokens, bool active,) = whitelistFairLaunch.whitelistMerkles(poolId);

        // Check that the sender is on the whitelist. We only need to validate our whitelist
        // is active.
        if (active && !MerkleProofLib.verify(_merkleProof, root, keccak256(abi.encode(msg.sender)))) {
            revert MerkleVerificationFailed();
        }

        // Action the swap which should now be whitelisted
        delta_ = abi.decode(
            manager.unlock(abi.encode(CallbackData(msg.sender, _key, _params, _referrer))),
            (BalanceDelta)
        );

        // Increase the amount of tokens that the user has claimed
        tokensClaimed[_key.toId()][msg.sender] += uint(-int(delta_.amount0() < 0 ? delta_.amount0() : delta_.amount1()));

        // Confirm the amount that the user has claimed in this whitelist does not surpass the
        // maximum. If there is no maxTokens value set, then we don't need to make this check.
        if (maxTokens != 0 && tokensClaimed[_key.toId()][msg.sender] > maxTokens) {
            // If the user has already claimed their allocation, then we need to prevent the swap
            revert TooManyTokensClaimed();
        }
    }

    /**
     * Routes the existing swap logic that is inherited through the merkle approach.
     */
    function swap(PoolKey memory _key, IPoolManager.SwapParams memory _params) public payable override returns (BalanceDelta) {
        return swap(_key, _params, new bytes32[](0), address(0));
    }

    function swap(PoolKey memory _key, IPoolManager.SwapParams memory _params, address _referrer) public payable override returns (BalanceDelta) {
        return swap(_key, _params, new bytes32[](0), _referrer);
    }

}
