// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {TreasuryManager} from '@flaunch/treasury/managers/TreasuryManager.sol';


contract TreasuryManagerMock is TreasuryManager {

    constructor (address _treasuryManagerFactory) TreasuryManager(_treasuryManagerFactory) {}

    function _initialize(address _owner, bytes calldata) internal override {
        // ..
    }

}
