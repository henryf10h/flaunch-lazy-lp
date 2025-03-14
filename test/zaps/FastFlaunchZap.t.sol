// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FastFlaunchZap} from '@flaunch/zaps/FastFlaunchZap.sol';

import {IMemecoin} from '@flaunch-interfaces/IMemecoin.sol';
import {PoolId, PoolIdLibrary} from '@uniswap/v4-core/src/types/PoolId.sol';
import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';

import {FlaunchTest} from 'test/FlaunchTest.sol';

contract FastFlaunchZapTests is FlaunchTest {

    using PoolIdLibrary for PoolKey;

    constructor () {
        // Deploy our platform
        _deployPlatform();
    }

    function test_CanFastFlaunch(bool _flipped) public flipTokens(_flipped) {
        address memecoin = fastFlaunchZap.flaunch(FastFlaunchZap.FastFlaunchParams({
            name: 'Token Name',
            symbol: 'TOKEN',
            tokenUri: 'https://flaunch.gg/',
            creator: address(this)
        }));

        PoolId poolId = positionManager.poolKey(memecoin).toId();

        // Confirm the fair launch supply
        assertEq(fairLaunch.fairLaunchInfo(poolId).supply, 60e27, "Fair launch supply is not 60% of the total supply");

        // Confirm that the fair launch has started
        assertEq(fairLaunch.inFairLaunchWindow(poolId), true, "Fair launch has not started");

        // Confirm the creator
        uint tokenId = flaunch.tokenId(memecoin);
        assertEq(flaunch.ownerOf(tokenId), address(this), "Creator is not the owner of the memecoin");

        // Confirm the memecoin metadata
        assertEq(IMemecoin(memecoin).name(), 'Token Name');
        assertEq(IMemecoin(memecoin).symbol(), 'TOKEN');
        assertEq(IMemecoin(memecoin).tokenURI(), 'https://flaunch.gg/');
    }
}
