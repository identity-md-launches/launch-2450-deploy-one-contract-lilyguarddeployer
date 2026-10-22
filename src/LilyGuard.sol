// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";

interface ITokenSupply {
    function totalSupply() external view returns (uint256);
}

/// @notice Immutable ETH/IMD fee hook with an owner-controlled, per-pool swap pause.
/// @dev Fee deltas always refer to currency0 (native ETH). No token custody or liquidity callbacks.
contract LilyGuard is IHooks, IUnlockCallback {
    using SafeCast for int128;
    using SafeCast for uint256;

    address public constant IMD = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;
    uint256 public constant FEE_BPS = 100;
    uint256 public constant BPS_DENOMINATOR = 10_000;

    IPoolManager public immutable poolManager;
    address public immutable owner;
    address public immutable feeRecipient;

    mapping(PoolId => address) private _token;
    mapping(PoolId => bool) public paused;
    mapping(PoolId => uint256) public pendingFees;
    mapping(PoolId => bool) private _redeeming;
    bool private _entered;

    error ZeroAddress();
    error OnlyPoolManager();
    error OnlyOwner();
    error UnsupportedPool();
    error UnknownPool(PoolId poolId);
    error PoolPaused(PoolId poolId);
    error PartialETHFill(int256 expected, int256 actual);
    error ReentrantCall();
    error UnexpectedUnlock();
    error CallbackNotEnabled();

    event PoolRegistered(PoolId indexed poolId, address indexed token);
    event Paused(PoolId indexed poolId);
    event Unpaused(PoolId indexed poolId);
    event FeePaid(PoolId indexed poolId, uint256 amount);
    event FeeDeferred(PoolId indexed poolId, uint256 amount);
    event FeesClaimed(PoolId indexed poolId, uint256 amount);

    /// @dev Does not call the manager, token, recipient, or any other contract.
    constructor(IPoolManager poolManager_, address owner_, address feeRecipient_) {
        if (address(poolManager_) == address(0) || owner_ == address(0) || feeRecipient_ == address(0)) {
            revert ZeroAddress();
        }
        poolManager = poolManager_;
        owner = owner_;
        feeRecipient = feeRecipient_;
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }

    modifier nonReentrant() {
        if (_entered) revert ReentrantCall();
        _entered = true;
        _;
        _entered = false;
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory p) {
        p.beforeInitialize = true;
        p.beforeSwap = true;
        p.afterSwap = true;
        p.beforeSwapReturnDelta = true;
        p.afterSwapReturnDelta = true;
    }

    function token(PoolId poolId) public view returns (address) {
        address result = _token[poolId];
        if (result == address(0)) revert UnknownPool(poolId);
        return result;
    }

    /// @notice The existing pool token's live supply, in its own raw units.
    function totalSupply(PoolId poolId) external view returns (uint256) {
        return ITokenSupply(token(poolId)).totalSupply();
    }

    function pause(PoolId poolId) external onlyOwner nonReentrant {
        token(poolId);
        paused[poolId] = true;
        emit Paused(poolId);
    }

    function unpause(PoolId poolId) external onlyOwner nonReentrant {
        token(poolId);
        paused[poolId] = false;
        emit Unpaused(poolId);
    }

    function beforeInitialize(address, PoolKey calldata key, uint160)
        external
        onlyPoolManager
        nonReentrant
        returns (bytes4)
    {
        _validateKey(key);
        PoolId poolId = key.toId();
        _token[poolId] = Currency.unwrap(key.currency1);
        emit PoolRegistered(poolId, Currency.unwrap(key.currency1));
        return IHooks.beforeInitialize.selector;
    }

    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        nonReentrant
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _validateKey(key);
        PoolId poolId = key.toId();
        token(poolId);
        if (paused[poolId]) revert PoolPaused(poolId);

        // v4 only permits adjusting the specified currency in beforeSwap. In these two modes,
        // the specified ETH budget/output includes the fee adjustment. afterSwap checks the fill
        // before paying anything. This hook never consumes the full input or skips the AMM.
        int128 fee = _ethSpecified(params) ? _fee(_abs(params.amountSpecified)) : int128(0);
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(fee, 0), 0);
    }

    function afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external onlyPoolManager nonReentrant returns (bytes4, int128) {
        _validateKey(key);
        PoolId poolId = key.toId();
        token(poolId);

        bool specifiedETH = _ethSpecified(params);
        int128 fee;
        if (specifiedETH) {
            fee = _fee(_abs(params.amountSpecified));
            // Positive specified hook delta reduces exact ETH input or increases gross ETH output.
            // Partial fills would otherwise charge a fee on ETH that was never exchanged.
            int256 expected = params.amountSpecified + int256(fee);
            if (int256(delta.amount0()) != expected) {
                revert PartialETHFill(expected, int256(delta.amount0()));
            }
        } else {
            // ETH is unspecified: measure the executed pool delta, including partial fills.
            fee = _fee(_abs(int256(delta.amount0())));
        }

        _payFee(poolId, fee.toUint128());
        return (IHooks.afterSwap.selector, specifiedETH ? int128(0) : fee);
    }

    /// @notice Redeem only this pool's deferred ETH claims to the immutable recipient.
    /// @dev Call after the swap's unlock has settled. A failed redemption preserves all claims.
    /// Anyone may call this, including while the pool's swaps are paused. No fee goes to the caller.
    function claimFees(PoolId poolId) external nonReentrant returns (uint256 amount) {
        token(poolId);
        if (pendingFees[poolId] == 0) return 0;
        _redeeming[poolId] = true;
        amount = abi.decode(poolManager.unlock(abi.encode(poolId)), (uint256));
        if (_redeeming[poolId]) revert UnexpectedUnlock();
    }

    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        PoolId poolId = abi.decode(data, (PoolId));
        if (!_entered || !_redeeming[poolId]) revert UnexpectedUnlock();
        _redeeming[poolId] = false;
        uint256 amount = pendingFees[poolId];
        pendingFees[poolId] = 0;
        // Burning an ERC-6909 claim credits this hook's ETH delta; take consumes exactly that credit.
        poolManager.burn(address(this), 0, amount);
        poolManager.take(Currency.wrap(address(0)), feeRecipient, amount);
        emit FeesClaimed(poolId, amount);
        return abi.encode(amount);
    }

    function _payFee(PoolId poolId, uint256 amount) private {
        if (amount == 0) return;
        if (address(poolManager).balance >= amount) {
            // A recipient rejecting ETH also falls back to a claim instead of freezing swaps.
            try poolManager.take(Currency.wrap(address(0)), feeRecipient, amount) {
                emit FeePaid(poolId, amount);
                return;
            } catch {}
        }
        pendingFees[poolId] += amount;
        poolManager.mint(address(this), 0, amount);
        emit FeeDeferred(poolId, amount);
    }

    function _validateKey(PoolKey calldata key) private view {
        if (
            !key.currency0.isAddressZero() || Currency.unwrap(key.currency1) != IMD
                || address(key.hooks) != address(this)
        ) revert UnsupportedPool();
    }

    function _ethSpecified(SwapParams calldata params) private pure returns (bool) {
        return params.zeroForOne == (params.amountSpecified < 0);
    }

    function _fee(uint256 amount) private pure returns (int128) {
        return FullMath.mulDiv(amount, FEE_BPS, BPS_DENOMINATOR).toInt128();
    }

    function _abs(int256 amount) private pure returns (uint256) {
        return amount < 0 ? uint256(-(amount + 1)) + 1 : uint256(amount);
    }

    // Disabled lifecycle callbacks deliberately revert. Their permission bits are all unset, so
    // the PoolManager never invokes them, and pausing cannot obstruct LP withdrawals or collects.
    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        revert CallbackNotEnabled();
    }

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert CallbackNotEnabled();
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert CallbackNotEnabled();
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert CallbackNotEnabled();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert CallbackNotEnabled();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert CallbackNotEnabled();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert CallbackNotEnabled();
    }
}
