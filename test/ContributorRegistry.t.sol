// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ContributorRegistry} from "../contracts/ContributorRegistry.sol";

contract ContributorRegistryTest is Test {
    ContributorRegistry public registry;

    address public admin = makeAddr("admin");
    address public registrar = makeAddr("registrar");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    bytes32 public constant PROJECT_A = keccak256("PROJECT_A");
    bytes32 public constant PROJECT_B = keccak256("PROJECT_B");

    function setUp() public {
        registry = new ContributorRegistry(admin);

        vm.startPrank(admin);
        registry.grantRole(registry.REGISTRAR_ROLE(), registrar);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                          REGISTRATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Register_Success() public {
        vm.prank(registrar);
        registry.register(alice, PROJECT_A, ContributorRegistry.Role.CONTRIBUTOR, 5000, "ipfs://alice");

        ContributorRegistry.Contributor memory c = registry.getContributor(alice, PROJECT_A);
        assertEq(c.contributor, alice);
        assertEq(c.weight, 5000);
        assertTrue(c.active);
        assertEq(uint8(c.role), uint8(ContributorRegistry.Role.CONTRIBUTOR));
    }

    function test_Register_EmitsEvent() public {
        vm.expectEmit(true, true, false, true);
        emit ContributorRegistry.ContributorRegistered(alice, PROJECT_A, ContributorRegistry.Role.MAINTAINER, 3000);

        vm.prank(registrar);
        registry.register(alice, PROJECT_A, ContributorRegistry.Role.MAINTAINER, 3000, "");
    }

    function test_Register_RevertsIfAlreadyRegistered() public {
        vm.startPrank(registrar);
        registry.register(alice, PROJECT_A, ContributorRegistry.Role.CONTRIBUTOR, 5000, "");
        vm.expectRevert(
            abi.encodeWithSelector(ContributorRegistry.AlreadyRegistered.selector, alice, PROJECT_A)
        );
        registry.register(alice, PROJECT_A, ContributorRegistry.Role.CONTRIBUTOR, 5000, "");
        vm.stopPrank();
    }

    function test_Register_RevertsOnZeroAddress() public {
        vm.prank(registrar);
        vm.expectRevert(ContributorRegistry.InvalidAddress.selector);
        registry.register(address(0), PROJECT_A, ContributorRegistry.Role.CONTRIBUTOR, 5000, "");
    }

    function test_Register_RevertsOnZeroProjectId() public {
        vm.prank(registrar);
        vm.expectRevert(ContributorRegistry.InvalidProjectId.selector);
        registry.register(alice, bytes32(0), ContributorRegistry.Role.CONTRIBUTOR, 5000, "");
    }

    function test_Register_RevertsOnZeroWeight() public {
        vm.prank(registrar);
        vm.expectRevert(abi.encodeWithSelector(ContributorRegistry.InvalidWeight.selector, 0));
        registry.register(alice, PROJECT_A, ContributorRegistry.Role.CONTRIBUTOR, 0, "");
    }

    function test_Register_RevertsOnWeightExceedingMax() public {
        vm.prank(registrar);
        vm.expectRevert(abi.encodeWithSelector(ContributorRegistry.InvalidWeight.selector, 10_001));
        registry.register(alice, PROJECT_A, ContributorRegistry.Role.CONTRIBUTOR, 10_001, "");
    }

    function test_Register_RevertsIfNotRegistrar() public {
        vm.prank(alice);
        vm.expectRevert();
        registry.register(bob, PROJECT_A, ContributorRegistry.Role.CONTRIBUTOR, 5000, "");
    }

    function test_Register_IncrementsTotalContributors() public {
        assertEq(registry.totalContributors(), 0);

        vm.startPrank(registrar);
        registry.register(alice, PROJECT_A, ContributorRegistry.Role.CONTRIBUTOR, 5000, "");
        registry.register(bob, PROJECT_A, ContributorRegistry.Role.MAINTAINER, 3000, "");
        vm.stopPrank();

        assertEq(registry.totalContributors(), 2);
    }

    function test_Register_SameAddressDifferentProjects() public {
        vm.startPrank(registrar);
        registry.register(alice, PROJECT_A, ContributorRegistry.Role.CONTRIBUTOR, 5000, "");
        registry.register(alice, PROJECT_B, ContributorRegistry.Role.MAINTAINER, 3000, "");
        vm.stopPrank();

        assertEq(registry.totalContributors(), 2);
        assertEq(uint8(registry.getContributor(alice, PROJECT_A).role), uint8(ContributorRegistry.Role.CONTRIBUTOR));
        assertEq(uint8(registry.getContributor(alice, PROJECT_B).role), uint8(ContributorRegistry.Role.MAINTAINER));
    }

    function test_Register_EmitsProjectCreatedOnFirstRegistration() public {
        vm.expectEmit(true, true, false, true);
        emit ContributorRegistry.ProjectCreated(PROJECT_A, registrar, uint48(block.timestamp));

        vm.prank(registrar);
        registry.register(alice, PROJECT_A, ContributorRegistry.Role.CONTRIBUTOR, 5000, "");
    }

    function test_Register_ProjectCreatedEmittedOnlyOncePerProject() public {
        // First registration creates the project.
        vm.prank(registrar);
        registry.register(alice, PROJECT_A, ContributorRegistry.Role.CONTRIBUTOR, 5000, "");

        // A second contributor for the same project must NOT re-emit ProjectCreated.
        vm.recordLogs();
        vm.prank(registrar);
        registry.register(bob, PROJECT_A, ContributorRegistry.Role.MAINTAINER, 3000, "");

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 projectCreatedSig = keccak256("ProjectCreated(bytes32,address,uint48)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length > 0) {
                assertTrue(logs[i].topics[0] != projectCreatedSig, "ProjectCreated re-emitted");
            }
        }
    }

    function test_Register_ProjectCreatedEmittedPerDistinctProject() public {
        vm.startPrank(registrar);

        vm.expectEmit(true, true, false, true);
        emit ContributorRegistry.ProjectCreated(PROJECT_A, registrar, uint48(block.timestamp));
        registry.register(alice, PROJECT_A, ContributorRegistry.Role.CONTRIBUTOR, 5000, "");

        vm.expectEmit(true, true, false, true);
        emit ContributorRegistry.ProjectCreated(PROJECT_B, registrar, uint48(block.timestamp));
        registry.register(alice, PROJECT_B, ContributorRegistry.Role.CONTRIBUTOR, 5000, "");

        vm.stopPrank();
    }

/*//////////////////////////////////////////////////////////////
                            UPDATE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Update_Success() public {
        vm.startPrank(registrar);
        registry.register(alice, PROJECT_A, ContributorRegistry.Role.CONTRIBUTOR, 5000, "old");
        registry.update(alice, PROJECT_A, ContributorRegistry.Role.MAINTAINER, 7000, "new");
        vm.stopPrank();

        ContributorRegistry.Contributor memory c = registry.getContributor(alice, PROJECT_A);
        assertEq(uint8(c.role), uint8(ContributorRegistry.Role.MAINTAINER));
        assertEq(c.weight, 7000);
        assertEq(c.metadata, "new");
    }

    function test_Update_RevertsIfNotRegistered() public {
        vm.prank(registrar);
        vm.expectRevert(
            abi.encodeWithSelector(ContributorRegistry.NotRegistered.selector, alice, PROJECT_A)
        );
        registry.update(alice, PROJECT_A, ContributorRegistry.Role.CONTRIBUTOR, 5000, "");
    }

    /*//////////////////////////////////////////////////////////////
                      DEACTIVATION / REACTIVATION
    //////////////////////////////////////////////////////////////*/

    function test_Deactivate_Success() public {
        vm.startPrank(registrar);
        registry.register(alice, PROJECT_A, ContributorRegistry.Role.CONTRIBUTOR, 5000, "");
        registry.deactivate(alice, PROJECT_A);
        vm.stopPrank();

        assertFalse(registry.isActive(alice, PROJECT_A));
    }

    function test_Reactivate_Success() public {
        vm.startPrank(registrar);
        registry.register(alice, PROJECT_A, ContributorRegistry.Role.CONTRIBUTOR, 5000, "");
        registry.deactivate(alice, PROJECT_A);
        registry.reactivate(alice, PROJECT_A);
        vm.stopPrank();

        assertTrue(registry.isActive(alice, PROJECT_A));
    }

    /*//////////////////////////////////////////////////////////////
                              VIEW TESTS
    //////////////////////////////////////////////////////////////*/

    function test_GetProjectContributors() public {
        vm.startPrank(registrar);
        registry.register(alice, PROJECT_A, ContributorRegistry.Role.CONTRIBUTOR, 5000, "");
        registry.register(bob, PROJECT_A, ContributorRegistry.Role.MAINTAINER, 3000, "");
        vm.stopPrank();

        address[] memory contributors = registry.getProjectContributors(PROJECT_A);
        assertEq(contributors.length, 2);
        assertEq(contributors[0], alice);
        assertEq(contributors[1], bob);
    }

    function test_IsRegistered() public {
        assertFalse(registry.isRegistered(alice, PROJECT_A));

        vm.prank(registrar);
        registry.register(alice, PROJECT_A, ContributorRegistry.Role.CONTRIBUTOR, 5000, "");

        assertTrue(registry.isRegistered(alice, PROJECT_A));
    }

    function test_GetWeight() public {
        vm.prank(registrar);
        registry.register(alice, PROJECT_A, ContributorRegistry.Role.CONTRIBUTOR, 4200, "");
        assertEq(registry.getWeight(alice, PROJECT_A), 4200);
    }

    /*//////////////////////////////////////////////////////////////
                          PAUSE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Pause_BlocksRegistration() public {
        vm.prank(admin);
        registry.pause();

        vm.prank(registrar);
        vm.expectRevert();
        registry.register(alice, PROJECT_A, ContributorRegistry.Role.CONTRIBUTOR, 5000, "");
    }

    function test_Unpause_ResumesRegistration() public {
        vm.startPrank(admin);
        registry.pause();
        registry.unpause();
        vm.stopPrank();

        vm.prank(registrar);
        registry.register(alice, PROJECT_A, ContributorRegistry.Role.CONTRIBUTOR, 5000, "");
        assertTrue(registry.isActive(alice, PROJECT_A));
    }

    /*//////////////////////////////////////////////////////////////
                        BATCH REGISTER TESTS
    //////////////////////////////////////////////////////////////*/

    function test_BatchRegister_Success() public {
        ContributorRegistry.ContributorInput[] memory inputs =
            new ContributorRegistry.ContributorInput[](2);
        inputs[0] = ContributorRegistry.ContributorInput({
            contributor: alice,
            projectId: PROJECT_A,
            role: ContributorRegistry.Role.CONTRIBUTOR,
            weight: 5000,
            metadata: "ipfs://alice"
        });
        inputs[1] = ContributorRegistry.ContributorInput({
            contributor: bob,
            projectId: PROJECT_A,
            role: ContributorRegistry.Role.MAINTAINER,
            weight: 3000,
            metadata: "ipfs://bob"
        });

        vm.prank(registrar);
        registry.batchRegister(inputs);

        assertEq(registry.totalContributors(), 2);
        assertTrue(registry.isActive(alice, PROJECT_A));
        assertTrue(registry.isActive(bob, PROJECT_A));
        assertEq(registry.getWeight(alice, PROJECT_A), 5000);
        assertEq(registry.getWeight(bob, PROJECT_A), 3000);
    }

    function test_BatchRegister_EmitsOneEventPerContributor() public {
        ContributorRegistry.ContributorInput[] memory inputs =
            new ContributorRegistry.ContributorInput[](1);
        inputs[0] = ContributorRegistry.ContributorInput({
            contributor: alice,
            projectId: PROJECT_A,
            role: ContributorRegistry.Role.CONTRIBUTOR,
            weight: 5000,
            metadata: ""
        });

        vm.expectEmit(true, true, false, true);
        emit ContributorRegistry.ContributorRegistered(
            alice, PROJECT_A, ContributorRegistry.Role.CONTRIBUTOR, 5000
        );

        vm.prank(registrar);
        registry.batchRegister(inputs);
    }

    function test_BatchRegister_Atomic_RevertsIfAnyEntryInvalid() public {
        ContributorRegistry.ContributorInput[] memory inputs =
            new ContributorRegistry.ContributorInput[](2);
        inputs[0] = ContributorRegistry.ContributorInput({
            contributor: alice,
            projectId: PROJECT_A,
            role: ContributorRegistry.Role.CONTRIBUTOR,
            weight: 5000,
            metadata: ""
        });
        // Second entry has invalid weight — should revert entire batch
        inputs[1] = ContributorRegistry.ContributorInput({
            contributor: bob,
            projectId: PROJECT_A,
            role: ContributorRegistry.Role.MAINTAINER,
            weight: 0,
            metadata: ""
        });

        vm.prank(registrar);
        vm.expectRevert(abi.encodeWithSelector(ContributorRegistry.InvalidWeight.selector, 0));
        registry.batchRegister(inputs);

        // Alice must NOT have been registered (atomicity)
        assertFalse(registry.isRegistered(alice, PROJECT_A));
    }

    function test_BatchRegister_RevertsOnBatchTooLarge() public {
        ContributorRegistry.ContributorInput[] memory inputs =
            new ContributorRegistry.ContributorInput[](51);
        for (uint256 i; i < 51; ++i) {
            inputs[i] = ContributorRegistry.ContributorInput({
                contributor: address(uint160(i + 1)),
                projectId: PROJECT_A,
                role: ContributorRegistry.Role.CONTRIBUTOR,
                weight: 100,
                metadata: ""
            });
        }

        vm.prank(registrar);
        vm.expectRevert(abi.encodeWithSelector(ContributorRegistry.BatchTooLarge.selector, 51));
        registry.batchRegister(inputs);
    }

    function test_BatchRegister_RevertsIfNotRegistrar() public {
        ContributorRegistry.ContributorInput[] memory inputs =
            new ContributorRegistry.ContributorInput[](1);
        inputs[0] = ContributorRegistry.ContributorInput({
            contributor: alice,
            projectId: PROJECT_A,
            role: ContributorRegistry.Role.CONTRIBUTOR,
            weight: 5000,
            metadata: ""
        });

        vm.prank(alice);
        vm.expectRevert();
        registry.batchRegister(inputs);
    }

    function test_BatchRegister_MaxBatchOf50Succeeds() public {
        ContributorRegistry.ContributorInput[] memory inputs =
            new ContributorRegistry.ContributorInput[](50);
        for (uint256 i; i < 50; ++i) {
            inputs[i] = ContributorRegistry.ContributorInput({
                contributor: address(uint160(i + 1)),
                projectId: PROJECT_A,
                role: ContributorRegistry.Role.CONTRIBUTOR,
                weight: 100,
                metadata: ""
            });
        }

        vm.prank(registrar);
        registry.batchRegister(inputs);
        assertEq(registry.totalContributors(), 50);
    }

    /*//////////////////////////////////////////////////////////////
                           FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    function testFuzz_Register_WeightBounds(uint96 weight) public {
        if (weight == 0 || weight > 10_000) {
            vm.prank(registrar);
            vm.expectRevert();
            registry.register(alice, PROJECT_A, ContributorRegistry.Role.CONTRIBUTOR, weight, "");
        } else {
            vm.prank(registrar);
            registry.register(alice, PROJECT_A, ContributorRegistry.Role.CONTRIBUTOR, weight, "");
            assertEq(registry.getWeight(alice, PROJECT_A), weight);
        }
    }
}
