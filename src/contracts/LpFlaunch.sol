// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Initializable} from '@solady/utils/Initializable.sol';
import {ERC721} from '@solady/tokens/ERC721.sol';
import {LibClone} from '@solady/utils/LibClone.sol';
import {LibString} from '@solady/utils/LibString.sol';
import {Ownable} from '@solady/auth/Ownable.sol';

import {PoolId} from '@uniswap/v4-core/src/types/PoolId.sol';

import {AnyPositionManager} from '@flaunch/AnyPositionManager.sol';

import {IAnyFlaunch} from '@flaunch-interfaces/IAnyFlaunch.sol';


/**
 * The Flaunch ERC721 NFT that is created when a new position is by the {AnyPositionManager} flaunched.
 * This is used to prove ownership of a pool, so transferring this token would result in a new
 * pool creator being assigned.
 */
contract LpFlaunch is ERC721, IAnyFlaunch, Initializable, Ownable {

    error BaseURICannotBeEmpty();
    error CallerIsNotPositionManager();
    error CreatorFeeAllocationInvalid(uint24 _allocation, uint _maxAllocation);

    event BaseURIUpdated(string _newBaseURI);
    event MemecoinTreasuryImplementationUpdated(address _newImplementation);

    /**
     * Stores related memecoin contract implementation addresses.
     *
     * @member memecoin The ERC20 {Memecoin} address
     * @member memecoinTreasury The {MemecoinTreasury} address
     */
    struct TokenInfo {
        address memecoin;
        address payable memecoinTreasury;
        address creator;
    }

    /// The maximum value of a creator's fee allocation
    uint public constant MAX_CREATOR_ALLOCATION = 100_00;

    /// Our basic token information
    string internal _name = 'Flaunch Revenue Streams (Imported)';
    string internal _symbol = 'FLAUNCH';

    /// The base URI to represent the metadata
    string public baseURI;

    /// Stores the next tokenId that will be minted. This can be used as an indication of how
    /// many tokens currently exist in the protocol.
    uint public nextTokenId = 1;

    /// The Flaunch {AnyPositionManager} contract
    AnyPositionManager public positionManager;

    /// Our treasury implementation that will be deployed when a new token is added
    address public memecoinTreasuryImplementation;

    /// Maps `TokenInfo` for each token ID
    mapping (uint _tokenId => TokenInfo _tokenInfo) internal tokenInfo;

    /// Maps a {Memecoin} ERC20 address to it's token ID
    mapping (address _memecoin => uint _tokenId) public tokenId;

    /**
     * References the contract addresses for the Flaunch protocol.
     *
     * @param _baseURI The default baseUri for the ERC721
     */
    constructor (string memory _baseURI) {
        // Ensure that our BaseURI is not an empty value
        if (bytes(_baseURI).length == 0) revert BaseURICannotBeEmpty();
        baseURI = _baseURI;

        _initializeOwner(msg.sender);
    }

    /**
     * Adds the {AnyPositionManager} and {MemecoinTreasury} implementation addresses required to
     * actually flaunch tokens, converting the contract from a satellite contract into a fully
     * fledged Flaunch protocol implementation.
     *
     * @param _positionManager The Flaunch {AnyPositionManager}
     * @param _memecoinTreasuryImplementation The {MemecoinTreasury} implementation address
     */
    function initialize(AnyPositionManager _positionManager, address _memecoinTreasuryImplementation) external onlyOwner initializer {
        positionManager = _positionManager;
        memecoinTreasuryImplementation = _memecoinTreasuryImplementation;
    }

    /**
     * Adds a new token, deploying the required implementations and creating a new ERC721. The
     * tokens are sent to the `_creator` to prove ownership of the pool.
     */
    function flaunch(
        AnyPositionManager.FlaunchParams calldata _params
    ) external override onlyPositionManager returns (
        address payable memecoinTreasury_,
        uint tokenId_
    ) {
        // A creator cannot set their allocation above a threshold
        if (_params.creatorFeeAllocation > MAX_CREATOR_ALLOCATION) revert CreatorFeeAllocationInvalid(_params.creatorFeeAllocation, MAX_CREATOR_ALLOCATION);

        // Store the current token ID and increment the next token ID
        tokenId_ = nextTokenId;
        unchecked { nextTokenId++; }


        // mint ownership token to the positionManager instead.
        _mint(address(positionManager), tokenId_); 
        
        

        // Store the token ID
        tokenId[_params.memecoin] = tokenId_;

        // Deploy the memecoin treasury
        memecoinTreasury_ = payable(
            LibClone.cloneDeterministic(memecoinTreasuryImplementation, bytes32(tokenId_))
        );

        // Store the token info
        // update tokenInfo to include creator address ... _params.creator
        tokenInfo[tokenId_] = TokenInfo(_params.memecoin, memecoinTreasury_, _params.creator);
    }

    /**
     * Allows a contract owner to update the base URI for the creator ERC721 tokens.
     * 
     * @param _baseURI The new base URI
     */
    function setBaseURI(string memory _baseURI) external onlyOwner {
        // Ensure that our BaseURI is not an empty value
        if (bytes(_baseURI).length == 0) revert BaseURICannotBeEmpty();
        baseURI = _baseURI;
        emit BaseURIUpdated(_baseURI);
    }

    /**
     * Allows the contract owner to update the memecoin treasury implementation address.
     * 
     * @param _memecoinTreasuryImplementation The new memecoin treasury implementation address
     */
    function setMemecoinTreasuryImplementation(address _memecoinTreasuryImplementation) external onlyOwner {
        memecoinTreasuryImplementation = _memecoinTreasuryImplementation;
        emit MemecoinTreasuryImplementationUpdated(_memecoinTreasuryImplementation);
    }

    /**
     * Returns the ERC721 name.
     */
    function name() public view override returns (string memory) {
        return _name;
    }

    /**
     * Returns the ERC721 symbol.
     */
    function symbol() public view override returns (string memory) {
        return _symbol;
    }

    /**
     * Returns the Uniform Resource Identifier (URI) for token id.
     *
     * @dev We prevent the token from erroring if it was burned, and instead we just check against
     * the current tokenId iteration we have stored.
     *
     * @param _tokenId The token ID to get the URI for
     */
    function tokenURI(uint _tokenId) public view override returns (string memory) {
        // If we are ahead of our tracked tokenIds, then revert
        if (_tokenId == 0 || _tokenId >= nextTokenId) revert TokenDoesNotExist();

        // Concatenate the base URI and the token ID
        return LibString.concat(baseURI, LibString.toString(_tokenId));
    }

    /**
     * Helpers to show the {Memecoin} address for the ERC721.
     *
     * @param _tokenId The token ID to get the {Memecoin} for
     *
     * @return address {Memecoin} address
     */
    function memecoin(uint _tokenId) public view returns (address) {
        return tokenInfo[_tokenId].memecoin;
    }

    /**
     * Returns the {MemecoinTreasury} address for the memecoin.
     *
     * @param _memecoin The {Memecoin} address
     */
    function memecoinTreasury(address _memecoin) public view returns (address payable) {
        return tokenInfo[tokenId[_memecoin]].memecoinTreasury;
    }

    /**
     * Helper to show the {PoolId} address for the ERC721 token.
     *
     * @param _tokenId The token ID to get the {PoolId} for
     *
     * @return PoolId The {PoolId} for the token
     */
    function poolId(uint _tokenId) public view returns (PoolId) {
        return positionManager.poolKey(tokenInfo[_tokenId].memecoin).toId();
    }

    /**
    * @dev Returns the creator of the token as stored in TokenInfo struct
    * @param _memecoin The memecoin address
    * @return The address of the token creator
    */
    function creator(address _memecoin) public view returns (address) {
        uint256 _tokenId = tokenId[_memecoin];
        return tokenInfo[_tokenId].creator;
    }

    /**
    * @dev Returns the actual owner of the NFT (position manager)
    * @param _memecoin The memecoin address
    * @return The address of the NFT owner (position manager)
    */
    function nftManager(address _memecoin) public view returns (address) {
        uint256 _tokenId = tokenId[_memecoin];
        return ownerOf(_tokenId);
    }

    /**
     * Helpers to show the {MemecoinTreasury} address for the ERC721.
     *
     * @param _tokenId The token ID to get the {MemecoinTreasury} for
     *
     * @return address {MemecoinTreasury} address
     */
    function memecoinTreasury(uint _tokenId) public view returns (address payable) {
        return tokenInfo[_tokenId].memecoinTreasury;
    }

    /**
     * Burns `tokenId` by sending it to `address(0)`.
     *
     * @dev The caller must own `tokenId` or be an approved operator.
     *
     * @param _tokenId The token ID to check
     */
    function burn(uint _tokenId) public {
        _burn(msg.sender, _tokenId);
    }

    /**
     * Ensures that only the immutable {AnyPositionManager} can call the function.
     */
    modifier onlyPositionManager() {
        if (msg.sender != address(positionManager)) {
            revert CallerIsNotPositionManager();
        }
        _;
    }

    /**
     * Override to return true to make `_initializeOwner` prevent double-initialization.
     *
     * @return bool Set to `true` to prevent owner being reinitialized.
     */
    function _guardInitializeOwner() internal pure override returns (bool) {
        return true;
    }
}