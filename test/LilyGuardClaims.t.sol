// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {LilyGuard} from "../src/LilyGuard.sol";
import {LilyGuardTestBase} from "./LilyGuardTestBase.sol";
import {RecipientProbe} from "./mocks/RecipientProbe.sol";

contract LilyGuardClaimsTest is LilyGuardTestBase {
    function test_firstBuyOnTokenOnlyFreshManagerMintsThenRedeemsClaim() public {
        actor.modify(key, -600, -60, int256(uint256(LIQUIDITY)));
        assertEq(address(manager).balance, 0, "liquidity supplied only IMD");
        assertGt(imd.balanceOf(address(manager)), 0);
        uint256 beforeRecipient = OWNER.balance;
        (BalanceDelta result,, uint256 fee) = _assertSwap(key, _params(true, -1 ether));
        assertGt(result.amount1(), 0);
        assertEq(fee, 0.01 ether);
        assertEq(OWNER.balance, beforeRecipient, "manager had no ETH before router settlement");
        assertEq(hook.pendingFees(key.toId()), fee);
        assertEq(manager.balanceOf(address(hook), 0), fee);
        assertEq(address(manager).balance, 1 ether, "router settled both AMM input and hook fee");

        vm.prank(STRANGER);
        assertEq(hook.claimFees(key.toId()), fee);
        assertEq(OWNER.balance - beforeRecipient, fee);
        assertEq(hook.pendingFees(key.toId()), 0);
        assertEq(manager.balanceOf(address(hook), 0), 0);
        assertEq(address(manager).balance, 0.99 ether);
        assertEq(hook.claimFees(key.toId()), 0, "no double redemption");
        _assertSettled();
    }

    function test_firstExactTokenOutputBuyAlsoDefersETHFee() public {
        actor.modify(key, -600, -60, int256(uint256(LIQUIDITY)));
        (BalanceDelta result, int128 rawETH, uint256 fee) = _assertSwap(key, _params(true, 1 ether));
        assertEq(result.amount1(), 1 ether);
        assertEq(fee, _abs(int256(rawETH)) / 100);
        assertGt(fee, 0);
        assertEq(hook.pendingFees(key.toId()), fee);
        assertEq(manager.balanceOf(address(hook), 0), fee);
        hook.claimFees(key.toId());
        assertEq(hook.pendingFees(key.toId()), 0);
        _assertSettled();
    }

    function test_unfundedRedemptionRollsBackAndCanBeRetried() public {
        actor.modify(key, -600, -60, int256(uint256(LIQUIDITY)));
        _assertSwap(key, _params(true, -1 ether));
        uint256 managerBalance = address(manager).balance;
        uint256 pending = hook.pendingFees(key.toId());
        vm.deal(address(manager), 0); // Simulate ETH claims not currently liquid at the manager.
        vm.expectRevert();
        hook.claimFees(key.toId());
        assertEq(hook.pendingFees(key.toId()), pending);
        assertEq(manager.balanceOf(address(hook), 0), pending, "burn rolled back");
        vm.deal(address(manager), managerBalance);
        assertEq(hook.claimFees(key.toId()), pending);
        _assertSettled();
    }

    function test_claimsStayIsolatedAcrossFeeTiersAndSpacingAndCanBeClaimedPaused() public {
        RecipientProbe recipient = _recipientProbe();
        recipient.setReject(true);
        PoolKey memory other = _key(12_500, 10);
        manager.initialize(other, Q96);
        actor.modify(key, -600, 600, int256(uint256(LIQUIDITY)));
        actor.modify(other, -600, 600, int256(uint256(LIQUIDITY)));
        _assertSwap(key, _params(true, -1 ether));
        _assertSwap(other, _params(true, -2 ether));
        assertEq(hook.pendingFees(key.toId()), 0.01 ether);
        assertEq(hook.pendingFees(other.toId()), 0.02 ether);
        assertEq(manager.balanceOf(address(hook), 0), 0.03 ether);
        vm.prank(OWNER);
        hook.pause(key.toId());
        recipient.setReject(false);
        uint256 beforeRecipient = OWNER.balance;
        vm.prank(STRANGER);
        hook.claimFees(key.toId());
        assertEq(OWNER.balance - beforeRecipient, 0.01 ether);
        assertEq(hook.pendingFees(other.toId()), 0.02 ether);
        assertEq(manager.balanceOf(address(hook), 0), 0.02 ether);
        assertTrue(hook.paused(key.toId()));
        vm.prank(STRANGER);
        hook.claimFees(other.toId());
        assertEq(OWNER.balance - beforeRecipient, 0.03 ether);
        assertEq(manager.balanceOf(address(hook), 0), 0);
        _assertSettled();
    }

    function test_recipientRejectingETHDefersFeesWithoutFreezingBuysOrSells() public {
        RecipientProbe recipient = _recipientProbe();
        recipient.setReject(true);
        actor.modify(key, -600, 600, int256(uint256(LIQUIDITY)));
        uint256 beforeRecipient = OWNER.balance;
        uint256 total;
        (,, uint256 fee) = _assertSwap(key, _params(true, -1 ether));
        total += fee;
        (,, fee) = _assertSwap(key, _params(true, 1 ether));
        total += fee;
        (,, fee) = _assertSwap(key, _params(false, -1 ether));
        total += fee;
        (,, fee) = _assertSwap(key, _params(false, 1 ether));
        total += fee;
        assertEq(OWNER.balance, beforeRecipient);
        assertEq(hook.pendingFees(key.toId()), total);
        assertEq(manager.balanceOf(address(hook), 0), total);

        vm.expectRevert();
        hook.claimFees(key.toId());
        assertEq(hook.pendingFees(key.toId()), total);
        assertEq(manager.balanceOf(address(hook), 0), total);
        recipient.setReject(false);
        assertEq(hook.claimFees(key.toId()), total);
        assertEq(OWNER.balance - beforeRecipient, total);
        _assertSettled();
    }

    function test_reentryIntoClaimFeesDuringDirectPayoutIsRejected() public {
        RecipientProbe recipient = _recipientProbe();
        actor.modify(key, -600, 600, int256(uint256(LIQUIDITY)));
        recipient.setReentry(address(hook), abi.encodeCall(LilyGuard.claimFees, (key.toId())));
        _assertSwap(key, _params(true, -1 ether));
        assertEq(recipient.attempts(), 1);
        assertFalse(recipient.reentrySucceeded());
        assertEq(hook.pendingFees(key.toId()), 0);
    }

    function test_nestedManagerSwapDuringFeePaymentIsRejected() public {
        RecipientProbe recipient = _recipientProbe();
        actor.modify(key, -600, 600, int256(uint256(LIQUIDITY)));
        recipient.setReentry(
            address(manager), abi.encodeCall(IPoolManager.swap, (key, _params(false, -1 ether), ""))
        );
        _assertSwap(key, _params(true, -1 ether));
        assertEq(recipient.attempts(), 1);
        assertFalse(recipient.reentrySucceeded());
        _assertSettled();
    }

    function test_reentryDuringClaimCannotRedeemTwiceOrPause() public {
        RecipientProbe recipient = _recipientProbe();
        recipient.setReject(true);
        actor.modify(key, -600, 600, int256(uint256(LIQUIDITY)));
        _assertSwap(key, _params(true, -1 ether));
        recipient.setReject(false);
        recipient.setReentry(address(hook), abi.encodeCall(LilyGuard.claimFees, (key.toId())));
        uint256 beforeRecipient = OWNER.balance;
        hook.claimFees(key.toId());
        assertFalse(recipient.reentrySucceeded());
        assertEq(OWNER.balance - beforeRecipient, 0.01 ether);
        assertEq(hook.pendingFees(key.toId()), 0);
        recipient.setReentry(address(hook), abi.encodeCall(LilyGuard.pause, (key.toId())));
        _assertSwap(key, _params(true, -1 ether));
        assertFalse(recipient.reentrySucceeded());
        assertFalse(hook.paused(key.toId()));
        _assertSettled();
    }

    function test_directPayoutDoesNotAutomaticallyRedeemOldClaims() public {
        actor.modify(key, -600, -60, int256(uint256(LIQUIDITY)));
        _assertSwap(key, _params(true, -1 ether));
        uint256 oldPending = hook.pendingFees(key.toId());
        uint256 beforeRecipient = OWNER.balance;
        _assertSwap(key, _params(true, -1 ether));
        assertEq(hook.pendingFees(key.toId()), oldPending);
        assertEq(OWNER.balance - beforeRecipient, 0.01 ether);
        hook.claimFees(key.toId());
        assertEq(OWNER.balance - beforeRecipient, 0.02 ether);
    }

    function test_emptyPoolCannotPayAQuotedFeeForNoTrade() public {
        uint256 beforeRecipient = OWNER.balance;
        try actor.swap(key, _params(true, -1 ether)) {
            revert("unfilled ETH swap accepted");
        } catch (bytes memory reason) {
            _assertHookError(reason, IHooks.afterSwap.selector, LilyGuard.PartialETHFill.selector);
        }
        assertEq(OWNER.balance, beforeRecipient);
        assertEq(hook.pendingFees(key.toId()), 0);
        assertEq(manager.balanceOf(address(hook), 0), 0);
    }

    function _recipientProbe() internal returns (RecipientProbe) {
        vm.etch(OWNER, address(new RecipientProbe()).code);
        return RecipientProbe(payable(OWNER));
    }
}
