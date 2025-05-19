// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';
import {PoolIdLibrary, PoolId} from '@uniswap/v4-core/src/types/PoolId.sol';
import {IPoolManager, PoolManager, Pool} from '@uniswap/v4-core/src/PoolManager.sol';
import {TickMath} from '@uniswap/v4-core/src/libraries/TickMath.sol';
import {Currency} from '@uniswap/v4-core/src/types/Currency.sol';

import {BidWall} from '@flaunch/bidwall/BidWall.sol';
import {FeeDistributor} from '@flaunch/hooks/FeeDistributor.sol';
import {FeeEscrow} from '@flaunch/escrows/FeeEscrow.sol';
import {FeeExemptions} from '@flaunch/hooks/FeeExemptions.sol';
import {InternalSwapPool} from '@flaunch/hooks/InternalSwapPool.sol';
import {PoolSwap} from '@flaunch/zaps/PoolSwap.sol';
import {PositionManager} from '@flaunch/PositionManager.sol';

import {IMemecoin} from '@flaunch-interfaces/IMemecoin.sol';

import {PoolManagerMock} from '../mocks/PoolManagerMock.sol';
import {FlaunchTest} from '../FlaunchTest.sol';


contract FeeDistributorTest is FlaunchTest {

    using PoolIdLibrary for PoolKey;

    // Set a test-wide pool key
    PoolKey private _poolKey;

    // Store our memecoin created for the test
    address memecoin;

    constructor () {
        // Deploy our platform
        _deployPlatform();

        // Create our memecoin
        memecoin = positionManager.flaunch(PositionManager.FlaunchParams('name', 'symbol', 'https://token.gg/', supplyShare(50), 30 minutes, 0, address(this), 20_00, 0, abi.encode(''), abi.encode(1_000)));

        // Reference our `_poolKey` for later tests
        _poolKey = positionManager.poolKey(memecoin);

        // Skip FairLaunch
        _bypassFairLaunch();
    }

    function test_CanCalculateFeeSplit() public view {
        // Zero amount
        (uint bidWall, uint creator, uint protocol) = positionManager.feeSplit(_poolKey.toId(), 0);
        assertEq(protocol, 0);
        assertEq(creator, 0);
        assertEq(bidWall, 0);

        // Indivisible amount
        (bidWall, creator, protocol) = positionManager.feeSplit(_poolKey.toId(), 1);
        assertEq(protocol, 0);
        assertEq(creator, 0);
        assertEq(bidWall, 1);

        // Divisible amount
        (bidWall, creator, protocol) = positionManager.feeSplit(_poolKey.toId(), 100);
        assertEq(protocol, 10);
        assertEq(creator, 18);
        assertEq(bidWall, 72);
    }

    function test_CanCalculateFeeSplitWithPoolFeeDistribution() public {
        (uint bidWall, uint creator, uint protocol) = positionManager.feeSplit(_poolKey.toId(), 100);
        assertEq(protocol, 10);
        assertEq(creator, 18);
        assertEq(bidWall, 72);

        positionManager.setPoolFeeDistribution(
            _poolKey.toId(),
            FeeDistributor.FeeDistribution({
                swapFee: 50_00,
                referrer: 15_00,
                protocol: 5_00,
                active: true
            })
        );

        (bidWall, creator, protocol) = positionManager.feeSplit(_poolKey.toId(), 100);
        assertEq(protocol, 5);
        assertEq(creator, 19);
        assertEq(bidWall, 76);
    }

    function test_CanSetFeeDistribution(uint24 _swapFee, uint24 _referrer) public {
        // We can assume these two values, but to assume the sum of all other parts
        // would result in mass rejection and fail the tests.
        vm.assume(_swapFee <= 100_00);
        vm.assume(_referrer <= 100_00);

        // Set up a testing matrix of valid combinations
        uint24[][] memory testMatrix = new uint24[][](6);
        testMatrix[0] = _validFeeDistributionMatrix(100_00, 0, 0);
        testMatrix[1] = _validFeeDistributionMatrix(0, 100_00, 0);
        testMatrix[2] = _validFeeDistributionMatrix(0, 0, 10_00);
        testMatrix[3] = _validFeeDistributionMatrix(50_00, 50_00, 0);
        testMatrix[4] = _validFeeDistributionMatrix(20_00, 15_00, 5_00);
        testMatrix[5] = _validFeeDistributionMatrix(12, 34_56, 7_50);

        for (uint i; i < testMatrix.length; ++i) {
            positionManager.setFeeDistribution(FeeDistributor.FeeDistribution({
                swapFee: _swapFee,
                referrer: _referrer,
                protocol: testMatrix[i][2],
                active: true
            }));
        }
    }

    function test_CannotSetFeeDistributionWithoutOwner() public {
        vm.startPrank(address(1));
        vm.expectRevert(UNAUTHORIZED);

        positionManager.setFeeDistribution(FeeDistributor.FeeDistribution({
            swapFee: 1_00,
            referrer: 5_00,
            protocol: 10_00,
            active: true
        }));

        vm.stopPrank();
    }

    function test_CannotSetFeeDistributionWithInvalidSwapFee(uint24 _swapFee) public {
        vm.assume(_swapFee > 100_00);

        vm.expectRevert(FeeDistributor.SwapFeeInvalid.selector);
        positionManager.setFeeDistribution(FeeDistributor.FeeDistribution({
            swapFee: _swapFee,
            referrer: 5_00,
            protocol: 10_00,
            active: true
        }));
    }

    function test_CannotSetFeeDistributionWithInvalidReferrerFee(uint24 _referrerFee) public {
        vm.assume(_referrerFee > 100_00);

        vm.expectRevert(FeeDistributor.ReferrerFeeInvalid.selector);
        positionManager.setFeeDistribution(FeeDistributor.FeeDistribution({
            swapFee: 1_00,
            referrer: _referrerFee,
            protocol: 10_00,
            active: true
        }));
    }

    function test_CanSetPoolFeeDistribution(uint24 _swapFee, uint24 _referrer) public {
        // We can assume these two values, but to assume the sum of all other parts
        // would result in mass rejection and fail the tests.
        vm.assume(_swapFee <= 100_00);
        vm.assume(_referrer <= 100_00);

        // Set up a testing matrix of valid combinations
        uint24[][] memory testMatrix = new uint24[][](6);
        testMatrix[0] = _validFeeDistributionMatrix(100_00, 0, 0);
        testMatrix[1] = _validFeeDistributionMatrix(0, 100_00, 0);
        testMatrix[2] = _validFeeDistributionMatrix(0, 0, 10_00);
        testMatrix[3] = _validFeeDistributionMatrix(50_00, 50_00, 0);
        testMatrix[4] = _validFeeDistributionMatrix(20_00, 15_00, 5_00);
        testMatrix[5] = _validFeeDistributionMatrix(12, 34_56, 7_32);

        for (uint i; i < testMatrix.length; ++i) {
            positionManager.setPoolFeeDistribution(
                _poolKey.toId(),
                FeeDistributor.FeeDistribution({
                    swapFee: _swapFee,
                    referrer: _referrer,
                    protocol: testMatrix[i][2],
                    active: true
                })
            );
        }
    }

    function test_CannotSetPoolFeeDistributionWithoutOwner() public {
        vm.startPrank(address(1));
        vm.expectRevert(UNAUTHORIZED);

        positionManager.setPoolFeeDistribution(
            _poolKey.toId(),
            FeeDistributor.FeeDistribution({
                swapFee: 1_00,
                referrer: 5_00,
                protocol: 30_00,
                active: true
            })
        );

        vm.stopPrank();
    }

    function test_CannotSetPoolFeeDistributionWithInvalidSwapFee(uint24 _swapFee) public {
        vm.assume(_swapFee > 100_00);

        vm.expectRevert(FeeDistributor.SwapFeeInvalid.selector);
        positionManager.setPoolFeeDistribution(
            _poolKey.toId(),
            FeeDistributor.FeeDistribution({
                swapFee: _swapFee,
                referrer: 5_00,
                protocol: 30_00,
                active: true
            })
        );
    }

    function test_CannotSetPoolFeeDistributionWithInvalidReferrerFee(uint24 _referrerFee) public {
        vm.assume(_referrerFee > 100_00);

        vm.expectRevert(FeeDistributor.ReferrerFeeInvalid.selector);
        positionManager.setPoolFeeDistribution(
            _poolKey.toId(),
            FeeDistributor.FeeDistribution({
                swapFee: 1_00,
                referrer: _referrerFee,
                protocol: 30_00,
                active: true
            })
        );
    }

    function test_CannotSetPoolFeeDistributionWithInvalidProtocolFee(uint24 _protocolFee) public {
        vm.assume(_protocolFee > 10_00);

        vm.expectRevert(FeeDistributor.ProtocolFeeInvalid.selector);
        positionManager.setPoolFeeDistribution(
            _poolKey.toId(),
            FeeDistributor.FeeDistribution({
                swapFee: 1_00,
                referrer: 5_00,
                protocol: _protocolFee,
                active: true
            })
        );
    }

    function test_CanAllocateAndWithdrawFees(address _sender, address payable _recipient, uint _amount, bool _unwrap) public {
        // Ensure we don't have a used address for recipient
        _assumeValidAddress(_recipient);
        _assumeValidAddress(_sender);
        vm.assume(_sender != _recipient);

        // Ensure we have a positive amount and that we can safely 2x the value
        vm.assume(_amount > 0);
        vm.assume(_amount <= type(uint128).max);

        // Mint ETH to the flETH contract to facilitate unwrapping
        deal(address(this), _amount * 2);
        WETH.deposit{value: _amount * 2}();
        WETH.transfer(address(positionManager), _amount * 2);

        // Allocate the fees to the recipient, confirming that our event is fired
        vm.expectEmit();
        emit FeeEscrow.Deposit(_poolKey.toId(), _sender, positionManager.getNativeToken(), _amount);
        _allocateFees(_poolKey.toId(), _sender, _amount);

        // Allocate additional fees
        vm.expectEmit();
        emit FeeEscrow.Deposit(_poolKey.toId(), _sender, positionManager.getNativeToken(), _amount);
        _allocateFees(_poolKey.toId(), _sender, _amount);

        vm.startPrank(_sender);

        // Withdraw the fees for our recipient, confirming our event is fired and that
        // they have successfully received their token.
        vm.expectEmit();
        emit FeeEscrow.Withdrawal(_sender, _recipient, (_unwrap) ? address(0) : positionManager.getNativeToken(), _amount * 2);
        positionManager.feeEscrow().withdrawFees(_recipient, _unwrap);

        if (_unwrap) {
            assertEq(payable(_recipient).balance, _amount * 2, 'Invalid recipient ETH');
        } else {
            assertEq(IERC20(positionManager.getNativeToken()).balanceOf(_recipient), _amount * 2, 'Invalid recipient flETH');
        }

        vm.stopPrank();
    }

    function test_CanAllocateAndWithdrawFeesWithZeroAmount(bool _unwrap) public {
        address recipient = makeAddr('test_CanAllocateAndWithdrawFeesWithZeroAmount');

        _allocateFees(_poolKey.toId(), recipient, 0);
        positionManager.feeEscrow().withdrawFees(recipient, _unwrap);
        assertEq(IERC20(positionManager.getNativeToken()).balanceOf(recipient), 0);
        assertEq(payable(recipient).balance, 0);
    }

    function test_CannotAllocateFeesToZeroAddress() external {
        vm.expectRevert(FeeEscrow.RecipientZeroAddress.selector);
        _allocateFees(_poolKey.toId(), address(0), 1);
    }

    function test_CanCaptureSwapFees_ZeroForOne_ExactInput(address _referrer) public {
        // Assume our referrer doesn't clash with other addresses
        _assumeValidReferrer(_referrer);

        // User will spend 3 eth to get as many tokens as possible
        _addLiquidityToPool(memecoin, int(10 ether), false);

        uint poolManagerEth = WETH.balanceOf(address(poolManager));

        _processSwap(true, -3 ether, _referrer);

        // Get the expected cost and fees (from the PoolSwap event)
        uint expectedTokens = 5.980976000727421734 ether; // uniAmount1
        uint expectedFees   = 0.059809760007274217 ether; // uniFee1

        uint referrerFee;
        if (_referrer != address(0)) {
            referrerFee = expectedFees * 5 / 100;

            assertEq(referralEscrow.allocations(_referrer, address(WETH)), 0, 'Invalid closing referrer ETH balance');
            assertEq(referralEscrow.allocations(_referrer, memecoin), referrerFee, 'Invalid closing referrer token balance');
        }

        InternalSwapPool.ClaimableFees memory fees = positionManager.poolFees(_poolKey);
        assertEq(fees.amount0, 0, 'Incorrect closing pool ETH fees');
        assertEq(fees.amount1, expectedFees - referrerFee, 'Incorrect closing pool token1 fees');

        assertEq(WETH.balanceOf(address(poolManager)), poolManagerEth + 3 ether, 'Invalid closing poolManager ETH balance');
        assertEq(WETH.balanceOf(address(positionManager)), 0, 'Invalid closing positionManager ETH balance');

        assertEq(WETH.balanceOf(address(referralEscrow)), 0, 'Invalid closing referralEscrow ETH balance');
        assertEq(IERC20(memecoin).balanceOf(address(referralEscrow)), referrerFee, 'Invalid closing referralEscrow memecoin balance');

        assertEq(WETH.balanceOf(address(this)), 100 ether - 3 ether, 'Invalid closing user ETH balance');
        assertEq(IERC20(memecoin).balanceOf(address(this)), 100 ether + expectedTokens - expectedFees, 'Invalid closing user token balance');
    }

    function test_CanCaptureSwapFees_ZeroForOne_ExactOutput(address _referrer) public {
        // Assume our referrer doesn't clash with other addresses
        _assumeValidReferrer(_referrer);

        // User will spend as much eth as needed to get 3 tokens
        _addLiquidityToPool(memecoin, int(10 ether), false);

        uint poolManagerEth = WETH.balanceOf(address(poolManager));

        _processSwap(true, 3 ether, _referrer);

        // Get the expected cost and fees (from the PoolSwap event)
        uint expectedCost = 1.504762194065487463 ether; // uniAmount0
        uint expectedFees = 0.015047621940654874 ether; // uniFee0

        uint referrerFee;
        if (_referrer != address(0)) {
            referrerFee = expectedFees * 5 / 100;

            assertEq(referralEscrow.allocations(_referrer, address(WETH)), referrerFee, 'Invalid closing referrer ETH balance');
            assertEq(referralEscrow.allocations(_referrer, memecoin), 0, 'Invalid closing referrer token balance');
        }

        InternalSwapPool.ClaimableFees memory fees = positionManager.poolFees(_poolKey);
        assertEq(fees.amount0, 0, 'Incorrect closing pool ETH fees');
        assertEq(fees.amount1, 0, 'Incorrect closing pool token1 fees');

        assertEq(WETH.balanceOf(address(poolManager)), poolManagerEth + expectedCost, 'Invalid closing poolManager ETH balance');
        assertEq(WETH.balanceOf(address(positionManager)), expectedFees - referrerFee, 'Invalid closing positionManager ETH balance');

        assertEq(WETH.balanceOf(address(referralEscrow)), referrerFee, 'Invalid closing referralEscrow ETH balance');
        assertEq(IERC20(memecoin).balanceOf(address(referralEscrow)), 0, 'Invalid closing referralEscrow memecoin balance');


        // Our user is set to a static 100 ether of eth and tokens in the `_processSwap` call
        assertEq(WETH.balanceOf(address(this)), 100 ether - expectedCost - expectedFees, 'Invalid closing user ETH balance');
        assertEq(IERC20(memecoin).balanceOf(address(this)), 100 ether + 3 ether, 'Invalid closing user token balance');
    }

    function test_CanCaptureSwapFees_OneForZero_ExactInput(address _referrer) public {
        // Assume our referrer doesn't clash with other addresses
        _assumeValidReferrer(_referrer);

        _addLiquidityToPool(memecoin, int(10 ether), false);

        uint poolManagerEth = WETH.balanceOf(address(poolManager));

        _processSwap(false, -3 ether, _referrer);

        uint expectedTokens = 1.237488951273354569 ether;
        uint expectedFees = 0.012374889512733545 ether;

        uint referrerFee;
        if (_referrer != address(0)) {
            referrerFee = expectedFees * 5 / 100;

            assertEq(referralEscrow.allocations(_referrer, address(WETH)), referrerFee, 'Invalid closing referrer ETH balance');
            assertEq(referralEscrow.allocations(_referrer, memecoin), 0, 'Invalid closing referrer token balance');
        }

        InternalSwapPool.ClaimableFees memory fees = positionManager.poolFees(_poolKey);
        assertEq(fees.amount0, 0, 'Incorrect closing pool ETH fees');
        assertEq(fees.amount1, 0, 'Incorrect closing pool token1 fees');

        assertEq(WETH.balanceOf(address(poolManager)), poolManagerEth - expectedTokens, 'Invalid closing poolManager ETH balance');
        assertEq(WETH.balanceOf(address(positionManager)), expectedFees - referrerFee, 'Invalid closing positionManager ETH balance');

        assertEq(WETH.balanceOf(address(referralEscrow)), referrerFee, 'Invalid closing referralEscrow ETH balance');
        assertEq(IERC20(memecoin).balanceOf(address(referralEscrow)), 0, 'Invalid closing referralEscrow memecoin balance');

        // Our user is set to a static 100 ether of eth and tokens in the `_processSwap` call
        assertEq(WETH.balanceOf(address(this)), 100 ether + expectedTokens - expectedFees, 'Invalid closing user ETH balance');
        assertEq(IERC20(memecoin).balanceOf(address(this)), 100 ether - 3 ether, 'Invalid closing user token balance');
    }

    function test_CanCaptureSwapFees_OneForZero_ExactOutput(address _referrer) public {
        // Assume our referrer doesn't clash with other addresses
        _assumeValidReferrer(_referrer);

        _addLiquidityToPool(memecoin, int(10 ether), false);

        uint poolManagerEth = WETH.balanceOf(address(poolManager));

        _processSwap(false, 3 ether, _referrer);

        uint expectedCost = 10.421444405209233040 ether;
        uint expectedFees = 0.104214444052092330 ether;

        uint referrerFee;
        if (_referrer != address(0)) {
            referrerFee = expectedFees * 5 / 100;

            assertEq(referralEscrow.allocations(_referrer, address(WETH)), 0, 'Invalid closing referrer ETH balance');
            assertEq(referralEscrow.allocations(_referrer, memecoin), referrerFee, 'Invalid closing referrer token balance');
        }

        InternalSwapPool.ClaimableFees memory fees = positionManager.poolFees(_poolKey);
        assertEq(fees.amount0, 0, 'Incorrect closing pool ETH fees');
        assertEq(fees.amount1, expectedFees - referrerFee, 'Incorrect closing pool token1 fees');

        assertEq(WETH.balanceOf(address(poolManager)), poolManagerEth - 3 ether, 'Invalid closing poolManager ETH balance');
        assertEq(WETH.balanceOf(address(positionManager)), 0, 'Invalid closing positionManager ETH balance');

        assertEq(WETH.balanceOf(address(referralEscrow)), 0, 'Invalid closing referralEscrow ETH balance');
        assertEq(IERC20(memecoin).balanceOf(address(referralEscrow)), referrerFee, 'Invalid closing referralEscrow memecoin balance');

        // Our user is set to a static 100 ether of eth and tokens in the `_processSwap` call
        assertEq(WETH.balanceOf(address(this)), 100 ether + 3 ether, 'Invalid closing user ETH balance');
        assertEq(IERC20(memecoin).balanceOf(address(this)), 100 ether - expectedCost - expectedFees, 'Invalid closing user token balance');
    }

    function test_CanReceiveReferrerRewardsFromInternalSwapPool() public {
        // Deposit fees into the pool
        deal(memecoin, address(this), 1 ether);
        IERC20(memecoin).transfer(address(positionManager), 1 ether);
        positionManager.depositFeesMock(_poolKey, 0, 1 ether);

        // Set a referrer
        address _referrer = address(1);

        // Process our swap
        _addLiquidityToPool(memecoin, int(10 ether), false);
        _processSwap(true, 3 ether, _referrer);

        // These are the total amount of fees accumulated from the swap. From these values we will
        // then need to find 5% to return the actual fees received by the referrer.
        uint internalFees = 0.005380455668937963 ether;
        uint uniswapFees  = 0.010031688214552693 ether;

        // Calculate the amount of fees that a referrer would receive (5% of swap fees). The
        // manipulation of "2" is to accommodate rounding issues.
        uint referrerFees = ((internalFees + uniswapFees) / 100) * 5 + 2;

        assertEq(referralEscrow.allocations(_referrer, address(WETH)), referrerFees, 'Invalid closing referrer ETH balance');
        assertEq(referralEscrow.allocations(_referrer, memecoin), 0, 'Invalid closing referrer token balance');
    }

    function test_CanGetCorrectFeesBasedOnOverwrites() public {
        // Define some variables we will test against
        uint swapFee;

        // Set up a mocked pool manager to avoid trying to take tokens
        address _poolManager = address(new PoolManagerMock());

        // Set our default fee position at 0%
        positionManager.setFeeDistribution(
            FeeDistributor.FeeDistribution({
                swapFee: 0,
                referrer: 5_00,
                protocol: 10_00,
                active: true
            })
        );

        // Capture 1 token
        swapFee = positionManager.captureSwapFees(
            IPoolManager(_poolManager), _poolKey, _getSwapParams(1 ether), Currency.wrap(memecoin), 1 ether, _noFeeExemption()
        );

        // We should receive 1 token with 0% fee applied
        assertEq(swapFee, 0, 'global -> 0%');

        // Set our default fee position at 1%
        positionManager.setFeeDistribution(
            FeeDistributor.FeeDistribution({
                swapFee: 1_00,
                referrer: 5_00,
                protocol: 10_00,
                active: true
            })
        );

        // Capture 1 token
        swapFee = positionManager.captureSwapFees(
            IPoolManager(_poolManager), _poolKey, _getSwapParams(1 ether), Currency.wrap(memecoin), 1 ether, _noFeeExemption()
        );

        // We should receive 1 token with 1% fee applied
        assertEq(swapFee, 0.01 ether, 'global -> 1%');

        // Set our pool fee position at 0%
        positionManager.setPoolFeeDistribution(
            _poolKey.toId(),
            FeeDistributor.FeeDistribution({
                swapFee: 0,
                referrer: 5_00,
                protocol: 10_00,
                active: true
            })
        );

        // Capture 1 token
        swapFee = positionManager.captureSwapFees(
            IPoolManager(_poolManager), _poolKey, _getSwapParams(1 ether), Currency.wrap(memecoin), 1 ether, _noFeeExemption()
        );

        // We should receive 1 token with 0% fee applied
        assertEq(swapFee, 0, 'global -> pool -> 0%');

        // Set our pool fee position at 0.5%
        positionManager.setPoolFeeDistribution(
            _poolKey.toId(),
            FeeDistributor.FeeDistribution({
                swapFee: 50,
                referrer: 5_00,
                protocol: 10_00,
                active: true
            })
        );

        // Capture 1 token
        swapFee = positionManager.captureSwapFees(
            IPoolManager(_poolManager), _poolKey, _getSwapParams(1 ether), Currency.wrap(memecoin), 1 ether, _noFeeExemption()
        );

        // We should receive 1 token with 0.5% fee applied
        assertEq(swapFee, 0.005 ether, 'global -> pool -> 0.5%');

        // Capture 1 token, but apply a swap fee override of 0.25%
        swapFee = positionManager.captureSwapFees(
            IPoolManager(_poolManager),
            _poolKey,
            _getSwapParams(1e18),
            Currency.wrap(memecoin),
            1 ether,
            FeeExemptions.FeeExemption(uint24(25), true)
        );

        // We should receive 1 token with 10% fee applied
        assertEq(swapFee, 0.0025 ether, 'global -> pool -> overwrite -> 0.25%');
    }

    function test_CanSetProtocolFeeDistributionAsGovernance(uint24 _protocol) public {
        // Ensure _protocol is in valid range using fuzzing
        vm.assume(_protocol <= 10_00);

        // Expect the event to be emitted with the updated protocol fee
        FeeDistributor.FeeDistribution memory feeDistribution = positionManager.getPoolFeeDistribution(_poolKey.toId());
        FeeDistributor.FeeDistribution memory expectedDistribution = FeeDistributor.FeeDistribution({
            swapFee: feeDistribution.swapFee,
            referrer: feeDistribution.referrer,
            protocol: _protocol,
            active: feeDistribution.active
        });

        vm.expectEmit();
        emit FeeDistributor.FeeDistributionUpdated(expectedDistribution);

        // Prank the governance address to call the function
        vm.prank(governance);

        // Call the function
        positionManager.setProtocolFeeDistribution(_protocol);

        // Assert that the protocol fee was correctly updated
        feeDistribution = positionManager.getPoolFeeDistribution(_poolKey.toId());
        assertEq(feeDistribution.protocol, _protocol);
    }

    function test_CannotSetProtocolFeeDistributionAsNonGovernance(uint24 _protocol) public {
        // Ensure _protocol is in valid range
        vm.assume(_protocol < 10_00);

        // Prank an unauthorized address
        vm.prank(address(1));

        // Expect the transaction to revert with the custom error
        vm.expectRevert(UNAUTHORIZED);

        // Call the function
        positionManager.setProtocolFeeDistribution(_protocol);
    }

    function test_CannotSetInvalidProtocolFee(uint24 _protocol) public {
        // Ensure _protocol is out of the valid range (>= 10_00)
        vm.assume(_protocol > 10_00);

        // Prank the governance address
        vm.prank(governance);

        // Expect the transaction to revert with the custom error
        vm.expectRevert(FeeDistributor.ProtocolFeeInvalid.selector);

        // Call the function
        positionManager.setProtocolFeeDistribution(_protocol);
    }

    function test_CannotSetInvalidProtocolFeeFromNonGovernance(uint24 _protocol) public {
        // Ensure _protocol is out of the valid range (>= 10_00)
        vm.assume(_protocol >= 10_00);

        // Prank an unauthorized address
        vm.prank(address(1));

        // Expect the transaction to revert due to unauthorized access (regardless of protocol fee validity)
        vm.expectRevert(UNAUTHORIZED);

        // Call the function
        positionManager.setProtocolFeeDistribution(_protocol);
    }

    function test_CanGetProtocolFeeEventEmission(uint24 _protocol) public {
        // Ensure _protocol is in valid range
        vm.assume(_protocol < 10_00);

        // Expect the event to be emitted
        FeeDistributor.FeeDistribution memory feeDistribution = positionManager.getPoolFeeDistribution(_poolKey.toId());
        FeeDistributor.FeeDistribution memory expectedDistribution = FeeDistributor.FeeDistribution({
            swapFee: feeDistribution.swapFee,
            referrer: feeDistribution.referrer,
            protocol: _protocol,
            active: feeDistribution.active
        });

        vm.expectEmit();
        emit FeeDistributor.FeeDistributionUpdated(expectedDistribution);

        // Prank the governance address
        vm.prank(governance);

        // Call the function
        positionManager.setProtocolFeeDistribution(_protocol);
    }

    function test_CanDistributeFeesWithBurnedCreatorToken() public {
        uint tokenId = flaunch.tokenId(memecoin);

        // Confirm our initial ownership
        assertEq(flaunch.ownerOf(tokenId), address(this));
        assertEq(IMemecoin(memecoin).creator(), address(this));

        // Burn the token
        flaunch.burn(tokenId);

        // Confirm our expected ERC721 responses. The owner should revert as is expected, but
        // our creator call should handle this and instead just return a zero address.
        vm.expectRevert();
        flaunch.ownerOf(tokenId);

        assertEq(IMemecoin(memecoin).creator(), address(0));

        // Prevent BidWall.deposit, as this will require the PositionManager to be unlocked
        vm.mockCall(
            address(positionManager.bidWall()),
            abi.encodeWithSelector(BidWall.deposit.selector),
            abi.encode(0)
        );

        // Deposit some fees ready to distribute
        deal(address(WETH), address(positionManager), 1 ether);
        positionManager.depositFeesMock(_poolKey, 1 ether, 0);

        // Distribute the fees
        positionManager.distributeFeesMock(_poolKey);
    }

    /**
     * Test that passes a referrer and confirm the fees are correctly allocated against the
     * balance in the ISP.
     */
    function test_CanHandleReferrerFeeOffsetInSwap(address _referrer) public {
        // Assume our referrer doesn't clash with other addresses
        _assumeValidReferrer(_referrer);

        // User will spend 3 eth to get as many tokens as possible
        _addLiquidityToPool(memecoin, int(10 ether), false);

        _processSwap(true, -3 ether, _referrer);

        // Get the expected cost and fees (from the PoolSwap event)
        uint expectedFees = 0.059809760007274217 ether; // uniFee1

        // Calculate the referrer fee that we expect to be taken
        uint referrerFee = expectedFees * 5 / 100;

        // Ensure that our ClaimableFees in the ISP don't include the referrer fee
        InternalSwapPool.ClaimableFees memory fees = positionManager.poolFees(_poolKey);
        assertEq(fees.amount0, 0, 'Incorrect closing pool ETH fees');
        assertEq(fees.amount1, expectedFees - referrerFee, 'Incorrect closing pool token1 fees');

        // Confirm that the PositionManager holds the token fees. The initial swap will have triggered
        // the FairLaunch and thus created a position with the tokens that are remaining in the
        // {PositionManager}. For this reason we can just check the fees amount.
        assertEq(
            IERC20(memecoin).balanceOf(address(positionManager)),
            fees.amount1,
            'Invalid closing PositionManager memecoin balance'
        );
    }

    function _processSwap(bool _zeroForOne, int _amountSpecified, address _referrer) public {
        // Reference our memecoin
        IERC20 token = IERC20(memecoin);

        // Give tokens and approve for swap
        deal(address(WETH), address(this), 100 ether);
        deal(address(token), address(this), 100 ether);
        WETH.approve(address(poolSwap), type(uint).max);
        token.approve(address(poolSwap), type(uint).max);

        // Action our swap
        poolSwap.swap(
            _poolKey,
            IPoolManager.SwapParams({
                zeroForOne: _zeroForOne,
                amountSpecified: _amountSpecified,
                sqrtPriceLimitX96: _zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            _referrer
        );
    }

    function _allocateFees(PoolId _poolId, address _sender, uint _amount) internal {
        feeEscrow.allocateFees(_poolId, _sender, _amount);
    }

    function _validFeeDistributionMatrix(uint24 _bidWall, uint24 _creator, uint24 _protocol) internal pure returns (uint24[] memory feeDisibution_) {
        feeDisibution_ = new uint24[](3);
        feeDisibution_[0] = _bidWall;
        feeDisibution_[1] = _creator;
        feeDisibution_[2] = _protocol;
    }

    function _assumeValidReferrer(address _referrer) internal view {
        vm.assume(_referrer != address(poolManager));
        vm.assume(_referrer != address(positionManager));
        vm.assume(_referrer != address(this));
    }

    function _noFeeExemption() internal pure returns (FeeExemptions.FeeExemption memory) {
        return FeeExemptions.FeeExemption(0, false);
    }

}
