// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BeforeSwapDelta, toBeforeSwapDelta} from '@uniswap/v4-core/src/types/BeforeSwapDelta.sol';
import {Currency} from '@uniswap/v4-core/src/types/Currency.sol';
import {IPoolManager} from '@uniswap/v4-core/src/interfaces/IPoolManager.sol';
import {PoolId} from '@uniswap/v4-core/src/types/PoolId.sol';
import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';

import {AnyPositionManager} from '@flaunch/AnyPositionManager.sol';
import {FeeExemptions} from '@flaunch/hooks/FeeExemptions.sol';

import {IFeeCalculator} from '@flaunch-interfaces/IFeeCalculator.sol';
import {IInitialPrice} from '@flaunch-interfaces/IInitialPrice.sol';


contract AnyPositionManagerMock is AnyPositionManager {

    constructor (ConstructorParams memory params) AnyPositionManager(params) {
        // ..
    }

    function depositFeesMock(PoolKey memory key, uint amount0, uint amount1) public {
        _depositFees(key, amount0, amount1);
    }

    function allocateFeesMock(PoolId _poolId, address _recipient, uint _amount) public {
        _allocateFees(_poolId, _recipient, _amount);
    }

    function distributeFeesMock(PoolKey memory _poolKey) public {
        _distributeFees(_poolKey);
    }

    function setPoolFees(PoolId _poolId, uint _amount0, uint _amount1) public {
        _poolFees[_poolId] = ClaimableFees(_amount0, _amount1);
    }

    function captureSwapFees(
        IPoolManager poolManager,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata _params,
        Currency swapFeeCurrency,
        uint swapAmount,
        FeeExemptions.FeeExemption calldata swapFeeOverride
    ) public returns (
        uint swapFee_
    ) {
        return _captureSwapFees(poolManager, key, _params, IFeeCalculator(address(0)), swapFeeCurrency, swapAmount, swapFeeOverride);
    }

    function captureDelta(PoolKey memory /* _poolKey */, IPoolManager.SwapParams memory _params, BeforeSwapDelta _delta) public returns (int amount0_, int amount1_) {
        _captureDelta(_params, TS_FL_AMOUNT0, TS_FL_AMOUNT1, _delta);
        return (_tload(TS_FL_AMOUNT0), _tload(TS_FL_AMOUNT1));
    }

    function captureDeltaSwapFee(PoolKey memory /* _poolKey */, IPoolManager.SwapParams memory _params, uint _delta) public returns (int amount0_, int amount1_) {
        _captureDeltaSwapFee(_params, TS_FL_FEE0, TS_FL_FEE1, _delta);
        return (_tload(TS_FL_FEE0), _tload(TS_FL_FEE1));
    }

    function getNativeToken() public view returns (address) {
        return nativeToken;
    }

    function getInitialPrice() public view returns (IInitialPrice) {
        return initialPrice;
    }

    function getCreatorFee(PoolId _poolId) public view returns (uint) {
        return creatorFee[_poolId];
    }

    function emitPoolStateUpdate(PoolId _poolId) public {
        _emitPoolStateUpdate(_poolId, '', '');
    }

}
