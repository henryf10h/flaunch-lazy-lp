// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@solady/auth/Ownable.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";

import {FairLaunch} from "@flaunch/hooks/FairLaunch.sol";
import {HypeFeeCalculator} from "@flaunch/fees/HypeFeeCalculator.sol";
import {ProtocolRoles} from '@flaunch/libraries/ProtocolRoles.sol';

import {FlaunchTest} from "../FlaunchTest.sol";

contract HypeFeeCalculatorTest is FlaunchTest {
    using PoolIdLibrary for PoolKey;

    address internal constant POSITION_MANAGER = address(10);
    address internal constant NATIVE_TOKEN = address(1);
    address internal constant TOKEN = address(2);

    HypeFeeCalculator feeCalculator;
    FairLaunch mockFairLaunch;
    PoolKey internal poolKey;
    PoolId internal poolId;

    uint24 baseFee = 100; // 1%

    function setUp() public {
        // Deploy mock FairLaunch contract
        vm.startPrank(POSITION_MANAGER);
        mockFairLaunch = new FairLaunch(IPoolManager(address(0)));
        mockFairLaunch.grantRole(ProtocolRoles.POSITION_MANAGER, POSITION_MANAGER);
        vm.stopPrank();

        // Deploy HypeFeeCalculator
        feeCalculator = new HypeFeeCalculator(mockFairLaunch, NATIVE_TOKEN);

        // Set up pool key
        poolKey = PoolKey({
            currency0: Currency.wrap(NATIVE_TOKEN),
            currency1: Currency.wrap(TOKEN),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(POSITION_MANAGER)
        });

        poolId = poolKey.toId();
    }

    /// setTargetTokensPerSec()
    function test_CannotSetTargetTokensPerSecFromUnknownCaller(
        address caller
    ) public {
        vm.assume(caller != POSITION_MANAGER);

        vm.prank(caller);
        vm.expectRevert(HypeFeeCalculator.CallerNotPositionManager.selector);
        feeCalculator.setFlaunchParams(poolId, abi.encode(1000));
    }

    function test_CanSetTargetTokensPerSec(uint256 targetRate) public {
        vm.assume(targetRate > 0);

        vm.prank(POSITION_MANAGER);
        feeCalculator.setFlaunchParams(poolId, abi.encode(targetRate));

        (bool isHypeFeeEnabled, uint256 totalTokensSold, uint256 targetTokensPerSec) = feeCalculator
            .poolInfos(poolId);
        assertEq(isHypeFeeEnabled, true);
        assertEq(targetTokensPerSec, targetRate);
        assertEq(totalTokensSold, 0);
    }

    function test_CanDisableHypeFee() public {
        uint256 targetRate = 0;

        vm.prank(POSITION_MANAGER);
        feeCalculator.setFlaunchParams(poolId, abi.encode(targetRate));

        (bool isHypeFeeEnabled, uint256 totalTokensSold, uint256 targetTokensPerSec) = feeCalculator
            .poolInfos(poolId);
        assertEq(isHypeFeeEnabled, false);
        assertEq(targetTokensPerSec, 0);
        assertEq(totalTokensSold, 0);
    }

    function test_CanDisableHypeFee_WithEmptyParams() public {
        vm.prank(POSITION_MANAGER);
        feeCalculator.setFlaunchParams(poolId, bytes(''));

        (bool isHypeFeeEnabled, uint256 totalTokensSold, uint256 targetTokensPerSec) = feeCalculator
            .poolInfos(poolId);
        assertEq(isHypeFeeEnabled, false);
        assertEq(targetTokensPerSec, 0);
        assertEq(totalTokensSold, 0);
    }

    /// setMaxSwapPercentPerTx()
    function test_CannotSetMaxSwapPercentPerTxFromUnknownCaller(
        address caller
    ) public {
        vm.assume(caller != address(this));

        vm.prank(caller);
        vm.expectRevert(Ownable.Unauthorized.selector);
        feeCalculator.setMaxSwapPercentPerTx(1_00);
    }

    function test_CanSetMaxSwapPercentPerTx(uint256 maxSwapPercentPerTx) public {
        vm.assume(maxSwapPercentPerTx <= 1_00);

        feeCalculator.setMaxSwapPercentPerTx(maxSwapPercentPerTx);

        assertEq(feeCalculator.maxSwapPercentPerTx(), maxSwapPercentPerTx);
    }

    /// trackSwap()
    function test_CannotTrackSwapIfExceedsMaxSwapPercentPerTx() public {
        (uint256 fairLaunchStart, ) = _setUpFairLaunch();

        uint256 maxSwapPercentPerTx = 1_00;
        feeCalculator.setMaxSwapPercentPerTx(maxSwapPercentPerTx);

        int128 swapPercent = 2_00;
        int128 swapAmount = (1e27 * swapPercent) / 1_00;

        vm.warp(fairLaunchStart + 1);
        vm.prank(POSITION_MANAGER);
        vm.expectRevert(HypeFeeCalculator.SwapExceedsMaxSwapPercentPerTx.selector);
        _trackSwap(swapAmount);
    }

    /// determineSwapFee() + trackSwap()
    function test_ReturnsBaseFeeOutsideFairLaunch() public {
        // Mock fair launch not active
        vm.mockCall(
            address(mockFairLaunch),
            abi.encodeCall(mockFairLaunch.inFairLaunchWindow, poolId),
            abi.encode(false)
        );

        assertEq(
            feeCalculator.determineSwapFee(
                poolKey,
                _getSwapParams(1e18),
                baseFee
            ),
            baseFee
        );
    }

    function test_ReturnsBaseFeeForDisabledHypeFee() public {
        // Set hype fee to disabled
        vm.prank(POSITION_MANAGER);
        feeCalculator.setFlaunchParams(poolId, abi.encode(0));

        assertEq(
            feeCalculator.determineSwapFee(
                poolKey,
                _getSwapParams(1e18),
                baseFee
            ),
            baseFee
        );
    }

    function test_CalculatesHypeFee() public {
        (uint256 fairLaunchStart, uint256 fairLaunchEnd) = _setUpFairLaunch();
        int128 swapAmount;

        // First swap at target rate - should get minimum fee
        vm.warp(fairLaunchStart + 1);
        // 1x target rate
        swapAmount = 1000;
        // determineSwapFee() considers the swap amount in this tx, even before the trackSwap() is called
        uint24 fee0 = feeCalculator.determineSwapFee(
            poolKey,
            _getSwapParams(swapAmount),
            baseFee
        );
        assertEq(
            fee0,
            feeCalculator.MINIMUM_FEE_SCALED() / 100,
            "fee0 error"
        );
        vm.prank(POSITION_MANAGER);
        _trackSwap(swapAmount);

        // Second swap slightly above target - should get increased fee
        vm.warp(fairLaunchStart + 2);
        swapAmount = 1500;
        uint24 fee1 = feeCalculator.determineSwapFee(
            poolKey,
            _getSwapParams(swapAmount),
            baseFee
        );
        assertEq(fee1, 13_25, "fee1 error");
        vm.prank(POSITION_MANAGER);
        _trackSwap(swapAmount);

        // Third swap well above target - should get even higher fee
        vm.warp(fairLaunchStart + 3);
        swapAmount = 3000;
        uint24 fee2 = feeCalculator.determineSwapFee(
            poolKey,
            _getSwapParams(swapAmount),
            baseFee
        );
        assertEq(fee2, 41_81, "fee2 error");
        vm.prank(POSITION_MANAGER);
        _trackSwap(swapAmount);

        // Allow some time to pass - rate should decrease and fee should lower
        vm.warp(fairLaunchStart + 10);
        swapAmount = 1;
        uint24 fee3 = feeCalculator.determineSwapFee(
            poolKey,
            _getSwapParams(swapAmount),
            baseFee
        );
        assertEq(fee3, 1_00, "fee3 error");

        // Another large swap - fee should spike again
        swapAmount = 5000;
        uint24 fee4 = feeCalculator.determineSwapFee(
            poolKey,
            _getSwapParams(swapAmount),
            baseFee
        );
        assertEq(fee4, 3_45, "fee4 error");
        vm.prank(POSITION_MANAGER);
        _trackSwap(swapAmount);

        // Skip to near end of fair launch - rate and fee should be much lower
        vm.warp(fairLaunchEnd - 1 minutes);
        swapAmount = 1;
        uint24 fee5 = feeCalculator.determineSwapFee(
            poolKey,
            _getSwapParams(swapAmount),
            baseFee
        );
        assertEq(fee5, 1_00, "fee5 error");
    }

    function test_ReturnsMinimumFeeForLowRate() public {
        (uint256 fairLaunchStart, ) = _setUpFairLaunch();

        // Track small swap
        vm.warp(fairLaunchStart + 1);
        vm.prank(POSITION_MANAGER);
        _trackSwap(500); // 0.5x target rate

        // Fee should be minimum since rate is below target
        uint24 fee = feeCalculator.determineSwapFee(
            poolKey,
            _getSwapParams(1),
            baseFee
        );
        assertEq(fee, feeCalculator.MINIMUM_FEE_SCALED() / 100);
    }

    function _setUpFairLaunch() internal returns (uint256 fairLaunchStart, uint256 fairLaunchEnd) {
        uint256 targetRate = 1000; // tokens per second
        fairLaunchStart = block.timestamp;
        fairLaunchEnd = fairLaunchStart + 30 minutes;

        // Setup fair launch window
        vm.mockCall(
            address(mockFairLaunch),
            abi.encodeCall(mockFairLaunch.inFairLaunchWindow, poolId),
            abi.encode(true)
        );

        vm.mockCall(
            address(mockFairLaunch),
            abi.encodeCall(mockFairLaunch.fairLaunchInfo, poolId),
            abi.encode(
                FairLaunch.FairLaunchInfo({
                    startsAt: fairLaunchStart,
                    endsAt: fairLaunchEnd,
                    initialTick: 0,
                    revenue: 0,
                    supply: 1e27,
                    closed: false
                })
            )
        );

        // Set target rate
        vm.prank(POSITION_MANAGER);
        feeCalculator.setFlaunchParams(poolId, abi.encode(targetRate));
    }

    function _trackSwap(int128 _amountSpecified) internal {
        feeCalculator.trackSwap(
            address(1),
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: int(_amountSpecified),
                sqrtPriceLimitX96: uint160(
                    int160(TickMath.minUsableTick(poolKey.tickSpacing))
                )
            }),
            toBalanceDelta(-(_amountSpecified / 2), _amountSpecified),
            ""
        );
    }
}
