// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BalanceDelta} from '@uniswap/v4-core/src/types/BalanceDelta.sol';
import {IPoolManager} from '@uniswap/v4-core/src/interfaces/IPoolManager.sol';
import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';


interface IPoolSwap {

    function swap(PoolKey memory _key, IPoolManager.SwapParams memory _params) external payable returns (BalanceDelta);

    function swap(PoolKey memory _key, IPoolManager.SwapParams memory _params, address _referrer) external payable returns (BalanceDelta delta_);

}
