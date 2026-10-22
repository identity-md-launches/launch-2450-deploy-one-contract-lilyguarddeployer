// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";

/// @dev Test-only pre-funded trader/LP. Settlement occurs after swap, as with production routers.
/// It also exposes the manager's raw Swap event through the logs for independent fee assertions.
contract PoolActor is IUnlockCallback {
    IPoolManager public immutable manager;
    address private immutable controller;

    constructor(IPoolManager manager_) {
        manager = manager_;
        controller = msg.sender;
    }

    function swap(PoolKey memory key, SwapParams memory params) external returns (BalanceDelta) {
        require(msg.sender == controller, "controller");
        return BalanceDelta.wrap(
            abi.decode(manager.unlock(abi.encode(uint8(0), key, abi.encode(params))), (int256))
        );
    }

    function modify(PoolKey memory key, int24 lower, int24 upper, int256 liquidity)
        external
        returns (BalanceDelta)
    {
        require(msg.sender == controller, "controller");
        ModifyLiquidityParams memory params = ModifyLiquidityParams(lower, upper, liquidity, bytes32(0));
        return BalanceDelta.wrap(
            abi.decode(manager.unlock(abi.encode(uint8(1), key, abi.encode(params))), (int256))
        );
    }

    function donate(PoolKey memory key, uint256 amount0, uint256 amount1) external {
        require(msg.sender == controller, "controller");
        manager.unlock(abi.encode(uint8(2), key, abi.encode(amount0, amount1)));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "manager");
        (uint8 action, PoolKey memory key, bytes memory args) = abi.decode(data, (uint8, PoolKey, bytes));
        BalanceDelta delta;
        if (action == 0) {
            delta = manager.swap(key, abi.decode(args, (SwapParams)), "");
        } else if (action == 1) {
            (delta,) = manager.modifyLiquidity(key, abi.decode(args, (ModifyLiquidityParams)), "");
        } else {
            (uint256 amount0, uint256 amount1) = abi.decode(args, (uint256, uint256));
            delta = manager.donate(key, amount0, amount1, "");
        }
        _settle(key.currency0, delta.amount0());
        _settle(key.currency1, delta.amount1());
        return abi.encode(BalanceDelta.unwrap(delta));
    }

    function _settle(Currency currency, int128 amount) private {
        if (amount < 0) {
            uint256 owed = uint256(-int256(amount));
            manager.sync(currency);
            if (currency.isAddressZero()) {
                manager.settle{value: owed}();
            } else {
                require(IERC20Minimal(Currency.unwrap(currency)).transfer(address(manager), owed), "transfer");
                manager.settle();
            }
        } else if (amount > 0) {
            manager.take(currency, address(this), uint256(uint128(amount)));
        }
    }

    receive() external payable {}
}
