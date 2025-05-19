// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';
import {PoolIdLibrary} from '@uniswap/v4-core/src/types/PoolId.sol';
import {IHooks} from '@uniswap/v4-core/src/libraries/Hooks.sol';
import {Currency} from '@uniswap/v4-core/src/types/Currency.sol';

import {IndexerSubscriber} from '@flaunch/subscribers/Indexer.sol';
import {PositionManager} from '@flaunch/PositionManager.sol';

import {FlaunchTest} from '../FlaunchTest.sol';


contract IndexerTest is FlaunchTest {

    using PoolIdLibrary for PoolKey;

    constructor () {
        // Deploy our platform
        _deployPlatform();

        // We subscribe our indexer during our test environment setup, so we need to
        // unsubscribe it ahead of our tests
        positionManager.notifier().unsubscribe(address(indexer));
    }

    function test_CanIndex() public {
        _deploySubscriber();
        _setNotifier();

        (address memecoin, uint tokenId, PoolKey memory poolKey) = _flaunchToken();

        (address indexedFlaunch, address indexedMemecoin,, uint indexedTokenId) = indexer.poolIndex(poolKey.toId());
        assertEq(indexedFlaunch, address(flaunch));
        assertEq(indexedMemecoin, memecoin);
        assertEq(indexedTokenId, tokenId);
    }

    function test_CannotIndexWithoutNotifierFlaunch() public {
        (,, PoolKey memory poolKey) = _flaunchToken();
        (address indexedFlaunch, address indexedMemecoin,, uint indexedTokenId) = indexer.poolIndex(poolKey.toId());
        assertEq(indexedFlaunch, address(0));
        assertEq(indexedMemecoin, address(0));
        assertEq(indexedTokenId, 0);
    }

    function test_CanAddIndex() public {
        (address memecoin1, uint tokenId1, PoolKey memory poolKey1) = _flaunchToken();
        (address memecoin2, uint tokenId2, PoolKey memory poolKey2) = _flaunchToken();

        _deploySubscriber();
        _setNotifier();

        IndexerSubscriber.AddIndexParams[] memory indexParams = new IndexerSubscriber.AddIndexParams[](1);
        uint[] memory tokenIds = new uint[](2);
        tokenIds[0] = tokenId1;
        tokenIds[1] = tokenId2;
        indexParams[0] = IndexerSubscriber.AddIndexParams({
            flaunch: address(flaunch),
            tokenIds: tokenIds
        });

        indexer.addIndex(indexParams);

        (address indexedFlaunch, address indexedMemecoin,, uint indexedTokenId) = indexer.poolIndex(poolKey1.toId());
        assertEq(indexedFlaunch, address(flaunch));
        assertEq(indexedMemecoin, memecoin1);
        assertEq(indexedTokenId, tokenId1);

        (indexedFlaunch, indexedMemecoin,, indexedTokenId) = indexer.poolIndex(poolKey2.toId());
        assertEq(indexedFlaunch, address(flaunch));
        assertEq(indexedMemecoin, memecoin2);
        assertEq(indexedTokenId, tokenId2);
    }

    function _deploySubscriber() internal {
        positionManager.notifier().subscribe(address(indexer), '');
    }

    function _setNotifier() internal {
        indexer.setNotifierFlaunch(address(positionManager.notifier()), address(flaunch));
    }

    function _flaunchToken() internal returns (address memecoin_, uint tokenId_, PoolKey memory poolKey_) {
        memecoin_ = positionManager.flaunch(PositionManager.FlaunchParams('name', 'symbol', 'https://token.gg/', supplyShare(50), 30 minutes, 0, address(this), 50_00, 0, abi.encode(''), abi.encode(1_000)));
        tokenId_ = flaunch.tokenId(memecoin_);
        poolKey_ = PoolKey({
            currency0: Currency.wrap(address(flETH)),
            currency1: Currency.wrap(memecoin_),
            fee: 0,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(positionManager))
        });
    }

}
