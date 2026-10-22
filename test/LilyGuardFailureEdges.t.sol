// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {Pool} from "v4-core/src/libraries/Pool.sol";
import {LilyGuard} from "../src/LilyGuard.sol";
import {LilyGuardTestBase} from "./LilyGuardTestBase.sol";
import {RecipientProbe} from "./mocks/RecipientProbe.sol";

contract LilyGuardFailureEdgesTest is LilyGuardTestBase {
    using StateLibrary for IPoolManager;

    function test_zeroAmountSwapCannotPayOrAccrueAClaim() public {
        actor.modify(key, -600, 600, int256(uint256(LIQUIDITY)));
        bytes32 beforeState = _digest();
        vm.expectRevert(IPoolManager.SwapAmountCannotBeZero.selector);
        actor.swap(key, _params(true, 0));
        vm.expectRevert(IPoolManager.SwapAmountCannotBeZero.selector);
        actor.swap(key, _params(false, 0));
        assertEq(_digest(), beforeState);
        _assertSettled();
    }

    function test_duplicateInitializationCannotClearPauseOrExistingClaims() public {
        _seedClaims();
        vm.prank(OWNER);
        hook.pause(key.toId());
        bytes32 beforeState = _digest();
        vm.expectRevert(Pool.PoolAlreadyInitialized.selector);
        manager.initialize(key, Q96);
        assertEq(_digest(), beforeState);
        assertTrue(hook.paused(key.toId()));
        assertGt(hook.pendingFees(key.toId()), 0);
        _assertSettled();
    }

    function test_unrelatedCreatorCanInitializeSameFeeDifferentSpacingWhileFirstPoolPaused() public {
        _seedClaims();
        uint256 pending = hook.pendingFees(key.toId());
        vm.prank(OWNER);
        hook.pause(key.toId());
        PoolKey memory other = _key(3_000, 10);
        vm.prank(STRANGER);
        manager.initialize(other, Q96);
        assertEq(hook.token(other.toId()), IMD);
        assertFalse(hook.paused(other.toId()));
        assertEq(hook.pendingFees(other.toId()), 0);
        assertEq(hook.pendingFees(key.toId()), pending);
        assertTrue(hook.paused(key.toId()));
        assertEq(manager.balanceOf(address(hook), 0), pending);
        _assertSettled();
    }

    function test_liquidityExhaustionRollsBackBothETHSpecifiedDirectionsAndOldClaims() public {
        _seedClaims();
        bytes32 beforeState = _digest();
        for (uint256 i; i < 2; ++i) {
            bool buy = i == 0;
            try actor.swap(key, _params(buy, buy ? -int256(1_000 ether) : int256(1_000 ether))) {
                revert("exhausted liquidity accepted an ETH quote");
            } catch (bytes memory reason) {
                _assertHookError(reason, IHooks.afterSwap.selector, LilyGuard.PartialETHFill.selector);
            }
            assertEq(_digest(), beforeState, "partial fill changed pre-existing balances or claims");
            _assertSettled();
        }
    }

    function test_emptyTokenSpecifiedSwapsCannotManufactureFeesOrOutput() public {
        uint256 recipientBefore = OWNER.balance;
        BalanceDelta buy = actor.swap(key, _params(true, 1 ether));
        BalanceDelta sell = actor.swap(key, _params(false, -1 ether));
        assertEq(BalanceDelta.unwrap(buy), 0);
        assertEq(BalanceDelta.unwrap(sell), 0);
        assertEq(OWNER.balance, recipientBefore);
        assertEq(hook.pendingFees(key.toId()), 0);
        assertEq(manager.balanceOf(address(hook), 0), 0);
        _assertSettled();
    }

    function test_oneWeiTokenSpecifiedTradesRoundFeeToZero() public {
        actor.modify(key, -600, 600, int256(uint256(LIQUIDITY)));
        (BalanceDelta buy,, uint256 buyFee) = _assertSwap(key, _params(true, 1));
        assertEq(buy.amount1(), 1);
        assertEq(buyFee, 0);
        (BalanceDelta sell,, uint256 sellFee) = _assertSwap(key, _params(false, -1));
        assertEq(sell.amount1(), -1);
        assertEq(sellFee, 0);
        assertEq(manager.balanceOf(address(hook), 0), 0);
    }

    function test_exactFeeBalancePaysDirectly() public {
        _assertManagerBalanceBoundary(true);
    }

    function test_oneWeiShortOfFeeDefersWholeFeeAndCanRedeemAfterSettlement() public {
        _assertManagerBalanceBoundary(false);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_unknownPoolCannotRedeemPauseOrEraseAnotherPoolsClaims(bytes32 rawId) public {
        _seedClaims();
        PoolId unknown = PoolId.wrap(rawId);
        if (rawId == PoolId.unwrap(key.toId())) unknown = _key(3_001, 60).toId();
        bytes32 beforeState = _digest();
        bytes memory reason = abi.encodeWithSelector(LilyGuard.UnknownPool.selector, unknown);
        vm.expectRevert(reason);
        hook.claimFees(unknown);
        vm.prank(OWNER);
        vm.expectRevert(reason);
        hook.pause(unknown);
        vm.prank(OWNER);
        vm.expectRevert(reason);
        hook.unpause(unknown);
        assertEq(_digest(), beforeState);
        assertFalse(hook.paused(unknown));
        assertEq(hook.pendingFees(unknown), 0);
        _assertSettled();
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_nonNativeCurrency0CannotRegisterEvenWhenCurrenciesAreSorted(uint160 rawCurrency)
        public
    {
        PoolKey memory invalid = key;
        invalid.currency0 = Currency.wrap(address(uint160(bound(rawCurrency, 1, uint160(IMD) - 1))));
        _assertUnsupportedInitialization(invalid);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_nativePoolWithAnyOtherTokenCannotRegister(uint160 rawCurrency) public {
        PoolKey memory invalid = key;
        uint160 tokenAddress = uint160(bound(rawCurrency, 1, type(uint160).max));
        if (tokenAddress == uint160(IMD)) ++tokenAddress;
        invalid.currency1 = Currency.wrap(address(tokenAddress));
        _assertUnsupportedInitialization(invalid);
    }

    function _assertManagerBalanceBoundary(bool coversFee) private {
        // First quote the executed ETH side against real core, then restore the entire state.
        // The manager's cash balance does not affect AMM pricing.
        actor.modify(key, -600, -60, int256(uint256(LIQUIDITY)));
        assertEq(address(manager).balance, 0);
        uint256 snapshot = vm.snapshotState();
        (,, uint256 fee) = _assertSwap(key, _params(true, 1 ether));
        assertGt(fee, 0);
        assertTrue(vm.revertToState(snapshot));
        vm.deal(address(manager), coversFee ? fee : fee - 1);
        uint256 beforeRecipient = OWNER.balance;
        (,, uint256 actualFee) = _assertSwap(key, _params(true, 1 ether));
        assertEq(actualFee, fee);
        assertEq(OWNER.balance - beforeRecipient, coversFee ? fee : 0);
        assertEq(hook.pendingFees(key.toId()), coversFee ? 0 : fee);
        assertEq(manager.balanceOf(address(hook), 0), coversFee ? 0 : fee);
        vm.prank(STRANGER);
        assertEq(hook.claimFees(key.toId()), coversFee ? 0 : fee);
        assertEq(OWNER.balance - beforeRecipient, fee);
        assertEq(hook.pendingFees(key.toId()), 0);
        assertEq(manager.balanceOf(address(hook), 0), 0);
        _assertSettled();
    }

    function _assertUnsupportedInitialization(PoolKey memory invalid) private {
        bytes32 beforeState = _digest();
        try manager.initialize(invalid, Q96) {
            revert("unsupported currency registered");
        } catch (bytes memory reason) {
            _assertHookError(reason, IHooks.beforeInitialize.selector, LilyGuard.UnsupportedPool.selector);
        }
        vm.expectRevert(abi.encodeWithSelector(LilyGuard.UnknownPool.selector, invalid.toId()));
        hook.token(invalid.toId());
        assertEq(_digest(), beforeState);
        assertEq(hook.pendingFees(invalid.toId()), 0);
        _assertSettled();
    }

    function _seedClaims() private {
        vm.etch(OWNER, address(new RecipientProbe()).code);
        RecipientProbe(payable(OWNER)).setReject(true);
        actor.modify(key, -600, 600, int256(uint256(LIQUIDITY)));
        (,, uint256 fee) = _assertSwap(key, _params(false, -1 ether));
        assertGt(fee, 0);
        assertEq(hook.pendingFees(key.toId()), fee);
    }

    function _digest() private view returns (bytes32) {
        (uint160 price, int24 tick, uint24 protocolFee, uint24 lpFee) = manager.getSlot0(key.toId());
        bytes32 poolState = keccak256(
            abi.encode(
                price, tick, protocolFee, lpFee, manager.getLiquidity(key.toId()), hook.paused(key.toId())
            )
        );
        return keccak256(
            abi.encode(
                poolState,
                OWNER.balance,
                address(actor).balance,
                address(manager).balance,
                imd.balanceOf(address(actor)),
                imd.balanceOf(address(manager)),
                hook.pendingFees(key.toId()),
                manager.balanceOf(address(hook), 0)
            )
        );
    }
}
