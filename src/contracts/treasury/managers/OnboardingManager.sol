// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Flaunch} from '@flaunch/Flaunch.sol';
import {FlayBurner} from '@flaunch/libraries/FlayBurner.sol';
import {SingleTokenManager} from '@flaunch/treasury/managers/SingleTokenManager.sol';

import {ISnapshotAirdrop} from '@flaunch-interfaces/ISnapshotAirdrop.sol';
import {IFLETH} from '@flaunch-interfaces/IFLETH.sol';


/**
 * Allows an ERC721 to be locked inside an onboarding manager that can be claimed by a designated
 * wallet address when wanted.
 *
 * Fees will be collected on behalf of an `onboardee` until they claim the ERC721, at which point
 * they will receive a set amount of the fees collected, and the remaining fees will be distributed
 * to holders via the {ISnapshotAirdrop} contract.
 */
contract OnboardingManager is SingleTokenManager {

    error CannotRescueToken();
    error InsufficientClaimWindow();
    error InvalidClaimer();
    error InvalidOnboardeeAllocation();
    error OnboardeeUnableToClaimETH();
    error OnboardingWindowClosed();
    error OnboardingWindowNotClosed();
    error TokenAlreadyClaimed();

    event ManagerInitialized(address indexed _flaunch, uint indexed _tokenId, InitializeParams _params);
    event OnboardeeUpdated(address _onboardee);

    event OnboardeeClaim(address indexed _flaunch, uint indexed _tokenId, address _onboardee, uint _onboardeeAmount, uint _publicAmount, uint _airdropIndex);
    event OnboardeeReleased(address indexed _flaunch, uint indexed _tokenId, address _onboardee, uint _buyBack);

    /**
     * Parameters passed during manager initialization.
     */
    struct InitializeParams {
        address payable onboardee;
        uint onboardeeAllocation;
        uint claimWindowEnd;
    }

    /// The maximum value an onboardee allocation should be (100%)
    uint public constant MAX_ONBOARDEE_ALLOCATION = 100_00;

    /// The onboardee and their allocation percentage (2dp)
    address payable public onboardee;
    uint public onboardeeAllocation;

    /// The {ISnapshotAirdrop} contract used by the Flaunch protocol
    ISnapshotAirdrop public immutable airdropClaim;

    /// The {FlayBurner} contract
    FlayBurner public immutable flayBurner;

    /// The index of the airdrop created by the claim
    uint public airdropIndex;

    /// The `block.timestamp` at which the the claim window closes
    uint public claimWindowEnd;

    /// Stores if the token has been claimed
    bool public claimed;

    /**
     * Sets up the contract with the initial required contract addresses.
     *
     * @param _treasuryManagerFactory The {TreasuryManagerFactory} that will launch this implementation
     * @param _flayBurner The {FlayBurner} contract address
     * @param _airdropClaim The {ISnapshotAirdrop} contract that will distribute claims
     */
    constructor (address _treasuryManagerFactory, address payable _flayBurner, address _airdropClaim) SingleTokenManager(_treasuryManagerFactory) {
        airdropClaim = ISnapshotAirdrop(_airdropClaim);
        flayBurner = FlayBurner(_flayBurner);
    }

    /**
     * Registers the tokenId passed by the initialization and ensures that it is the only one
     * registered to the manager. We also set our initial configurations, though the majority
     * of these can be updated by the owner at a later date.
     *
     * @param _flaunchToken The Flaunch token that is being deposited
     * @param _data Onboarding variables
     */
    function _initialize(FlaunchToken calldata _flaunchToken, bytes calldata _data) internal override depositSingleToken(_flaunchToken) {
        // Unpack our initial configuration data
        (InitializeParams memory params) = abi.decode(_data, (InitializeParams));

        // Validate the passed parameters
        if (params.onboardeeAllocation > MAX_ONBOARDEE_ALLOCATION) {
            revert InvalidOnboardeeAllocation();
        }

        if (params.claimWindowEnd <= block.timestamp) {
            revert InsufficientClaimWindow();
        }

        // The rest can be assigned without further validation
        onboardee = params.onboardee;
        onboardeeAllocation = params.onboardeeAllocation;
        claimWindowEnd = params.claimWindowEnd;

        // Emit an event that shows our initial data
        emit ManagerInitialized(address(flaunchToken.flaunch), flaunchToken.tokenId, params);
    }

    /**
     * If the onboardee claims, they take a fixed percentage of any of the revenue earned whilst
     * the ERC721 has been under the ownership of this manager. The remaining ETH is dispersed to
     * holders via a snapshot airdrop.
     */
    function claim() public tokenExists onlyNotClaimed {
        // Ensure that only the onboardee can make the claim
        if (msg.sender != onboardee) {
            revert InvalidClaimer();
        }

        // Ensure that the timelock has passed
        if (block.timestamp > claimWindowEnd) {
            revert OnboardingWindowClosed();
        }

        // Mark the token as claimed
        claimed = true;

        // Transfer the token to the onboardee
        flaunchToken.flaunch.transferFrom(address(this), onboardee, flaunchToken.tokenId);

        // Claim the fees owed to the token, bringing all the ETH revenue into this contract
        flaunchToken.flaunch.positionManager().withdrawFees(address(this), true);

        // Calculate the amount of revenue earned and find the onboardee share
        uint revenue = payable(address(this)).balance;
        uint onboardeeAmount = revenue * onboardeeAllocation / 100_00;

        // Send the ETH to the onboardee, in addition to the ERC721 which will be sent by the
        // parent call.
        if (onboardeeAmount != 0) {
            // Ensure that the onboardee received the ETH, as otherwise this could result in
            // a large loss of trading fees. If this happens (onboardee is non-payable contract)
            // then it is possible to update the `onboardee` address.
            (bool sent,) = onboardee.call{value: onboardeeAmount}('');
            if (!sent) revert OnboardeeUnableToClaimETH();
        }

        // Determine the remaining amount that will be sent to the public airdrop
        uint publicAmount = revenue - onboardeeAmount;

        if (publicAmount != 0) {
            airdropIndex = airdropClaim.addAirdrop{value: publicAmount}({
                _memecoin: flaunchToken.flaunch.memecoin(flaunchToken.tokenId),
                _creator: address(this),
                _token: address(0),
                _amount: publicAmount,
                _airdropEndTime: block.timestamp + 4 weeks
            });
        }

         // Emit our onboardee claim event
        emit OnboardeeClaim(address(flaunchToken.flaunch), flaunchToken.tokenId, onboardee, onboardeeAmount, publicAmount, airdropIndex);
    }

    /**
     * If the onboardee does **not** claim during the onboarding window, then all of the ETH
     * accrued in fees goes into a $FLAY market buy. The $FLAY tokens purchased are subsequently
     * burned.
     *
     * @dev This function call does not need to mark the `claimed` boolean as true, as we burn
     * the ERC721. This means there is no way for it to re-enter the contract.
     */
    function release() public tokenExists onlyNotClaimed {
        // Ensure that the timelock has passed and ended
        if (block.timestamp <= claimWindowEnd) {
            revert OnboardingWindowNotClosed();
        }

        // Claim the fees owed to the token, bringing all the revenue in as flETH
        flaunchToken.flaunch.positionManager().withdrawFees(address(this), false);

        // Convert the ETH received into FLETH
        IFLETH fleth = flayBurner.fleth();
        fleth.deposit{value: address(this).balance}(0);

        // Capture the amount of flETH and emit our release event
        uint flethBalance = fleth.balanceOf(address(this));
        emit OnboardeeReleased(address(flaunchToken.flaunch), flaunchToken.tokenId, onboardee, flethBalance);

        // Action a market buy against our $FLAY token
        fleth.approve(address(flayBurner), flethBalance);
        flayBurner.buyAndBurn(flethBalance);

        // Burn the ERC721 ownership
        flaunchToken.flaunch.burn(flaunchToken.tokenId);
    }

    /**
     * Allows anyone to withdraw the remaining airdrop amount, after the airdrop has ended.
     */
    function recoverAirdrop() public tokenExists {
        // Reclaim fees from our airdrop as ETH
        airdropClaim.creatorWithdraw({
            _memecoin: flaunchToken.flaunch.memecoin(flaunchToken.tokenId),
            _airdropIndex: airdropIndex
        });

        // Convert the ETH received into FLETH before the market buy
        IFLETH fleth = flayBurner.fleth();
        fleth.deposit{value: address(this).balance}(0);

        // Action a market buy against our $FLAY token with the recovered fees
        uint flethBalance = fleth.balanceOf(address(this));

        fleth.approve(address(flayBurner), flethBalance);
        flayBurner.buyAndBurn(flethBalance);
    }

    /**
     * Updates the address of the onboardee in case they want to receive it to another address, or
     * if the ERC721 was managed before a wallet address was known. This value can be set to a zero
     * address if we are still awaiting a confirmed address.
     *
     * @dev This can only be called by the contract owner
     *
     * @param _onboardee The new Onboardee address
     */
    function setOnboardee(address payable _onboardee) public onlyManagerOwner onlyNotClaimed {
        onboardee = _onboardee;
        emit OnboardeeUpdated(_onboardee);
    }

    /**
     * This manager handles our Flaunch ERC721 withdrawals from specific function calls. For
     * this reason, we want to ensure that our expected flows are not bypassed with this function.
     */
    function rescue(FlaunchToken calldata /* _flaunchToken */, address /* _recipient */) public pure override {
        revert CannotRescueToken();
    }

    /**
     * Only allows the function call to be made if the token has not yet been claimed.
     */
    modifier onlyNotClaimed {
        if (claimed) revert TokenAlreadyClaimed();
        _;
    }

}
