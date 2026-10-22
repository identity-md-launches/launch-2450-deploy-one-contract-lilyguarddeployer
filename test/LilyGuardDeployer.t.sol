// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm, VmSafe} from "forge-std/Vm.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {LilyGuard} from "../src/LilyGuard.sol";
import {LilyGuardDeployer} from "../src/LilyGuardDeployer.sol";

contract LilyGuardDeployerTest is Test {
    address private constant MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address private constant OWNER = 0x5Bff2a2FEcD1d6152676813b21346238733bEAB1;
    address private constant IMD = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;
    uint160 private constant FLAGS = 0x20cc;

    function test_launchParametersOnEmptyChainAndExactlyTwoCreationsWithNoExternalCalls() public {
        vm.chainId(4663);
        assertEq(MANAGER.code.length, 0);
        assertEq(IMD.code.length, 0);
        vm.startStateDiffRecording();
        LilyGuardDeployer deployer = new LilyGuardDeployer(IPoolManager(MANAGER), OWNER, OWNER);
        Vm.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();
        LilyGuard hook = deployer.hook();
        uint256 creations;
        for (uint256 i; i < accesses.length; ++i) {
            VmSafe.AccountAccessKind kind = accesses[i].kind;
            assertTrue(
                kind != VmSafe.AccountAccessKind.Call && kind != VmSafe.AccountAccessKind.StaticCall
                    && kind != VmSafe.AccountAccessKind.DelegateCall
                    && kind != VmSafe.AccountAccessKind.CallCode,
                "a constructor called another contract"
            );
            if (kind == VmSafe.AccountAccessKind.Create) {
                ++creations;
                assertTrue(accesses[i].account == address(deployer) || accesses[i].account == address(hook));
                if (accesses[i].account == address(hook)) {
                    assertEq(accesses[i].accessor, address(deployer));
                    assertEq(
                        accesses[i].data,
                        bytes.concat(
                            type(LilyGuard).creationCode, abi.encode(IPoolManager(MANAGER), OWNER, OWNER)
                        ),
                        "constructor arguments passed unchanged"
                    );
                }
            }
        }
        assertEq(creations, 2, "only the deployer and its hook are created");
        assertEq(address(hook.poolManager()), MANAGER);
        assertEq(hook.owner(), OWNER);
        assertEq(hook.feeRecipient(), OWNER);
        assertEq(IMD.code.length, 0, "no token created");
        assertEq(MANAGER.code.length, 0, "no manager or pool interactions");
        assertGt(address(hook).code.length, 0, "hook exists before launch returns");
    }

    function test_saltIsTheFirstMatchingCandidateStartingAtZero() public {
        LilyGuardDeployer deployer = new LilyGuardDeployer(IPoolManager(MANAGER), OWNER, OWNER);
        bytes32 initHash = keccak256(
            bytes.concat(type(LilyGuard).creationCode, abi.encode(IPoolManager(MANAGER), OWNER, OWNER))
        );
        bytes memory preimage = abi.encodePacked(bytes1(0xff), address(deployer), bytes32(0), initHash);
        uint256 chosen = uint256(deployer.salt());
        address predicted;
        for (uint256 i; i <= chosen; ++i) {
            assembly ("memory-safe") {
                mstore(add(preimage, 53), i)
            }
            predicted = address(uint160(uint256(keccak256(preimage))));
            if (i != chosen) {
                require(uint160(predicted) & 0x3fff != FLAGS, "skipped an earlier matching salt");
            }
        }
        assertEq(predicted, address(deployer.hook()));
        assertEq(uint160(predicted) & 0x3fff, FLAGS);
    }

    function test_permissionReportExactlyMatchesAddressBits() public {
        LilyGuard hook = (new LilyGuardDeployer(IPoolManager(MANAGER), OWNER, OWNER)).hook();
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.beforeInitialize && p.beforeSwap && p.afterSwap);
        assertTrue(p.beforeSwapReturnDelta && p.afterSwapReturnDelta);
        assertFalse(p.afterInitialize);
        assertFalse(p.beforeAddLiquidity || p.afterAddLiquidity);
        assertFalse(p.beforeRemoveLiquidity || p.afterRemoveLiquidity);
        assertFalse(p.beforeDonate || p.afterDonate);
        assertFalse(p.afterAddLiquidityReturnDelta || p.afterRemoveLiquidityReturnDelta);
        Hooks.validateHookPermissions(hook, p);
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, FLAGS);
    }

    function test_deployerForwardsDistinctOwnerAndRecipientWithoutTakingPrivileges() public {
        // The constructor remains reusable; the launch uses the exact values in the first test.
        address separateRecipient = address(this);
        LilyGuardDeployer deployer = new LilyGuardDeployer(IPoolManager(MANAGER), OWNER, separateRecipient);
        LilyGuard hook = deployer.hook();
        assertEq(hook.owner(), OWNER);
        assertEq(hook.feeRecipient(), separateRecipient);
        assertEq(address(hook.poolManager()), MANAGER);
        assertNotEq(hook.owner(), address(deployer));
    }

    function test_zeroConstructorArgumentsAreRejected() public {
        vm.expectRevert(LilyGuard.ZeroAddress.selector);
        new LilyGuardDeployer(IPoolManager(address(0)), OWNER, OWNER);
        vm.expectRevert(LilyGuard.ZeroAddress.selector);
        new LilyGuardDeployer(IPoolManager(MANAGER), address(0), OWNER);
        vm.expectRevert(LilyGuard.ZeroAddress.selector);
        new LilyGuardDeployer(IPoolManager(MANAGER), OWNER, address(0));
    }

    function test_directHookDeploymentAtWrongFlagsReverts() public {
        bytes32 initHash = keccak256(
            bytes.concat(type(LilyGuard).creationCode, abi.encode(IPoolManager(MANAGER), OWNER, OWNER))
        );
        bytes32 wrongSalt;
        address predicted;
        while (true) {
            predicted = address(
                uint160(
                    uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), wrongSalt, initHash)))
                )
            );
            if (uint160(predicted) & Hooks.ALL_HOOK_MASK != FLAGS) break;
            wrongSalt = bytes32(uint256(wrongSalt) + 1);
        }
        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, predicted));
        new LilyGuard{salt: wrongSalt}(IPoolManager(MANAGER), OWNER, OWNER);
    }

    function test_deployerHasNoPostLaunchDeployOrAdminFunctions() public {
        LilyGuardDeployer deployer = new LilyGuardDeployer(IPoolManager(MANAGER), OWNER, OWNER);
        string[4] memory forbidden =
            ["deploy()", "deploy(bytes32)", "initialize()", "transferOwnership(address)"];
        for (uint256 i; i < forbidden.length; ++i) {
            (bool ok,) = address(deployer).call(abi.encodeWithSignature(forbidden[i], OWNER));
            assertFalse(ok, forbidden[i]);
        }
    }

    function test_runtimeSizesInitcodeSizesAndAbsenceOfEscapeOpcodes() public {
        LilyGuardDeployer deployer = new LilyGuardDeployer(IPoolManager(MANAGER), OWNER, OWNER);
        _assertRuntime(address(deployer).code);
        _assertRuntime(address(deployer.hook()).code);
        assertLe(type(LilyGuardDeployer).creationCode.length + 96, 49_152);
        assertLe(type(LilyGuard).creationCode.length + 96, 49_152);
    }

    function _assertRuntime(bytes memory code) internal pure {
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        bool reachable = true;
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op == 0x5b) reachable = true;
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            if (reachable) assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "escape opcode");
            if (op == 0x00 || op == 0x56 || op == 0xf3 || op == 0xfd || op == 0xfe || op == 0xff) {
                reachable = false;
            }
        }
    }
}
