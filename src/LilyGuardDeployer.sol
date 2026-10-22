// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {LilyGuard} from "./LilyGuard.sol";

/// @notice The sole launch application: mines and creates its hook in its own constructor.
/// @dev No post-deployment deploy function, initialization, token creation, or pool creation.
contract LilyGuardDeployer {
    LilyGuard public immutable hook;
    bytes32 public immutable salt;

    event HookDeployed(address indexed hook, bytes32 salt);

    constructor(IPoolManager poolManager, address owner, address feeRecipient) {
        bytes32 initCodeHash = keccak256(
            bytes.concat(type(LilyGuard).creationCode, abi.encode(poolManager, owner, feeRecipient))
        );
        uint160 flags = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
        uint160 mask = Hooks.ALL_HOOK_MASK;
        uint256 candidate = 0;

        // Reuse 85 bytes of scratch memory. Repeated abi.encodePacked in this loop would expand
        // memory on every trial and make on-chain salt mining unnecessarily expensive.
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, shl(248, 0xff))
            mstore(add(ptr, 1), shl(96, address()))
            mstore(add(ptr, 53), initCodeHash)
            for {} 1 {} {
                mstore(add(ptr, 21), candidate)
                let predicted := keccak256(ptr, 85)
                if eq(and(predicted, mask), flags) { break }
                candidate := add(candidate, 1)
            }
        }

        salt = bytes32(candidate);
        hook = new LilyGuard{salt: bytes32(candidate)}(poolManager, owner, feeRecipient);
        emit HookDeployed(address(hook), bytes32(candidate));
    }
}
