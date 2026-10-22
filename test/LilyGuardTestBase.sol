// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {LilyGuard} from "../src/LilyGuard.sol";
import {LilyGuardDeployer} from "../src/LilyGuardDeployer.sol";
import {MockIMD} from "./mocks/MockIMD.sol";
import {PoolActor} from "./mocks/PoolActor.sol";

abstract contract LilyGuardTestBase is Test {
    using TransientStateLibrary for IPoolManager;

    address internal constant IMD = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;
    address internal constant OWNER = 0x5Bff2a2FEcD1d6152676813b21346238733bEAB1;
    address internal constant STRANGER = address(0xB0B);
    uint160 internal constant Q96 = 1 << 96;
    uint160 internal constant FLAGS = 0x20cc;
    uint128 internal constant LIQUIDITY = 1_000 ether;
    bytes32 internal constant SWAP_TOPIC =
        keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");

    IPoolManager internal manager;
    MockIMD internal imd;
    LilyGuard internal hook;
    LilyGuardDeployer internal deployer;
    PoolActor internal actor;
    PoolKey internal key;

    struct Balances {
        uint256 recipient;
        uint256 actorETH;
        uint256 actorIMD;
        uint256 managerETH;
        uint256 managerIMD;
        uint256 pending;
    }

    function setUp() public virtual {
        manager = IPoolManager(address(new PoolManager(address(this))));
        vm.etch(IMD, address(new MockIMD()).code);
        imd = MockIMD(IMD);
        deployer = new LilyGuardDeployer(manager, OWNER, OWNER);
        hook = deployer.hook();
        actor = new PoolActor(manager);
        vm.deal(address(actor), 100_000 ether);
        imd.mint(address(actor), 100_000 ether);
        key = _key(3_000, 60);
        manager.initialize(key, Q96);
    }

    function _key(uint24 fee, int24 spacing) internal view returns (PoolKey memory) {
        return PoolKey(Currency.wrap(address(0)), Currency.wrap(IMD), fee, spacing, IHooks(address(hook)));
    }

    function _params(bool buy, int256 amount) internal pure returns (SwapParams memory) {
        return SwapParams(buy, amount, buy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1);
    }

    /// @dev Compares the trader's final deltas to the core PoolManager's unadjusted Swap log,
    /// and verifies real ETH/token balances rather than trusting hook events for the fee amount.
    function _assertSwap(PoolKey memory poolKey, SwapParams memory params)
        internal
        returns (BalanceDelta result, int128 rawETH, uint256 fee)
    {
        Balances memory before_ = Balances(
            OWNER.balance,
            address(actor).balance,
            imd.balanceOf(address(actor)),
            address(manager).balance,
            imd.balanceOf(address(manager)),
            hook.pendingFees(poolKey.toId())
        );

        vm.recordLogs();
        result = actor.swap(poolKey, params);
        int128 rawIMD;
        (rawETH, rawIMD) = _readSwapLog(poolKey.toId());
        bool specifiedETH = params.zeroForOne == (params.amountSpecified < 0);
        // The reference calculation uses division by 100 independently of the hook's mulDiv.
        fee = specifiedETH ? _abs(params.amountSpecified) / 100 : _abs(int256(rawETH)) / 100;
        assertEq(int256(result.amount0()), int256(rawETH) - int256(fee), "ETH delta includes exactly one fee");
        assertEq(result.amount1(), rawIMD, "IMD delta must be untouched");
        assertEq(int256(address(actor).balance) - int256(before_.actorETH), result.amount0());
        assertEq(int256(imd.balanceOf(address(actor))) - int256(before_.actorIMD), result.amount1());
        uint256 paid = OWNER.balance - before_.recipient;
        uint256 deferred = hook.pendingFees(poolKey.toId()) - before_.pending;
        assertEq(paid + deferred, fee, "fee conservation");
        assertEq(
            int256(address(manager).balance) - int256(before_.managerETH),
            -int256(result.amount0()) - int256(paid),
            "manager ETH conservation"
        );
        assertEq(
            int256(imd.balanceOf(address(manager))) - int256(before_.managerIMD),
            -int256(result.amount1()),
            "manager IMD conservation"
        );
        assertEq(imd.balanceOf(address(hook)), 0);
        assertEq(address(hook).balance, 0);
        _assertSettled();
    }

    function _readSwapLog(PoolId poolId) internal returns (int128 rawETH, int128 rawIMD) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(manager) && logs[i].topics[0] == SWAP_TOPIC) {
                assertEq(logs[i].topics[1], PoolId.unwrap(poolId));
                (rawETH, rawIMD,,,,) =
                    abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                return (rawETH, rawIMD);
            }
        }
        revert("core swap event missing");
    }

    function _assertHookError(bytes memory wrapped, bytes4 callback, bytes4 expectedError) internal view {
        assertEq(bytes4(wrapped), CustomRevert.WrappedError.selector, "core error wrapper");
        bytes memory body = new bytes(wrapped.length - 4);
        for (uint256 i; i < body.length; ++i) {
            body[i] = wrapped[i + 4];
        }
        (address target, bytes4 selector, bytes memory reason,) =
            abi.decode(body, (address, bytes4, bytes, bytes));
        assertEq(target, address(hook));
        assertEq(selector, callback);
        assertEq(bytes4(reason), expectedError, "underlying hook error");
    }

    function _assertSettled() internal view {
        assertEq(manager.getNonzeroDeltaCount(), 0, "all deltas settled");
        assertEq(manager.currencyDelta(address(hook), Currency.wrap(address(0))), 0);
        assertEq(manager.currencyDelta(address(hook), Currency.wrap(IMD)), 0);
        assertEq(manager.balanceOf(address(hook), uint256(uint160(IMD))), 0, "no IMD claims");
        assertFalse(manager.isUnlocked(), "manager relocked");
    }

    function _abs(int256 value) internal pure returns (uint256) {
        return value < 0 ? uint256(-(value + 1)) + 1 : uint256(value);
    }
}
