// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';
import {SafeCast} from '@uniswap/v4-core/src/libraries/SafeCast.sol';

import {MerkleAirdrop} from '@flaunch/creator-tools/MerkleAirdrop.sol';

import {IFLETH} from '@flaunch-interfaces/IFLETH.sol';
import {ITreasuryAction} from '@flaunch-interfaces/ITreasuryAction.sol';


/**
 * If a {MemecoinTreasury} receives an allocation of tokens from a {MerkleAirdrop}, then this
 * contract allows them to claim it by proxy.
 */
contract ClaimFeesAction is ITreasuryAction {

    using SafeCast for uint;

    /// The {MerkleAirdrop} contract address
    MerkleAirdrop public immutable merkleAirdrop;

    /**
     * Defines the data struct required to be passed by the action call.
     *
     * @member creator The creator of the airdrop
     * @member airdropIndex The index of the airdrop
     * @member amount The amount of tokens to be claimed
     * @member merkleProof The merkle proof for the airdrop
     */
    struct ActionParams {
        address creator;
        uint airdropIndex;
        uint amount;
        bytes32[] merkleProof;
    }

    /**
     * Set the {MerkleAirdrop} contract address that we will be claiming from.
     *
     * @param _merkleAirdrop The {MerkleAirdrop} contract address
     */
    constructor (address payable _merkleAirdrop) {
        merkleAirdrop = MerkleAirdrop(_merkleAirdrop);
    }

    /**
     * Makes an approved proxy claim against the `MerkleClaim` contract, claiming on behalf
     * of the {MemecoinTreasury}.
     *
     * @param _poolKey The PoolKey to execute against
     * @param _data The `ActionParams` data that will define the claim
     */
    function execute(PoolKey memory _poolKey, bytes memory _data) external override {
        // Unpack the merkle claim information from `_data`
        ActionParams memory params = abi.decode(_data, (ActionParams));

        // Make the claim as a proxy for the memecoin treasury (the sender)
        merkleAirdrop.proxyClaim({
            _claimant: msg.sender,
            _creator: params.creator,
            _airdropIndex: params.airdropIndex,
            _amount: params.amount,
            _merkleProof: params.merkleProof
        });

        // If the claim was made in ETH, then we need to wrap it back into flETH as this
        // is the native token included in the PoolKey.
        uint ethBalance = payable(address(this)).balance;
        if (ethBalance != 0) {
            IFLETH(merkleAirdrop.fleth()).deposit{value: ethBalance}(0);
        }

        // Transfer the airdrop claimed tokens back to the caller
        uint amount0 = _poolKey.currency0.balanceOfSelf();
        uint amount1 = _poolKey.currency1.balanceOfSelf();

        if (amount0 != 0) {
            _poolKey.currency0.transfer(msg.sender, amount0);
        }

        if (amount1 != 0) {
            _poolKey.currency1.transfer(msg.sender, amount1);
        }

        emit ActionExecuted(_poolKey, amount0.toInt256(), amount1.toInt256());
    }

    /**
     * Allows ETH claims to be made.
     */
    receive () external payable {}

}
