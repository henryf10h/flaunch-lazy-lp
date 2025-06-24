// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AnyPositionManager} from '@flaunch/AnyPositionManager.sol';


interface IAnyFlaunch {

    function tokenId(address _memecoin) external view returns (uint tokenId_);

    function flaunch(AnyPositionManager.FlaunchParams calldata) external returns (address payable memecoinTreasury_, uint tokenId_);

    function creator(address _memecoin) external view returns (address);

    function nftManager(address _memecoin) external view returns (address);

    function memecoinTreasury(address _memecoin) external view returns (address payable memecoinTreasury_);

}