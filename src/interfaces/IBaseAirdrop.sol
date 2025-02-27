// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IFLETH} from '@flaunch-interfaces/IFLETH.sol';
import {ITreasuryManagerFactory} from '@flaunch-interfaces/ITreasuryManagerFactory.sol';

interface IBaseAirdrop {

    event ApprovedAirdropCreatorAdded(address indexed _contract);
    event ApprovedAirdropCreatorRemoved(address indexed _contract);

    error NotApprovedAirdropCreator();
    error InvalidAirdrop();
    error ETHSentForTokenAirdrop();
    error AirdropEnded();
    error AirdropInProgress();
    error AirdropAlreadyClaimed();
    error ApprovedAirdropCreatorAlreadyAdded();
    error ApprovedAirdropCreatorNotPresent();

    function fleth() external view returns (IFLETH);

    function treasuryManagerFactory() external view returns (ITreasuryManagerFactory);

    function getApprovedAirdropCreators() external view returns (address[] memory);

    function isApprovedAirdropCreator(address _contract) external view returns (bool);

    function setApprovedAirdropCreators(address _contract, bool _approved) external;

}
