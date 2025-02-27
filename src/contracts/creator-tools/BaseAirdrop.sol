// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from '@solady/auth/Ownable.sol';
import {SafeTransferLib} from '@solady/utils/SafeTransferLib.sol';

import {EnumerableSet} from '@openzeppelin/contracts/utils/structs/EnumerableSet.sol';

import {IFLETH} from '@flaunch-interfaces/IFLETH.sol';
import {ITreasuryManagerFactory} from '@flaunch-interfaces/ITreasuryManagerFactory.sol';

import {IBaseAirdrop} from '@flaunch-interfaces/IBaseAirdrop.sol';

contract BaseAirdrop is Ownable, IBaseAirdrop {

    using EnumerableSet for EnumerableSet.AddressSet;

    /// The addresses of approved airdrop creators
    EnumerableSet.AddressSet internal _approvedAirdropCreators;

    /// Our {FLETH} token contract address
    IFLETH public immutable fleth;

    /// The {TreasuryManagerFactory} contract address
    ITreasuryManagerFactory public immutable treasuryManagerFactory;

    /**
     * Sets our Ownable owner to the caller and maps our contract addresses.
     *
     * @param _fleth The {FLETH} contract address
     * @param _treasuryManagerFactory The {ITreasuryManagerFactory} contract address
     */
    constructor(address _fleth, address _treasuryManagerFactory) {
        _initializeOwner(msg.sender);

        fleth = IFLETH(_fleth);
        treasuryManagerFactory = ITreasuryManagerFactory(_treasuryManagerFactory);
    }

    /**
     * Allows the owner to set the approved airdrop creator contracts.
     *
     * @dev This call will revert if the `_contract` is already the `_approved` state.
     *
     * @param _contract The contract to be updated
     * @param _approved If the `_contract` should be approved (`true`) or unapproved (`false`)
     */
    function setApprovedAirdropCreators(address _contract, bool _approved) external override(IBaseAirdrop) onlyOwner {
        if (_approved) {
            if (!_approvedAirdropCreators.add(_contract)) revert ApprovedAirdropCreatorAlreadyAdded();
            emit ApprovedAirdropCreatorAdded(_contract);
        } else {
            if (!_approvedAirdropCreators.remove(_contract)) revert ApprovedAirdropCreatorNotPresent();
            emit ApprovedAirdropCreatorRemoved(_contract);
        }
    }

    /**
     * Returns the list of approved airdrop creators.
     *
     * @dev This function is designed for off-chain usage.
     *
     * @return address[] The approved airdrop creator addresses
     */
    function getApprovedAirdropCreators() external view override(IBaseAirdrop) returns (address[] memory) {
        return _approvedAirdropCreators.values();
    }

    /**
     * Returns whether the given contract is an approved airdrop creator.
     *
     * @param _contract The contract address to check
     *
     * @return If the contract is approved
     */
    function isApprovedAirdropCreator(address _contract) external view override(IBaseAirdrop) returns (bool) {
        return _approvedAirdropCreators.contains(_contract);
    }

    /**
     * Pulls in the tokens from the sender. Handles ETH to flETH wrapping.
     * 
     * @param _token The token to pull in
     * @param _amount The amount of tokens to pull in
     * 
     * @return amount The amount of tokens pulled in
     */
    function _pullTokens(address _token, uint _amount) internal returns (uint amount) {
        // If our deposit is in ETH, then we wrap this into FLETH
        amount = _amount;
        if (_token == address(0)) {
            amount = msg.value;
            fleth.deposit{value: amount}(0);
        }
        // Otherwise, we can pull in the IERC20 tokens directly from the sender
        else {
            // If ETH was also sent to the call, revert this as we don't handle multiple
            // token type submissions.
            if (msg.value != 0) revert ETHSentForTokenAirdrop();
            SafeTransferLib.safeTransferFrom(_token, msg.sender, address(this), amount);
        }
    }

    /**
      * Withdraws an airdrop allocation to the `msg.sender`.
      *
      * @param _token The token to claim from the airdrop
      * @param _amount The amount of tokens to claim
      */
    function _withdraw(address _token, uint _amount) internal {
        // If the airdrop was added as ETH, then it will have been wrapped into flETH during
        // the process. For this reason, we need to unwrap it first to return it to it's
        // original token state.
        if (_token == address(0)) {
            fleth.withdraw(_amount);
            SafeTransferLib.safeTransferETH(msg.sender, _amount);
        }
        // Otherwise, we can just safe transfer the tokens to the recipient
        else {
            SafeTransferLib.safeTransfer(_token, msg.sender, _amount);
        }
    }

    /**
     * Checks that the calling address is either an approved creator, or if we determine that
     * it is a treasury manager implementation deployment then we check if the implementation
     * is an approved creator.
     */
    modifier onlyApprovedAirdropCreators() {
        if (
            !_approvedAirdropCreators.contains(msg.sender) &&
            !_approvedAirdropCreators.contains(treasuryManagerFactory.managerImplementation(msg.sender))
        ) revert NotApprovedAirdropCreator();
        _;
    }

    /**
     * To receive ETH from flETH on withdraw.
     */
    receive() external payable {}
}