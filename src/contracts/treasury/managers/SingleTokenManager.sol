// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Flaunch} from '@flaunch/Flaunch.sol';
import {TreasuryManager} from '@flaunch/treasury/managers/TreasuryManager.sol';


/**
 * Abstract contract used by TreasuryManager contracts that only support a single
 * Flaunch token.
 */
abstract contract SingleTokenManager is TreasuryManager {

    error TokenAlreadySet(FlaunchToken _flaunchToken);
    error TokenNotSet();

    /// The {Flaunch} token ID stored in the contract
    FlaunchToken public flaunchToken;

    /**
     * Register our {TreasuryManager}.
     *
     * @param _treasuryManagerFactory The {TreasuryManagerFactory} that will launch this implementation
     */
    constructor (address _treasuryManagerFactory) TreasuryManager(_treasuryManagerFactory) {
        // ..
    }

    /**
     * Ensures that only a single token has been deposited into the manager.
     */
    modifier depositSingleToken(FlaunchToken calldata _flaunchToken) {
        // Confirm that we only have one tokenId assigned to the escrow
        if (flaunchToken.tokenId != 0) {
            revert TokenAlreadySet(flaunchToken);
        }

        // Assign the flaunch token to the manager
        flaunchToken = _flaunchToken;

        _;
    }

    /**
     * Only allows the function call to be made if there is a staked token
     */
    modifier tokenExists {
        if (flaunchToken.tokenId == 0) revert TokenNotSet();
        _;
    }

}
