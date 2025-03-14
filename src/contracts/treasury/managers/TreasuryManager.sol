// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Flaunch} from '@flaunch/Flaunch.sol';
import {ProtocolRoles} from '@flaunch/libraries/ProtocolRoles.sol';
import {TreasuryManagerFactory} from '@flaunch/treasury/managers/TreasuryManagerFactory.sol';

import {ITreasuryManager} from '@flaunch-interfaces/ITreasuryManager.sol';


/**
 * Acts as a middleware for revenue claims, allowing external protocols to build on top of Flaunch
 * and be able to have more granular control over the revenue yielded.
 */
abstract contract TreasuryManager is ITreasuryManager {

    error FlaunchContractNotValid();
    error NotManagerOwner();
    error TokenTimelocked(uint _unlockedAt);

    event ManagerOwnershipTransferred(address indexed _previousOwner, address indexed _newOwner);
    event TreasuryEscrowed(address indexed _flaunch, uint indexed _tokenId, address _owner, address _sender);
    event TreasuryReclaimed(address indexed _flaunch, uint indexed _tokenId, address _sender, address _recipient);
    event TreasuryTimelocked(address indexed _flaunch, uint indexed _tokenId, uint _unlockedAt);

    /// The {TreasuryManagerFactory} that will launch this implementation
    TreasuryManagerFactory public immutable treasuryManagerFactory;

    /// The owner of the tokens that are depositted
    address public managerOwner;

    /// Creates a standardised timelock mechanism for tokens
    mapping (address _flaunch => mapping (uint _tokenId => uint _unlockedAt)) public tokenTimelock;

    /**
     * Sets up the contract with the initial required contract addresses.
     *
     * @param _treasuryManagerFactory The {TreasuryManagerFactory} that will launch this implementation
     */
    constructor (address _treasuryManagerFactory) {
        treasuryManagerFactory = TreasuryManagerFactory(_treasuryManagerFactory);
    }

    /**
     * Escrow an ERC721 token by transferring it to this contract and recording the original
     * owner.
     *
     * @param _flaunchToken The Flaunch token that is being initialized
     * @param _owner The address to have ownership over the tokens
     * @param _data Additional manager initialization data
     */
    function initialize(FlaunchToken calldata _flaunchToken, address _owner, bytes calldata _data) public {
        // Set the owner if one is not already set.
        if (managerOwner == address(0)) {
            managerOwner = _owner;
        }

        // Validate the Flaunch contract
        if (!_isValidFlaunchContract(address(_flaunchToken.flaunch))) {
            revert FlaunchContractNotValid();
        }

        // Transfer the token from the msg.sender to the contract
        _flaunchToken.flaunch.transferFrom(msg.sender, address(this), _flaunchToken.tokenId);
        emit TreasuryEscrowed(address(_flaunchToken.flaunch), _flaunchToken.tokenId, _owner, msg.sender);

        _initialize(_flaunchToken, _data);
    }

    /**
     * An internal initialization function that is overwritten by the managers that extend
     * this contract.
     *
     * @param _flaunchToken ..
     * @param _data Additional data bytes that can be unpacked
     */
    function _initialize(FlaunchToken calldata _flaunchToken, bytes calldata _data) internal virtual {
        // ..
    }

    /**
     * Rescues the ERC721, extracting it from the manager and transferring it to a recipient.
     *
     * @dev Only the owner can make this call.
     *
     * @param _flaunchToken The token to rescue
     * @param _recipient The recipient to receive the ERC721
     */
    function rescue(FlaunchToken calldata _flaunchToken, address _recipient) public virtual onlyManagerOwner {
        // Validate the Flaunch contract
        if (!_isValidFlaunchContract(address(_flaunchToken.flaunch))) {
            revert FlaunchContractNotValid();
        }

        // Ensure that the token is either not timelocked (zero value) or the timelock has passed
        uint unlockedAt = tokenTimelock[address(_flaunchToken.flaunch)][_flaunchToken.tokenId];
        if (block.timestamp < unlockedAt) {
            revert TokenTimelocked(unlockedAt);
        }

        // Remove the timelock on the token
        delete tokenTimelock[address(_flaunchToken.flaunch)][_flaunchToken.tokenId];

        // Transfer the token to the recipient from the contract. If the token is not held by
        // this contract then this call will revert.
        _flaunchToken.flaunch.transferFrom(address(this), _recipient, _flaunchToken.tokenId);

        emit TreasuryReclaimed(address(_flaunchToken.flaunch), _flaunchToken.tokenId, managerOwner, _recipient);
    }

    /**
     * Transfers ownership of the contract to a new account (`newOwner`).
     *
     * @dev Can only be called by the current owner.
     *
     * @param _newManagerOwner The new address that will become the owner
     */
    function transferOwnership(address _newManagerOwner) public onlyManagerOwner {
        emit ManagerOwnershipTransferred(managerOwner, _newManagerOwner);
        managerOwner = _newManagerOwner;
    }

    /**
     * Checks if the specified address is a valid Flaunch contract.
     */
    function _isValidFlaunchContract(address _flaunch) internal view returns (bool) {
        return treasuryManagerFactory.hasRole(ProtocolRoles.FLAUNCH, _flaunch);
    }

    /**
     * Allows for protected calls that only the manager owner can make.
     */
    modifier onlyManagerOwner {
        if (msg.sender != managerOwner) {
            revert NotManagerOwner();
        }

        _;
    }

    /**
     * Allows the contract to receive ETH when withdrawn from the flETH token.
     */
    receive () external payable {}

}
