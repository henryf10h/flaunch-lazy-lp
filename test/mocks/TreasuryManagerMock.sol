// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {TreasuryManager} from '@flaunch/treasury/managers/TreasuryManager.sol';


contract TreasuryManagerMock is TreasuryManager {

    constructor (address _flaunch) TreasuryManager(_flaunch) {}

    function _initialize(uint, bytes calldata) internal override {
        // ..
    }

}
