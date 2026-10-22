// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {LilyGuard} from "../src/LilyGuard.sol";
import {LilyGuardTestBase} from "./LilyGuardTestBase.sol";

contract LilyGuardAccessTest is LilyGuardTestBase {
    function test_onlyTheGivenOwnerMayPauseAndUnpause() public {
        vm.prank(STRANGER);
        vm.expectRevert(LilyGuard.OnlyOwner.selector);
        hook.pause(key.toId());
        vm.prank(OWNER);
        hook.pause(key.toId());
        vm.prank(STRANGER);
        vm.expectRevert(LilyGuard.OnlyOwner.selector);
        hook.unpause(key.toId());
        vm.prank(address(deployer));
        vm.expectRevert(LilyGuard.OnlyOwner.selector);
        hook.unpause(key.toId());
        vm.prank(OWNER);
        hook.unpause(key.toId());
        assertFalse(hook.paused(key.toId()));
        assertEq(hook.owner(), OWNER);
    }

    function test_ownerHasNoOtherAdminEntryPoints() public {
        string[9] memory forbidden = [
            "transferOwnership(address)",
            "renounceOwnership()",
            "setFee(uint256)",
            "setFeeRecipient(address)",
            "setPoolManager(address)",
            "upgradeTo(address)",
            "sweep(address)",
            "pause()",
            "unpause()"
        ];
        for (uint256 i; i < forbidden.length; ++i) {
            vm.prank(OWNER);
            (bool success,) = address(hook).call(abi.encodeWithSignature(forbidden[i], STRANGER));
            assertFalse(success, forbidden[i]);
        }
        assertEq(hook.owner(), OWNER);
        assertEq(hook.feeRecipient(), OWNER);
    }

    function test_enabledCallbacksAndUnlockRefuseNonManagerCallers() public {
        vm.expectRevert(LilyGuard.OnlyPoolManager.selector);
        hook.beforeInitialize(address(this), key, Q96);
        vm.expectRevert(LilyGuard.OnlyPoolManager.selector);
        hook.beforeSwap(address(this), key, _params(true, -1 ether), "");
        vm.expectRevert(LilyGuard.OnlyPoolManager.selector);
        hook.afterSwap(address(this), key, _params(true, -1 ether), BalanceDelta.wrap(0), "");
        vm.expectRevert(LilyGuard.OnlyPoolManager.selector);
        hook.unlockCallback(abi.encode(key.toId()));
    }

    function test_unsolicitedManagerUnlockCallbackIsRejected() public {
        vm.prank(address(manager));
        vm.expectRevert(LilyGuard.UnexpectedUnlock.selector);
        hook.unlockCallback(abi.encode(key.toId()));
    }

    function test_disabledCallbacksAlwaysRefuse() public {
        ModifyLiquidityParams memory params = ModifyLiquidityParams(-60, 60, 0, bytes32(0));
        BalanceDelta delta = BalanceDelta.wrap(0);
        vm.expectRevert(LilyGuard.CallbackNotEnabled.selector);
        hook.afterInitialize(address(this), key, Q96, 0);
        vm.expectRevert(LilyGuard.CallbackNotEnabled.selector);
        hook.beforeAddLiquidity(address(this), key, params, "");
        vm.expectRevert(LilyGuard.CallbackNotEnabled.selector);
        hook.afterAddLiquidity(address(this), key, params, delta, delta, "");
        vm.expectRevert(LilyGuard.CallbackNotEnabled.selector);
        hook.beforeRemoveLiquidity(address(this), key, params, "");
        vm.expectRevert(LilyGuard.CallbackNotEnabled.selector);
        hook.afterRemoveLiquidity(address(this), key, params, delta, delta, "");
        vm.expectRevert(LilyGuard.CallbackNotEnabled.selector);
        hook.beforeDonate(address(this), key, 0, 0, "");
        vm.expectRevert(LilyGuard.CallbackNotEnabled.selector);
        hook.afterDonate(address(this), key, 0, 0, "");
    }

    function test_existingTokenAndLiveSupplyArePoolScoped() public {
        PoolKey memory other = _key(12_500, 10);
        vm.prank(STRANGER);
        manager.initialize(other, Q96);
        assertEq(hook.token(key.toId()), IMD);
        assertEq(hook.token(other.toId()), IMD);
        assertEq(hook.totalSupply(key.toId()), imd.totalSupply());
        imd.mint(STRANGER, 123456789);
        assertEq(hook.totalSupply(key.toId()), imd.totalSupply());
        assertEq(hook.totalSupply(other.toId()), imd.totalSupply());
    }

    function test_initializationRejectsNonNativeCurrency0() public {
        PoolKey memory invalid = key;
        invalid.currency0 = Currency.wrap(address(1));
        try manager.initialize(invalid, Q96) {
            revert("non-native currency0 accepted");
        } catch (bytes memory reason) {
            _assertHookError(reason, IHooks.beforeInitialize.selector, LilyGuard.UnsupportedPool.selector);
        }
    }

    function test_initializationRejectsAnyOtherToken() public {
        PoolKey memory invalid = key;
        invalid.currency1 = Currency.wrap(address(1));
        try manager.initialize(invalid, Q96) {
            revert("different token accepted");
        } catch (bytes memory reason) {
            _assertHookError(reason, IHooks.beforeInitialize.selector, LilyGuard.UnsupportedPool.selector);
        }
    }

    function test_initializationRejectsReversedCurrencies() public {
        PoolKey memory invalid = key;
        invalid.currency0 = Currency.wrap(IMD);
        invalid.currency1 = Currency.wrap(address(0));
        vm.expectRevert();
        manager.initialize(invalid, Q96);
    }

    function test_managerCallbacksRejectAKeyNamingAnotherHook() public {
        PoolKey memory invalid = key;
        invalid.hooks = IHooks(STRANGER);
        vm.prank(address(manager));
        vm.expectRevert(LilyGuard.UnsupportedPool.selector);
        hook.beforeInitialize(address(this), invalid, Q96);
        vm.prank(address(manager));
        vm.expectRevert(LilyGuard.UnsupportedPool.selector);
        hook.beforeSwap(address(this), invalid, _params(true, -1 ether), "");
        vm.prank(address(manager));
        vm.expectRevert(LilyGuard.UnsupportedPool.selector);
        hook.afterSwap(address(this), invalid, _params(true, -1 ether), BalanceDelta.wrap(0), "");
    }

    function test_failedInitializationLeavesNoPoolRegistration() public {
        PoolKey memory other = _key(12_500, 10);
        vm.expectRevert();
        manager.initialize(other, 0);
        vm.expectRevert(abi.encodeWithSelector(LilyGuard.UnknownPool.selector, other.toId()));
        hook.token(other.toId());
        manager.initialize(other, Q96);
        assertEq(hook.token(other.toId()), IMD);
    }

    function test_unknownPoolsCannotUseTokenSupplyPauseClaimsOrSwapCallbacks() public {
        PoolKey memory other = _key(12_500, 10);
        PoolId unknown = other.toId();
        bytes memory err = abi.encodeWithSelector(LilyGuard.UnknownPool.selector, unknown);
        vm.expectRevert(err);
        hook.token(unknown);
        vm.expectRevert(err);
        hook.totalSupply(unknown);
        vm.expectRevert(err);
        hook.claimFees(unknown);
        vm.prank(OWNER);
        vm.expectRevert(err);
        hook.pause(unknown);
        vm.prank(OWNER);
        vm.expectRevert(err);
        hook.unpause(unknown);
        vm.prank(address(manager));
        vm.expectRevert(err);
        hook.beforeSwap(address(this), other, _params(true, -1 ether), "");
        vm.prank(address(manager));
        vm.expectRevert(err);
        hook.afterSwap(address(this), other, _params(true, -1 ether), BalanceDelta.wrap(0), "");
    }

    function test_extremeSpecifiedAmountsRevertWithSafeCastRatherThanArithmeticOverflow() public {
        vm.prank(address(manager));
        vm.expectRevert(SafeCast.SafeCastOverflow.selector);
        hook.beforeSwap(address(this), key, _params(true, type(int256).min), "");
        vm.prank(address(manager));
        vm.expectRevert(SafeCast.SafeCastOverflow.selector);
        hook.beforeSwap(address(this), key, _params(false, type(int256).max), "");
    }

    function testFuzz_specifiedFeeAndOnlySpecifiedETHDelta(uint128 rawAmount, bool buy) public {
        uint256 amount = bound(rawAmount, 1, uint256(uint128(type(int128).max)));
        SwapParams memory params = _params(buy, buy ? -int256(amount) : int256(amount));
        vm.prank(address(manager));
        (bytes4 selector, BeforeSwapDelta delta, uint24 feeOverride) =
            hook.beforeSwap(address(this), key, params, "");
        assertEq(selector, IHooks.beforeSwap.selector);
        assertEq(int256(BeforeSwapDelta.unwrap(delta) >> 128), int256(amount / 100));
        assertEq(uint128(uint256(BeforeSwapDelta.unwrap(delta))), 0, "no unspecified before delta");
        assertEq(feeOverride, 0, "LP fees left to the pool");
    }
}
