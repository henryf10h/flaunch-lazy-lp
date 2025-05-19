// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {EnumerableSet} from '@openzeppelin/contracts/utils/structs/EnumerableSet.sol';
import {IERC721} from '@openzeppelin/contracts/token/ERC721/IERC721.sol';

import {FullMath} from '@uniswap/v4-core/src/libraries/FullMath.sol';

import {FeeSplitManager} from '@flaunch/treasury/managers/FeeSplitManager.sol';


/**
 * This contract allows holders of any number of cross-chain ERC721 contract to receive an allocation
 * from all memestreams held within the manager.
 */
contract ERC721OwnerFeeSplitManager is FeeSplitManager {

    using EnumerableSet for EnumerableSet.UintSet;

    error DuplicateTokenId(address _erc721, uint _tokenId);
    error InvalidClaimParams();
    error InvalidInitializeParams();

    event ManagerInitialized(address _owner, InitializeParams _params);
    event Response(bytes32 indexed _requestId, bytes _response, bytes _err);
    event RevenueClaimed(address indexed _recipient, address _erc721, uint _tokenId, uint _amountClaimed, uint _totalClaimed);

    /**
     * When initializing our manager we define an array of ERC721 contracts that will receive a
     * share of the fees earned.
     *
     * @member shares Metadata for the ERC721 contracts
     */
    struct InitializeParams {
        uint creatorShare;
        ERC721Share[] shares;
    }

    /**
     * Defines the ERC721 data required to query and confirm ownership, as well as the fee share
     * that is offered to it.
     *
     * We cannot depend on the ERC721 to implement enumerable, so we must capture a totalSupply
     * from the initializing user. If this number is entered incorrectly, then it would just
     * result is funds being distributed incorrectly.
     *
     * @member erc721 The address of the ERC721 contract
     * @member chain The chain ID that the ERC721 is deployed on
     * @member share The share percentage (to 5dp) that the collection will receive
     * @member totalSupply The total number of NFTs in the collection
     */
    struct ERC721Share {
        address erc721;
        uint share;
        uint totalSupply;
    }

    /**
     * The parameters required to be passed when making a claim, defining the ERC721 address and
     * the tokens that are being claimed against.
     *
     * @member erc721 Array of ERC721 contract addresses being claimed against
     * @member tokenIds The tokenIds being claimed against for each respective ERC721
     */
    struct ClaimParams {
        address[] erc721;
        uint[][] tokenIds;
    }

    /// ERC721 share metadata for each contract address
    mapping (address _erc721 => ERC721Share _share) public erc721Shares;

    /// Track the amount claimed for each ERC721 tokenId
    mapping (address _erc721 => mapping (uint _tokenId => uint _claimed)) public amountClaimed;

    /**
     * Sets up the contract with the initial required contract addresses.
     *
     * @param _treasuryManagerFactory The {TreasuryManagerFactory} that will launch this implementation
     */
    constructor (address _treasuryManagerFactory) FeeSplitManager(_treasuryManagerFactory) {
        // ..
    }

    /**
     * Registers the owner of the manager, the ERC721 contract recipients and their
     * respective shares.
     *
     * @param _owner Owner of the manager
     * @param _data Onboarding variables
     */
    function _initialize(address _owner, bytes calldata _data) internal override {
        // Unpack our initial manager settings
        (InitializeParams memory params) = abi.decode(_data, (InitializeParams));

        // Ensure that our provided data is not zero and matches
        uint erc721SharesLength = params.shares.length;
        if (erc721SharesLength == 0) revert InvalidInitializeParams();

        emit ManagerInitialized(_owner, params);

        // Validate and set our creator share
        _setCreatorShare(params.creatorShare);

        // Ensure that each of our provided ERC721 params are correct
        uint totalCollectionShares;
        ERC721Share memory erc721Share;

        for (uint i; i < erc721SharesLength; ++i) {
            erc721Share = params.shares[i];
            if (erc721Share.erc721 == address(0) || erc721Share.totalSupply == 0 || erc721Share.share == 0) {
                revert InvalidInitializeParams();
            }

            // Set up a mapping for the ERC721Share
            erc721Shares[erc721Share.erc721] = erc721Share;

            // Increase our total shares for validation
            totalCollectionShares += erc721Share.share;
        }

        // Ensure that our collection shares equal 100%
        if (totalCollectionShares != VALID_SHARE_TOTAL) {
            revert InvalidRecipientShareTotal(totalCollectionShares, VALID_SHARE_TOTAL);
        }
    }

    /**
     * Without `_data` we can only find the pending creator fees.
     *
     * @param _recipient The account to find the balance of
     *
     * @return balance_ The amount of ETH available to claim by the `_recipient`
     */
    function balances(address _recipient) public view override returns (uint balance_) {
        balance_ += pendingCreatorFees(_recipient);
    }

    /**
     * Allow for a view function with `_data` to find both pending creator fees and
     * `ClaimParams` fees.
     *
     * @param _recipient The account to find the balance of
     *
     * @return balance_ The amount of ETH available to claim by the `_recipient`
     */
    function balances(address _recipient, bytes calldata _data) public view returns (uint balance_) {
        // Calculate the amount that each token should be offered based on the total allocation
        // amount, regardless of what has already been claimed.
        (ClaimParams memory claimParams) = abi.decode(_data, (ClaimParams));

        // Iterate over the ERC721 contracts being claimed against
        for (uint i; i < claimParams.erc721.length; ++i) {
            // For each ERC721, iterate over the tokenIds
            for (uint k; k < claimParams.tokenIds[i].length; ++k) {
                // Increase our allocation based on the amount claimed from the token
                balance_ += _tokenClaimAvailable(claimParams.erc721[i], claimParams.tokenIds[i][k]);
            }
        }

        balance_ += pendingCreatorFees(_recipient);
    }

    /**
     * Make a claim against the user's `ClaimParam`s.
     *
     * @param _data Encoded `ClaimParam`s
     *
     * @return amount_ The amount claimed from the call
     */
    function claim(bytes calldata _data) public returns (uint amount_) {
        amount_ = _claim(_data);
    }

    /**
     * Determines the percentage share that a recipient address is allocated from the whole
     * of the revenue fees, based on the ERC721 tokenIds provided.
     *
     * @param _recipient We don't process the recipient address
     * @param _data The `ClaimParams` used to determine the recipient share
     *
     * @return recipientShare_ The percentage (to 5dp) that the recipient is allocated
     */
    function recipientShare(address _recipient, bytes memory _data) public view override returns (uint recipientShare_) {
        // Unpack our claim parameters
        (ClaimParams memory claimParams) = abi.decode(_data, (ClaimParams));

        // Store our variable as loop-external variables
        ERC721Share memory erc721Share;
        uint tokenIds;

        // Iterate over our claim ERC721s to find the recipient shares based on the share amounts
        // specified at initialization.
        for (uint i; i < claimParams.erc721.length; ++i) {
            erc721Share = erc721Shares[claimParams.erc721[i]];
            tokenIds = claimParams.tokenIds[i].length;

            // If no tokenIds are set, then we can skip over it
            if (tokenIds == 0) {
                continue;
            }

            // Increase the recipient share
            recipientShare_ += (erc721Share.share / erc721Share.totalSupply) * tokenIds;
        }
    }

    /**
     * Checks if the recipient has ownership of same-chain tokenIds.
     *
     * @param _recipient The expected owner of the ERC721 token
     * @param _erc721 The contract address of the ERC721
     * @param _tokenId The tokenId of the ERC721
     *
     * @return bool If the token is owned by the recipient
     */
    function hasOwnership(address _recipient, address _erc721, uint _tokenId) internal view returns (bool) {
        // Handle case where the token has been burned. This is wrapped in a try/catch as we don't
        // want to revert if the token has a zero address owner (the default ERC721 logic).
        try IERC721(_erc721).ownerOf(_tokenId) returns (address owner) {
            return owner == _recipient;
        } catch {}

        return false;
    }

    /**
     * Checks if the recipient is valid to receive the allocation with the data that has been
     * provided. This is based on if they have ownership of same-chain tokenIds.
     *
     * @param _recipient The recipient address to check against same-chain tokenIds
     * @param _data The `ClaimParams` used to determine the if the recipient is valid
     *
     * @return bool If the recipient is valid to receive an allocation
     */
    function isValidRecipient(address _recipient, bytes memory _data) public view override returns (bool) {
        // Unpack our claim parameters
        (ClaimParams memory claimParams) = abi.decode(_data, (ClaimParams));

        // Validate the claim parameters
        _validateClaimParams(claimParams);

        // Iterate over our ERC721 contracts and their respective tokenIds to confirm that the user
        // has same-chain ownership.
        for (uint i; i < claimParams.erc721.length; ++i) {
            for (uint k; k < claimParams.tokenIds[i].length; ++k) {
                // Validates that the recipient has ownership of the tokenId
                if (!hasOwnership(_recipient, claimParams.erc721[i], claimParams.tokenIds[i][k])) {
                    return false;
                }
            }
        }

        return true;
    }

    /**
     * Takes the total fee amount that the tokenIds are calculated to receive over all time. This must
     * then be reduced by any previously claimed fees, by any tokenIds that are required to be checked.
     *
     * @dev The ownership of the provided tokens has already been verified
     *
     * @param _recipient We don't process the recipient address
     * @param _data Any additional data required by the manager to calculate
     *
     * @return allocation_ The allocation claimed by the user
     */
    function _captureClaim(address _recipient, bytes memory _data) internal override returns (uint allocation_) {
        // Calculate the amount that each token should be offered based on the total allocation
        // amount, regardless of what has already been claimed.
        (ClaimParams memory claimParams) = abi.decode(_data, (ClaimParams));

        address erc721;
        uint tokenId;

        // Iterate over the ERC721 contracts being claimed against
        for (uint i; i < claimParams.erc721.length; ++i) {
            // For each ERC721, iterate over the tokenIds
            for (uint k; k < claimParams.tokenIds[i].length; ++k) {
                erc721 = claimParams.erc721[i];
                tokenId = claimParams.tokenIds[i][k];

                uint tokenClaimAmount = _tokenClaimAvailable(erc721, tokenId);

                // If we have a claim about to be made, increase the amount claimed against this token
                if (tokenClaimAmount != 0) {
                    // Increase our allocation based on the amount claimed from the token
                    allocation_ += tokenClaimAmount;

                    // Increase the amount claimed for the token to offset future amounts
                    amountClaimed[erc721][tokenId] += tokenClaimAmount;

                    // Emit an event showing the amount claimed for the token
                    emit RevenueClaimed(msg.sender, erc721, tokenId, tokenClaimAmount, amountClaimed[erc721][tokenId]);
                }
            }
        }

        // Iterate over the tokens that the user created to register the claim
        for (uint i; i < _creatorTokens[_recipient].length(); ++i) {
            allocation_ += _creatorClaim(internalIds[_creatorTokens[_recipient].at(i)]);
        }
    }

    /**
     * Finds the amount that is claimable for an individual token.
     *
     * @param _erc721 The address of the ERC721 token contract
     * @param _tokenId The tokenId of the ERC721 token
     *
     * @return claimAvailable_ The total amount of claims available
     */
    function _tokenClaimAvailable(address _erc721, uint _tokenId) internal view returns (uint claimAvailable_) {
        /**
         * Find the total amount all time claimed into manager (splitFees) find the share of the
         * individual token (`erc721Shares[erc721].share / totalSupply`). We then minus the amount
         * already claimed by the token (`amountClaimed[erc721][tokenId]`).
         *
         * The creator fees are already reduced in the splitFees.
         */
        ERC721Share memory erc721Share = erc721Shares[_erc721];
        claimAvailable_ = FullMath.mulDiv(splitFees, erc721Share.share, erc721Share.totalSupply);
        claimAvailable_ /= VALID_SHARE_TOTAL;

        // Reduce the amount we can claim for the token based on the amount that has already
        // been claimed against it over all time.
        claimAvailable_ -= amountClaimed[_erc721][_tokenId];
    }

    /**
     * Transfers the revenue fee allocation to the recipient.
     *
     * @param _recipient The recipient address to claim against
     * @param _allocation The total fees allocated to the recipient
     */
    function _dispatchRevenue(address _recipient, uint _allocation, bytes memory _data) internal override {
        // Send the ETH fees to the recipient
        (bool success, bytes memory data) = payable(_recipient).call{value: _allocation}('');
        if (!success) {
            revert UnableToSendRevenue(data);
        }
    }

    /**
     * Validates claim parameters to ensure no duplicate ERC721 + tokenId combinations.
     *
     * @dev Uses a hash-based array approach for duplicate detection, which is not an efficient approach
     * but is the only way to ensure that we don't have to iterate over the entire array of tokenIds.
     *
     * @param _claimParams The claim parameters to validate
     */
    function _validateClaimParams(ClaimParams memory _claimParams) internal pure {
        // Basic validation to ensure lengths are correct
        if (_claimParams.erc721.length == 0 || _claimParams.erc721.length != _claimParams.tokenIds.length) {
            revert InvalidClaimParams();
        }
        
        // Calculate the maximum possible number of token combinations
        uint maxTokenCount;
        for (uint i; i < _claimParams.erc721.length; ++i) {
            maxTokenCount += _claimParams.tokenIds[i].length;
        }
        
        // Create an array to track seen token hashes
        bytes32[] memory seenTokenHashes = new bytes32[](maxTokenCount);
        uint seenTokensCount;
        
        address erc721Contract;
        uint tokenId;
        bytes32 tokenHash;
        
        // Iterate through each ERC721 contracts
        for (uint i; i < _claimParams.erc721.length; ++i) {
            erc721Contract = _claimParams.erc721[i];
            
            // For each token ID in this contract, check if this combination has been seen before
            for (uint k; k < _claimParams.tokenIds[i].length; ++k) {
                tokenId = _claimParams.tokenIds[i][k];
                
                // Create a unique hash for this erc721 + tokenId combination
                tokenHash = keccak256(abi.encodePacked(erc721Contract, tokenId));
                
                // Check if we've already seen this token
                for (uint j; j < seenTokensCount; ++j) {
                    if (seenTokenHashes[j] == tokenHash) {
                        revert DuplicateTokenId(erc721Contract, tokenId);
                    }
                }
                
                // Mark this combination as seen
                seenTokenHashes[seenTokensCount] = tokenHash;
                ++seenTokensCount;
            }
        }
    }

}
