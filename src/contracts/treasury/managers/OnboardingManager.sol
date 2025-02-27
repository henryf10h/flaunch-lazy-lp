// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Currency, CurrencyLibrary} from '@uniswap/v4-core/src/types/Currency.sol';
import {IPoolManager} from '@uniswap/v4-core/src/interfaces/IPoolManager.sol';
import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';
import {SafeCast} from '@uniswap/v4-core/src/libraries/SafeCast.sol';
import {TickMath} from '@uniswap/v4-core/src/libraries/TickMath.sol';
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

import {Flaunch} from '@flaunch/Flaunch.sol';
import {TreasuryManager} from '@flaunch/treasury/managers/TreasuryManager.sol';

import {ISnapshotAirdrop} from '@flaunch-interfaces/ISnapshotAirdrop.sol';
import {IPoolSwap} from '@flaunch-interfaces/IPoolSwap.sol';
import {IFLETH} from '@flaunch-interfaces/IFLETH.sol';


/**
 * Allows an ERC721 to be locked inside an onboarding manager that can be claimed by a designated
 * wallet address when wanted.
 *
 * Fees will be collected on behalf of an `onboardee` until they claim the ERC721, at which point
 * they will receive a set amount of the fees collected, and the remaining fees will be distributed
 * to holders via the {ISnapshotAirdrop} contract.
 */
contract OnboardingManager is TreasuryManager {

    using CurrencyLibrary for Currency;
    using SafeCast for uint;

    error CannotBeZeroAddress();
    error CannotRescueToken();
    error InsufficientClaimWindow();
    error InvalidClaimer();
    error InvalidOnboardeeAllocation();
    error OnboardeeUnableToClaimETH();
    error OnboardingWindowClosed();
    error OnboardingWindowNotClosed();
    error TokenAlreadyClaimed();
    error TokenIdAlreadySet(uint _tokenId);

    event ManagerInitialized(uint _tokenId, InitializeParams _params);
    event OnboardeeUpdated(address _onboardee);

    event OnboardeeClaim(uint _tokenId, address _onboardee, uint _onboardeeAmount, uint _publicAmount, uint _airdropIndex);
    event OnboardeeReleased(uint _tokenId, address _onboardee, uint _buyBack);
    event OnboardingMarketBuy(uint _tokenId, uint _flethSpent, uint _flayBurned);

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

    /// The `dEaD` address to burn our $FLAY tokens to
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    /// The {Flaunch} token ID stored in the contract
    uint public tokenId;

    /// The onboardee and their allocation percentage (2dp)
    address payable public onboardee;
    uint public onboardeeAllocation;

    /// The {ISnapshotAirdrop} contract used by the Flaunch protocol
    ISnapshotAirdrop public immutable airdropClaim;

    /// The index of the airdrop created by the claim
    uint public airdropIndex;

    /// The {PoolSwap} contract
    IPoolSwap public immutable poolSwap;

    /// The `block.timestamp` at which the the claim window closes
    uint public claimWindowEnd;

    /// The `PoolKey` used for $FLAY on Uniswap V4
    // solidity doesn't support immutable structs, so we'll use these as a workaround
    Currency immutable flayPoolKey_currency0;
    Currency immutable flayPoolKey_currency1;
    uint24 immutable flayPoolKey_fee;
    int24 immutable flayPoolKey_tickSpacing;
    IHooks immutable flayPoolKey_hooks;

    /// Stores if the token has been claimed
    bool public claimed;

    /**
     * Sets up the contract with the initial required contract addresses.
     *
     * @param _flaunch The {Flaunch} ERC721 contract address
     * @param _airdropClaim The {ISnapshotAirdrop} contract that will distribute claims
     * @param _poolSwap The {IPoolSwap} contract that will facilitate market buys
     */
    constructor (address _flaunch, address _airdropClaim, address _poolSwap, PoolKey memory _flayPoolKey) TreasuryManager(_flaunch) {
        airdropClaim = ISnapshotAirdrop(_airdropClaim);
        poolSwap = IPoolSwap(_poolSwap);
        
        flayPoolKey_currency0 = _flayPoolKey.currency0;
        flayPoolKey_currency1 = _flayPoolKey.currency1;
        flayPoolKey_fee = _flayPoolKey.fee;
        flayPoolKey_tickSpacing = _flayPoolKey.tickSpacing;
        flayPoolKey_hooks = _flayPoolKey.hooks;
    }

    /**
     * Registers the tokenId passed by the initialization and ensures that it is the only one
     * registered to the manager. We also set our initial configurations, though the majority
     * of these can be updated by the owner at a later date.
     *
     * @param _tokenId The Flaunch tokenId that is being managed
     * @param _data Onboarding variables
     */
    function _initialize(uint _tokenId, bytes calldata _data) internal override {
        // Confirm that we only have one tokenId assigned to the escrow. The zero tokenId does
        // not exist, so we can safely check against a zero value.
        if (tokenId != 0) {
            revert TokenIdAlreadySet(tokenId);
        }

        // Assign our tokenId to the manager
        tokenId = _tokenId;

        // Unpack our initial configuration data
        (InitializeParams memory params) = abi.decode(_data, (InitializeParams));

        // Validate the passed parameters
        if (params.onboardeeAllocation > MAX_ONBOARDEE_ALLOCATION) {
            revert InvalidOnboardeeAllocation();
        }

        // The rest can be assigned without further validation
        onboardee = params.onboardee;
        onboardeeAllocation = params.onboardeeAllocation;
        claimWindowEnd = params.claimWindowEnd;

        // Emit an event that shows our initial data
        emit ManagerInitialized(_tokenId, params);
    }

    /**
     * If the onboardee claims, they take a fixed percentage of any of the revenue earned whilst
     * the ERC721 has been under the ownership of this manager. The remaining ETH is dispersed to
     * holders via a snapshot airdrop.
     */
    function claim() public onlyNotClaimed {
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
        flaunch.transferFrom(address(this), onboardee, tokenId);

        // Claim the fees owed to the token, bringing all the ETH revenue into this contract
        flaunch.positionManager().withdrawFees(address(this), true);

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
                _memecoin: flaunch.memecoin(tokenId),
                _creator: address(this),
                _token: address(0),
                _amount: publicAmount,
                _airdropEndTime: block.timestamp + 4 weeks
            });
        }

         // Emit our onboardee claim event
        emit OnboardeeClaim(tokenId, onboardee, onboardeeAmount, publicAmount, airdropIndex);
    }

    /**
     * If the onboardee does **not** claim during the onboarding window, then all of the ETH
     * accrued in fees goes into a $FLAY market buy. The $FLAY tokens purchased are subsequently
     * burned.
     *
     * @dev This function call does not need to mark the `claimed` boolean as true, as we burn
     * the ERC721. This means there is no way for it to re-enter the contract.
     */
    function release() public onlyOwner onlyNotClaimed {
        // Ensure that the timelock has passed and ended
        if (block.timestamp <= claimWindowEnd) {
            revert OnboardingWindowNotClosed();
        }

        // Claim the fees owed to the token, bringing all the revenue in as flETH
        flaunch.positionManager().withdrawFees(address(this), false);

        // Capture the amount of flETH and emit our release event
        uint flethBalance = IFLETH(flaunch.positionManager().nativeToken()).balanceOf(address(this));
        emit OnboardeeReleased(tokenId, onboardee, flethBalance);

        // Action a market buy against our $FLAY token
        _marketBuyToken();

        // Burn the ERC721 ownership
        flaunch.burn(tokenId);
    }

    /**
     * Allows anyone to withdraw the remaining airdrop amount, after the airdrop has ended.
     */
    function recoverAirdrop() public {
        // Reclaim fees from our airdrop as ETH
        airdropClaim.creatorWithdraw({
            _memecoin: flaunch.memecoin(tokenId),
            _airdropIndex: airdropIndex
        });

        // Convert the ETH received into FLETH before the market buy
        IFLETH(flaunch.positionManager().nativeToken()).deposit{value: address(this).balance}(0);

        // Action a market buy against our $FLAY token with the recovered fees
        _marketBuyToken();
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
    function setOnboardee(address payable _onboardee) public onlyOwner onlyNotClaimed {
        onboardee = _onboardee;
        emit OnboardeeUpdated(_onboardee);
    }

    /**
     * Actions a market buy against our $FLAY pool, spending FLETH as our specified token.
     *
     * @dev This always uses the full balance of FLETH held by this contract
     */
    function _marketBuyToken() internal {
        // Find our native token (fleth) from the PoolKey
        IFLETH nativeToken = IFLETH(flaunch.positionManager().nativeToken());

        // Capture the amount of native token held by the sender from the claim
        uint amountSpecified = nativeToken.balanceOf(address(this));
        if (amountSpecified != 0) {
            // Approve the swap contract to use our flETH
            nativeToken.approve(address(poolSwap), amountSpecified);

            // Check if the native token is `currency0`
            bool nativeIsZero = address(nativeToken) == Currency.unwrap(flayPoolKey_currency0);

            // Action our swap against the {PoolSwap} contract, buying $FLAY from the PoolKey set
            poolSwap.swap({
                _key: flayPoolKey(),
                _params: IPoolManager.SwapParams({
                    zeroForOne: nativeIsZero,
                    amountSpecified: -amountSpecified.toInt256(),
                    sqrtPriceLimitX96: nativeIsZero ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                })
            });

            // Burn $FLAY tokens earned from the swap. The $FLAY token's burn function can only be called
            // by the Optimism's bridge contract, so instead we send the tokens to the `0xdead` address to
            // burn them.
            Currency flayToken = (nativeIsZero) ? flayPoolKey_currency1 : flayPoolKey_currency0;
            uint flayAmount = flayToken.balanceOfSelf();

            flayToken.transfer(BURN_ADDRESS, flayAmount);
            emit OnboardingMarketBuy(tokenId, amountSpecified, flayAmount);
        }
    }

    /**
     * This manager handles our Flaunch ERC721 withdrawals from specific function calls. For
     * this reason, we want to ensure that our expected flows are not bypassed with this function.
     */
    function rescue(uint /* _tokenId */, address /* _recipient */) public pure override {
        revert CannotRescueToken();
    }

    function flayPoolKey() public view returns (PoolKey memory) {
        return PoolKey({
            currency0: flayPoolKey_currency0,
            currency1: flayPoolKey_currency1,
            fee: flayPoolKey_fee,
            tickSpacing: flayPoolKey_tickSpacing,
            hooks: flayPoolKey_hooks
        });
    }

    /**
     * Only allows the function call to be made if the token has not yet been claimed.
     */
    modifier onlyNotClaimed {
        if (claimed) revert TokenAlreadyClaimed();
        _;
    }

}
