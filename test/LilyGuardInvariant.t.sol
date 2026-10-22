// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {LilyGuard} from "../src/LilyGuard.sol";
import {LilyGuardTestBase} from "./LilyGuardTestBase.sol";
import {PoolActor} from "./mocks/PoolActor.sol";
import {RecipientProbe} from "./mocks/RecipientProbe.sol";

contract LilyGuardHandler is Test {
    IPoolManager public immutable manager;
    LilyGuard public immutable hook;
    PoolActor public immutable actor;
    RecipientProbe public immutable recipient;
    PoolKey private _key0;
    PoolKey private _key1;
    mapping(PoolId => uint256) public expectedFees;
    mapping(PoolId => bool) public expectedPaused;
    bool public rejecting;

    constructor(IPoolManager manager_, LilyGuard hook_, PoolKey memory key0_, PoolKey memory key1_) {
        manager = manager_;
        hook = hook_;
        actor = new PoolActor(manager_);
        recipient = RecipientProbe(payable(hook_.feeRecipient()));
        _key0 = key0_;
        _key1 = key1_;
    }

    function seed() external {
        actor.modify(_key0, -600, 600, 1_000 ether);
        actor.modify(_key1, -600, 600, 1_000 ether);
    }

    function swap(uint8 poolIndex, uint96 rawAmount, bool buy, bool exactInput) external {
        PoolKey memory key = _key(poolIndex);
        uint256 amount = bound(uint256(rawAmount), 1_000_000, 0.01 ether);
        SwapParams memory params = SwapParams(
            buy,
            exactInput ? -int256(amount) : int256(amount),
            buy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        );
        if (expectedPaused[key.toId()]) {
            (bool success,) = address(actor).call(abi.encodeCall(PoolActor.swap, (key, params)));
            require(!success, "paused swap succeeded");
            return;
        }
        vm.recordLogs();
        BalanceDelta delta = actor.swap(key, params);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
        bool found;
        int128 ethTraded;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(manager) && logs[i].topics[0] == topic) {
                (ethTraded,,,,,) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                found = true;
                break;
            }
        }
        require(found, "missing core event");
        uint256 fee = (buy == exactInput ? amount : _abs(int256(ethTraded))) / 100;
        expectedFees[key.toId()] += fee;
        assertEq(int256(delta.amount0()), int256(ethTraded) - int256(fee));
    }

    function setPaused(uint8 poolIndex, bool pause_) external {
        PoolId poolId = _key(poolIndex).toId();
        expectedPaused[poolId] = pause_;
        vm.prank(hook.owner());
        if (pause_) hook.pause(poolId);
        else hook.unpause(poolId);
    }

    function setRecipientRejection(bool reject_) external {
        rejecting = reject_;
        recipient.setReject(reject_);
    }

    function claim(uint8 poolIndex) external {
        PoolId poolId = _key(poolIndex).toId();
        uint256 pending = hook.pendingFees(poolId);
        if (rejecting && pending != 0) {
            (bool success,) = address(hook).call(abi.encodeCall(LilyGuard.claimFees, (poolId)));
            require(!success, "claim to rejecting recipient succeeded");
            assertEq(hook.pendingFees(poolId), pending);
        } else {
            assertEq(hook.claimFees(poolId), pending);
        }
    }

    function collect(uint8 poolIndex) external {
        actor.modify(_key(poolIndex), -600, 600, 0);
    }

    function _key(uint8 index) private view returns (PoolKey memory) {
        return index % 2 == 0 ? _key0 : _key1;
    }

    function _abs(int256 value) private pure returns (uint256) {
        return value < 0 ? uint256(-value) : uint256(value);
    }
}

contract LilyGuardInvariantTest is LilyGuardTestBase {
    LilyGuardHandler private handler;
    PoolKey private other;
    uint256 private initialETH;
    uint256 private initialIMD;
    uint256 private initialRecipientETH;

    function setUp() public override {
        super.setUp();
        vm.etch(OWNER, address(new RecipientProbe()).code);
        other = _key(12_500, 10);
        manager.initialize(other, Q96);
        handler = new LilyGuardHandler(manager, hook, key, other);
        vm.deal(address(handler.actor()), 100_000 ether);
        imd.mint(address(handler.actor()), 100_000 ether);
        handler.seed();
        initialETH = address(handler.actor()).balance + address(manager).balance + OWNER.balance;
        initialIMD = imd.balanceOf(address(handler.actor())) + imd.balanceOf(address(manager));
        initialRecipientETH = OWNER.balance;

        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = LilyGuardHandler.swap.selector;
        selectors[1] = LilyGuardHandler.setPaused.selector;
        selectors[2] = LilyGuardHandler.setRecipientRejection.selector;
        selectors[3] = LilyGuardHandler.claim.selector;
        selectors[4] = LilyGuardHandler.collect.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariant_ETHAndIMDAreConservedAndNeverHeldByHook() public view {
        assertEq(address(handler.actor()).balance + address(manager).balance + OWNER.balance, initialETH);
        assertEq(imd.balanceOf(address(handler.actor())) + imd.balanceOf(address(manager)), initialIMD);
        assertEq(address(hook).balance, 0);
        assertEq(imd.balanceOf(address(hook)), 0);
    }

    function invariant_everyFeeIsEitherPaidOrAccountedAsAPoolClaim() public view {
        uint256 pending = hook.pendingFees(key.toId()) + hook.pendingFees(other.toId());
        uint256 expected = handler.expectedFees(key.toId()) + handler.expectedFees(other.toId());
        assertEq(manager.balanceOf(address(hook), 0), pending);
        assertEq(OWNER.balance - initialRecipientETH + pending, expected);
    }

    function invariant_pauseStateIsPoolSpecificAndManagerAlwaysRelocks() public view {
        assertEq(hook.paused(key.toId()), handler.expectedPaused(key.toId()));
        assertEq(hook.paused(other.toId()), handler.expectedPaused(other.toId()));
        _assertSettled();
    }
}
