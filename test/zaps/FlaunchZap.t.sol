// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import {PoolId, PoolIdLibrary} from '@uniswap/v4-core/src/types/PoolId.sol';
import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';

import {FlaunchZap} from '@flaunch/zaps/FlaunchZap.sol';
import {PositionManager} from '@flaunch/PositionManager.sol';

import {FlaunchTest} from 'test/FlaunchTest.sol';


contract FlaunchZapTest is FlaunchTest {

    using PoolIdLibrary for PoolKey;

    constructor () {
        // Deploy our platform
        _deployPlatform();

        // {PoolManager} must have some initial flETH balance to serve `take()` requests in our hook
        deal(address(flETH), address(poolManager), 1000e27 ether);
    }

    /**
     * This test fuzzes as many relevant factors as possible and then validates based on the
     * expdected user journey. The only variables fuzzed will be those that affect zap
     * functionality. The other variables are tested in other suites.
     *
     * @param _initialTokenFairLaunch ..
     * @param _premineAmount ..
     * @param _creator ..
     * @param _initialPrice ..
     *
     * @param _airdropMerkleRoot ..
     *
     * @param _manager ..
     *
     * @param _whitelistMerkleRoot ..
     * @param _whitelistMaxTokens ..
     */
    function test_CanFlaunch(
        uint _initialTokenFairLaunch,
        uint _premineAmount,
        address _creator,
        uint _initialPrice,
        bytes32 _airdropMerkleRoot,
        address _manager,
        bytes32 _whitelistMerkleRoot,
        uint _whitelistMaxTokens
    ) public {
        // Ensure that the creator is not a zero address, as this will revert
        vm.assume(_creator != address(0));

        // Ensure that our initial token supply is valid (InvalidInitialSupply)
        vm.assume(_initialTokenFairLaunch <= flaunch.MAX_FAIR_LAUNCH_TOKENS());

        // Ensure that our premine does not exceed the fair launch (PremineExceedsInitialAmount)
        vm.assume(_premineAmount <= _initialTokenFairLaunch);

        // Provide our user with enough FLETH to make the premine swap
        deal(address(this), 2000e27);
        flETH.deposit{value: 1000e27}();
        flETH.approve(address(flaunchZap), 1000e27);

        // Flaunch time baby!
        (address memecoin_, uint ethSpent_, address deployedManager_) = flaunchZap.flaunch{value: 1000e27}({
            _flaunchParams: PositionManager.FlaunchParams({
                name: 'FlaunchZap',
                symbol: 'ZAP',
                tokenUri: 'ipfs://123',
                initialTokenFairLaunch: _initialTokenFairLaunch,
                premineAmount: _premineAmount,
                creator: _creator,
                creatorFeeAllocation: 80_00,
                flaunchAt: 0,
                initialPriceParams: abi.encode(_initialPrice),
                feeCalculatorParams: abi.encode('')
            }),
            _whitelistParams: FlaunchZap.WhitelistParams({
                merkleRoot: _whitelistMerkleRoot,
                merkleIPFSHash: 'ipfs://123',
                maxTokens: _whitelistMaxTokens
            }),
            _airdropParams: FlaunchZap.AirdropParams({
                airdropIndex: 0,
                airdropAmount: 1,
                airdropEndTime: block.timestamp + 30 days,
                merkleRoot: _airdropMerkleRoot,
                merkleIPFSHash: 'ipfs://'
            }),
            _treasuryManagerParams: FlaunchZap.TreasuryManagerParams({
                manager: _manager,
                data: abi.encode('')
            })
        });

        // Check our flaunch state

        // Check our whitelist
        {
            (bytes32 root, string memory ipfs, uint maxTokens, bool active, bool exists) = whitelistFairLaunch.whitelistMerkles(
                positionManager.poolKey(memecoin_).toId()
            );

            if (_whitelistMerkleRoot != '' && _initialTokenFairLaunch != 0) {
                assertEq(root, _whitelistMerkleRoot);
                assertEq(ipfs, 'ipfs://123');
                assertEq(maxTokens, _whitelistMaxTokens);
                assertEq(active, true);
                assertEq(exists, true);
            } else {
                assertEq(root, '');
                assertEq(ipfs, '');
                assertEq(maxTokens, 0);
                assertEq(active, false);
                assertEq(exists, false);
            }
        }

        // Check our airdrop
        {
            if (_premineAmount != 0 && _airdropMerkleRoot != '') {
                // @dev The airdrop count reflects the creator, not the manager
                assertEq(merkleAirdrop.airdropsCount(_creator), 1);
                assertEq(IERC20(memecoin_).balanceOf(address(merkleAirdrop)), 1);
            } else {
                assertEq(merkleAirdrop.airdropsCount(_creator), 0);
                assertEq(IERC20(memecoin_).balanceOf(address(merkleAirdrop)), 0);
            }
        }

        // Check our treasury manager
        {
            if (_manager != address(0)) {
                assertEq(flaunch.ownerOf(1), _manager);
                assertEq(deployedManager_, _manager);
            } else {
                assertEq(flaunch.ownerOf(1), address(this));
                assertEq(deployedManager_, address(0));
            }
        }

        // Check our refunded ETH
        {
            assertEq(payable(address(this)).balance, 1000e27 - ethSpent_);
        }
    }

    function test_CanCalculateFees() public {
        // Set an fee to flaunch
        vm.mockCall(
            address(positionManager),
            abi.encodeWithSelector(PositionManager.getFlaunchingFee.selector),
            abi.encode(0.001e18)
        );

        // Set an expected market cap here to in-line with Sepolia tests (2~ eth)
        vm.mockCall(
            address(positionManager),
            abi.encodeWithSelector(PositionManager.getFlaunchingMarketCap.selector),
            abi.encode(2e18)
        );

        // premineCost : 0.1 ether
        // premineCost swap fee : 0.001 ether
        // fee : 0.001 ether

        uint ethRequired = flaunchZap.calculateFee(supplyShare(5_00), 0, abi.encode(''));
        assertEq(ethRequired, 0.1 ether + 0.001 ether + 0.001 ether);

        // premineCost : 0.2 ether
        // premineCost swap fee : 0.002 ether
        // fee : 0.001 ether

        ethRequired = flaunchZap.calculateFee(supplyShare(10_00), 0, abi.encode(''));
        assertEq(ethRequired, 0.2 ether + 0.002 ether + 0.001 ether);
    }

}
