// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {MilestoneVault} from "../contracts/MilestoneVault.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";

contract MilestoneVaultTest is Test {
    MilestoneVault public vault;
    ERC20Mock public token;

    address public admin = makeAddr("admin");
    address public funder = makeAddr("funder");
    address public recipient = makeAddr("recipient");
    address public validator = makeAddr("validator");
    address public attacker = makeAddr("attacker");
    address public arbitrator = makeAddr("arbitrator");

    uint48 public constant DISPUTE_WINDOW = 7 days;

    function setUp() public {
        vault = new MilestoneVault(admin);
        token = new ERC20Mock("Test Token", "TST", 18);

        vm.deal(funder, 100 ether);
        token.mint(funder, 1_000_000e18);

        vm.prank(funder);
        token.approve(address(vault), type(uint256).max);

        vm.startPrank(admin);
        vault.grantRole(vault.ARBITRATOR_ROLE(), arbitrator);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                        VAULT CREATION
    //////////////////////////////////////////////////////////////*/

    function test_CreateETHVault_Success() public {
        vm.prank(funder);
        uint256 vaultId = vault.createETHVault{value: 10 ether}(recipient, validator, true, DISPUTE_WINDOW);

        MilestoneVault.Vault memory v = vault.getVault(vaultId);
        assertEq(v.funder, funder);
        assertEq(v.recipient, recipient);
        assertEq(v.validator, validator);
        assertEq(v.token, address(0));
        assertEq(v.totalDeposited, 10 ether);
        assertTrue(v.sequential);
        assertEq(v.disputeWindowSeconds, DISPUTE_WINDOW);
        assertEq(uint8(v.status), uint8(MilestoneVault.VaultStatus.Active));
    }

    function test_CreateETHVault_EmitsEvent() public {
        vm.expectEmit(true, true, false, true);
        emit MilestoneVault.VaultCreated(0, funder, recipient, validator, address(0), 5 ether);

        vm.prank(funder);
        vault.createETHVault{value: 5 ether}(recipient, validator, true, DISPUTE_WINDOW);
    }

    function test_CreateETHVault_RevertsOnZeroRecipient() public {
        vm.prank(funder);
        vm.expectRevert(MilestoneVault.InvalidAddress.selector);
        vault.createETHVault{value: 1 ether}(address(0), validator, true, DISPUTE_WINDOW);
    }

    function test_CreateETHVault_RevertsOnZeroValidator() public {
        vm.prank(funder);
        vm.expectRevert(MilestoneVault.InvalidAddress.selector);
        vault.createETHVault{value: 1 ether}(recipient, address(0), true, DISPUTE_WINDOW);
    }

    function test_CreateETHVault_RevertsOnInvalidDisputeWindow() public {
        vm.prank(funder);
        vm.expectRevert(
            abi.encodeWithSelector(MilestoneVault.InvalidDisputeWindow.selector, uint48(0))
        );
        vault.createETHVault{value: 1 ether}(recipient, validator, true, 0);

        vm.prank(funder);
        uint48 tooLong = vault.MAX_DISPUTE_WINDOW() + 1;
        vm.expectRevert(
            abi.encodeWithSelector(MilestoneVault.InvalidDisputeWindow.selector, tooLong)
        );
        vault.createETHVault{value: 1 ether}(recipient, validator, true, tooLong);
    }

    function test_CreateERC20Vault_Success() public {
        vm.prank(funder);
        uint256 vaultId =
            vault.createERC20Vault(recipient, validator, address(token), 1000e18, true, DISPUTE_WINDOW);

        MilestoneVault.Vault memory v = vault.getVault(vaultId);
        assertEq(v.token, address(token));
        assertEq(v.totalDeposited, 1000e18);
        assertEq(token.balanceOf(address(vault)), 1000e18);
    }

    /*//////////////////////////////////////////////////////////////
                       MILESTONE MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    function _setupVaultWithMilestone(uint256 amount)
        internal
        returns (uint256 vaultId, uint256 milestoneIdx)
    {
        vm.prank(funder);
        vaultId = vault.createETHVault{value: amount}(recipient, validator, true, DISPUTE_WINDOW);

        vm.prank(funder);
        vault.addMilestone(vaultId, amount, "ipfs://milestone-1");
        milestoneIdx = 0;
    }

    function test_AddMilestone_Success() public {
        vm.prank(funder);
        uint256 vaultId = vault.createETHVault{value: 10 ether}(recipient, validator, true, DISPUTE_WINDOW);

        vm.prank(funder);
        vault.addMilestone(vaultId, 5 ether, "ipfs://milestone-1");

        MilestoneVault.Milestone[] memory milestones = vault.getMilestones(vaultId);
        assertEq(milestones.length, 1);
        assertEq(milestones[0].amount, 5 ether);
        assertEq(uint8(milestones[0].status), uint8(MilestoneVault.MilestoneStatus.Pending));
    }

    function test_AddMilestone_RevertsIfExceedsDeposit() public {
        vm.prank(funder);
        uint256 vaultId = vault.createETHVault{value: 5 ether}(recipient, validator, true, DISPUTE_WINDOW);

        vm.prank(funder);
        vm.expectRevert(
            abi.encodeWithSelector(MilestoneVault.MilestoneTotalExceedsDeposit.selector, 6 ether, 5 ether)
        );
        vault.addMilestone(vaultId, 6 ether, "too much");
    }

    function test_AddMilestone_RevertsIfNotFunder() public {
        vm.prank(funder);
        uint256 vaultId = vault.createETHVault{value: 5 ether}(recipient, validator, true, DISPUTE_WINDOW);

        vm.prank(attacker);
        vm.expectRevert(MilestoneVault.Unauthorized.selector);
        vault.addMilestone(vaultId, 5 ether, "attack");
    }

    /*//////////////////////////////////////////////////////////////
                       MILESTONE SUBMISSION
    //////////////////////////////////////////////////////////////*/

    function test_SubmitMilestone_Success() public {
        (uint256 vaultId,) = _setupVaultWithMilestone(5 ether);

        vm.prank(recipient);
        vault.submitMilestone(vaultId, 0);

        MilestoneVault.Milestone memory m = vault.getMilestone(vaultId, 0);
        assertEq(uint8(m.status), uint8(MilestoneVault.MilestoneStatus.Submitted));
        assertGt(m.submittedAt, 0);
    }

    function test_SubmitMilestone_RevertsIfNotRecipient() public {
        (uint256 vaultId,) = _setupVaultWithMilestone(5 ether);

        vm.prank(attacker);
        vm.expectRevert(MilestoneVault.Unauthorized.selector);
        vault.submitMilestone(vaultId, 0);
    }

    function test_SubmitMilestone_EnforcesSequentialOrder() public {
        vm.prank(funder);
        uint256 vaultId = vault.createETHVault{value: 10 ether}(recipient, validator, true, DISPUTE_WINDOW);

        vm.startPrank(funder);
        vault.addMilestone(vaultId, 5 ether, "milestone-0");
        vault.addMilestone(vaultId, 5 ether, "milestone-1");
        vm.stopPrank();

        // Trying to submit milestone 1 before 0 is approved should revert
        vm.prank(recipient);
        vault.submitMilestone(vaultId, 0);

        vm.prank(recipient);
        vm.expectRevert(
            abi.encodeWithSelector(MilestoneVault.PreviousMilestoneNotApproved.selector, 0)
        );
        vault.submitMilestone(vaultId, 1);
    }

    /*//////////////////////////////////////////////////////////////
                       MILESTONE APPROVAL
    //////////////////////////////////////////////////////////////*/

    function test_ApproveMilestone_ReleasesFunds() public {
        (uint256 vaultId,) = _setupVaultWithMilestone(5 ether);

        vm.prank(recipient);
        vault.submitMilestone(vaultId, 0);

        uint256 recipientBefore = recipient.balance;
        vm.prank(validator);
        vault.approveMilestone(vaultId, 0);

        assertEq(recipient.balance - recipientBefore, 5 ether);
        assertEq(uint8(vault.getMilestone(vaultId, 0).status), uint8(MilestoneVault.MilestoneStatus.Approved));
        assertEq(uint8(vault.getVault(vaultId).status), uint8(MilestoneVault.VaultStatus.Completed));
    }

    function test_ApproveMilestone_EmitsDescriptionURI() public {
        (uint256 vaultId,) = _setupVaultWithMilestone(5 ether);

        vm.prank(recipient);
        vault.submitMilestone(vaultId, 0);

        // The approval event carries the milestone's descriptionURI so off-chain
        // indexers can reconstruct the timeline without a separate getMilestone call.
        vm.expectEmit(true, true, false, true);
        emit MilestoneVault.MilestoneApproved(vaultId, 0, 5 ether, "ipfs://milestone-1");

        vm.prank(validator);
        vault.approveMilestone(vaultId, 0);
    }

function test_ApproveMilestone_RevertsIfNotValidator() public {
        (uint256 vaultId,) = _setupVaultWithMilestone(5 ether);

        vm.prank(recipient);
        vault.submitMilestone(vaultId, 0);

        vm.prank(attacker);
        vm.expectRevert(MilestoneVault.Unauthorized.selector);
        vault.approveMilestone(vaultId, 0);
    }

    function test_ApproveMilestone_RevertsIfNotSubmitted() public {
        (uint256 vaultId,) = _setupVaultWithMilestone(5 ether);

        vm.prank(validator);
        vm.expectRevert(
            abi.encodeWithSelector(MilestoneVault.MilestoneNotSubmitted.selector, vaultId, 0)
        );
        vault.approveMilestone(vaultId, 0);
    }

    /*//////////////////////////////////////////////////////////////
                       MILESTONE REJECTION
    //////////////////////////////////////////////////////////////*/

    function test_RejectMilestone_ResetsToPending() public {
        (uint256 vaultId,) = _setupVaultWithMilestone(5 ether);

        vm.prank(recipient);
        vault.submitMilestone(vaultId, 0);

        vm.prank(validator);
        vault.rejectMilestone(vaultId, 0);

        assertEq(uint8(vault.getMilestone(vaultId, 0).status), uint8(MilestoneVault.MilestoneStatus.Pending));
    }

    function test_RejectThenResubmit_Success() public {
        (uint256 vaultId,) = _setupVaultWithMilestone(5 ether);

        vm.prank(recipient);
        vault.submitMilestone(vaultId, 0);

        vm.prank(validator);
        vault.rejectMilestone(vaultId, 0);

        // Resubmit after rework
        vm.prank(recipient);
        vault.submitMilestone(vaultId, 0);

        uint256 before = recipient.balance;
        vm.prank(validator);
        vault.approveMilestone(vaultId, 0);
        assertEq(recipient.balance - before, 5 ether);
    }

    /*//////////////////////////////////////////////////////////////
                        VAULT CANCELLATION
    //////////////////////////////////////////////////////////////*/

    function test_CancelVault_RefundsFunder() public {
        vm.prank(funder);
        uint256 vaultId = vault.createETHVault{value: 10 ether}(recipient, validator, true, DISPUTE_WINDOW);

        // Add both milestones upfront so the vault stays Active after ms-0 is approved
        vm.startPrank(funder);
        vault.addMilestone(vaultId, 5 ether, "ms-0");
        vault.addMilestone(vaultId, 5 ether, "ms-1");
        vm.stopPrank();

        // Approve first milestone (releases 5 ETH); vault stays Active because ms-1 is Pending
        vm.prank(recipient);
        vault.submitMilestone(vaultId, 0);
        vm.prank(validator);
        vault.approveMilestone(vaultId, 0);

        uint256 funderBefore = funder.balance;
        vm.prank(funder);
        vault.cancelVault(vaultId);

        // 5 ETH was released; remaining 5 ETH should be refunded
        assertEq(funder.balance - funderBefore, 5 ether);
        assertEq(uint8(vault.getVault(vaultId).status), uint8(MilestoneVault.VaultStatus.Cancelled));
    }

    function test_CancelVault_RevertsIfMilestoneSubmitted() public {
        (uint256 vaultId,) = _setupVaultWithMilestone(5 ether);

        vm.prank(recipient);
        vault.submitMilestone(vaultId, 0);

        vm.prank(funder);
        vm.expectRevert();
        vault.cancelVault(vaultId);
    }

    function test_CancelVault_RevertsIfNotFunder() public {
        vm.prank(funder);
        uint256 vaultId = vault.createETHVault{value: 5 ether}(recipient, validator, true, DISPUTE_WINDOW);

        vm.prank(attacker);
        vm.expectRevert(MilestoneVault.Unauthorized.selector);
        vault.cancelVault(vaultId);
    }

    /*//////////////////////////////////////////////////////////////
                     VALIDATOR UPDATE
    //////////////////////////////////////////////////////////////*/

    function test_UpdateValidator_Success() public {
        vm.prank(funder);
        uint256 vaultId = vault.createETHVault{value: 5 ether}(recipient, validator, true, DISPUTE_WINDOW);

        address newValidator = makeAddr("newValidator");
        vm.prank(funder);
        vault.updateValidator(vaultId, newValidator);

        assertEq(vault.getVault(vaultId).validator, newValidator);
    }

    /*//////////////////////////////////////////////////////////////
                        TOP-UP (FUND)
    //////////////////////////////////////////////////////////////*/

    function test_FundETHVault_IncreasesDeposit() public {
        vm.prank(funder);
        uint256 vaultId = vault.createETHVault{value: 5 ether}(recipient, validator, true, DISPUTE_WINDOW);

        vm.deal(attacker, 5 ether); // anyone can top-up
        vm.prank(attacker);
        vault.fundETHVault{value: 5 ether}(vaultId);

        assertEq(vault.getVault(vaultId).totalDeposited, 10 ether);
    }

    /*//////////////////////////////////////////////////////////////
                         REMAINING BALANCE
    //////////////////////////////////////////////////////////////*/

    function test_RemainingBalance_DecreasesOnApproval() public {
        (uint256 vaultId,) = _setupVaultWithMilestone(5 ether);

        assertEq(vault.remainingBalance(vaultId), 5 ether);

        vm.prank(recipient);
        vault.submitMilestone(vaultId, 0);
        vm.prank(validator);
        vault.approveMilestone(vaultId, 0);

        assertEq(vault.remainingBalance(vaultId), 0);
    }

    /*//////////////////////////////////////////////////////////////
                        MULTI-MILESTONE FLOW
    //////////////////////////////////////////////////////////////*/

    function test_FullMultiMilestoneFlow() public {
        vm.prank(funder);
        uint256 vaultId = vault.createETHVault{value: 9 ether}(recipient, validator, true, DISPUTE_WINDOW);

        vm.startPrank(funder);
        vault.addMilestone(vaultId, 3 ether, "phase-1");
        vault.addMilestone(vaultId, 3 ether, "phase-2");
        vault.addMilestone(vaultId, 3 ether, "phase-3");
        vm.stopPrank();

        for (uint256 i; i < 3; i++) {
            vm.prank(recipient);
            vault.submitMilestone(vaultId, i);
            vm.prank(validator);
            vault.approveMilestone(vaultId, i);
        }

        assertEq(recipient.balance, 9 ether);
        assertEq(uint8(vault.getVault(vaultId).status), uint8(MilestoneVault.VaultStatus.Completed));
    }

    /*//////////////////////////////////////////////////////////////
                    PARALLEL MILESTONE FLOW
    //////////////////////////////////////////////////////////////*/

    function test_ParallelVault_AnyMilestoneCanBeSubmittedFirst() public {
        vm.prank(funder);
        uint256 vaultId = vault.createETHVault{value: 9 ether}(recipient, validator, false, DISPUTE_WINDOW);

        vm.startPrank(funder);
        vault.addMilestone(vaultId, 3 ether, "frontend");
        vault.addMilestone(vaultId, 3 ether, "backend");
        vault.addMilestone(vaultId, 3 ether, "devops");
        vm.stopPrank();

        assertFalse(vault.getVault(vaultId).sequential);

        // Submit and approve milestone 2 first, then 0, skipping 1 for now
        vm.prank(recipient);
        vault.submitMilestone(vaultId, 2);
        vm.prank(validator);
        vault.approveMilestone(vaultId, 2);

        vm.prank(recipient);
        vault.submitMilestone(vaultId, 0);
        vm.prank(validator);
        vault.approveMilestone(vaultId, 0);

        // Vault still Active — milestone 1 pending
        assertEq(uint8(vault.getVault(vaultId).status), uint8(MilestoneVault.VaultStatus.Active));

        // Now approve milestone 1 last
        vm.prank(recipient);
        vault.submitMilestone(vaultId, 1);
        vm.prank(validator);
        vault.approveMilestone(vaultId, 1);

        assertEq(recipient.balance, 9 ether);
        assertEq(uint8(vault.getVault(vaultId).status), uint8(MilestoneVault.VaultStatus.Completed));
    }

    function test_ParallelVault_SequentialFlagStoredCorrectly() public {
        vm.prank(funder);
        uint256 seqId = vault.createETHVault{value: 1 ether}(recipient, validator, true, DISPUTE_WINDOW);
        vm.prank(funder);
        uint256 parId = vault.createETHVault{value: 1 ether}(recipient, validator, false, DISPUTE_WINDOW);

        assertTrue(vault.getVault(seqId).sequential);
        assertFalse(vault.getVault(parId).sequential);
    }

    /*//////////////////////////////////////////////////////////////
                       DISPUTE RESOLUTION
    //////////////////////////////////////////////////////////////*/

    function _setupSubmittedMilestone() internal returns (uint256 vaultId) {
        (vaultId,) = _setupVaultWithMilestone(5 ether);
        vm.prank(recipient);
        vault.submitMilestone(vaultId, 0);
    }

    function test_Escalate_RevertsBeforeWindowExpires() public {
        uint256 vaultId = _setupSubmittedMilestone();

        // Just before the window ends — should revert
        vm.warp(block.timestamp + DISPUTE_WINDOW - 1);
        vm.prank(recipient);
        vm.expectRevert(
            abi.encodeWithSelector(MilestoneVault.DisputeWindowNotExpired.selector, vaultId, 0)
        );
        vault.escalate(vaultId, 0);
    }

    function test_Escalate_TransitionsToDisputedAfterWindow() public {
        uint256 vaultId = _setupSubmittedMilestone();

        vm.warp(block.timestamp + DISPUTE_WINDOW + 1);
        vm.prank(recipient);
        vault.escalate(vaultId, 0);

        assertEq(
            uint8(vault.getMilestone(vaultId, 0).status),
            uint8(MilestoneVault.MilestoneStatus.Disputed)
        );
    }

    function test_Escalate_EmitsEvent() public {
        uint256 vaultId = _setupSubmittedMilestone();

        vm.warp(block.timestamp + DISPUTE_WINDOW + 1);
        vm.expectEmit(true, true, false, false);
        emit MilestoneVault.MilestoneEscalated(vaultId, 0);

        vm.prank(recipient);
        vault.escalate(vaultId, 0);
    }

    function test_Escalate_RevertsIfNotRecipient() public {
        uint256 vaultId = _setupSubmittedMilestone();

        vm.warp(block.timestamp + DISPUTE_WINDOW + 1);
        vm.prank(attacker);
        vm.expectRevert(MilestoneVault.Unauthorized.selector);
        vault.escalate(vaultId, 0);
    }

    function test_Escalate_RevertsIfMilestoneNotSubmitted() public {
        (uint256 vaultId,) = _setupVaultWithMilestone(5 ether);
        // Milestone is still Pending, not Submitted
        vm.warp(block.timestamp + DISPUTE_WINDOW + 1);
        vm.prank(recipient);
        vm.expectRevert(
            abi.encodeWithSelector(MilestoneVault.MilestoneNotSubmitted.selector, vaultId, 0)
        );
        vault.escalate(vaultId, 0);
    }

    function test_ResolveDispute_ArbitratorApproves() public {
        uint256 vaultId = _setupSubmittedMilestone();

        vm.warp(block.timestamp + DISPUTE_WINDOW + 1);
        vm.prank(recipient);
        vault.escalate(vaultId, 0);

        uint256 recipientBefore = recipient.balance;
        vm.prank(arbitrator);
        vault.resolveDispute(vaultId, 0, true);

        assertEq(recipient.balance - recipientBefore, 5 ether);
        assertEq(
            uint8(vault.getMilestone(vaultId, 0).status),
            uint8(MilestoneVault.MilestoneStatus.Approved)
        );
        assertEq(uint8(vault.getVault(vaultId).status), uint8(MilestoneVault.VaultStatus.Completed));
    }

    function test_ResolveDispute_ArbitratorRejects() public {
        uint256 vaultId = _setupSubmittedMilestone();

        vm.warp(block.timestamp + DISPUTE_WINDOW + 1);
        vm.prank(recipient);
        vault.escalate(vaultId, 0);

        vm.prank(arbitrator);
        vault.resolveDispute(vaultId, 0, false);

        assertEq(
            uint8(vault.getMilestone(vaultId, 0).status),
            uint8(MilestoneVault.MilestoneStatus.Pending)
        );
    }

    function test_ResolveDispute_EmitsEvent() public {
        uint256 vaultId = _setupSubmittedMilestone();

        vm.warp(block.timestamp + DISPUTE_WINDOW + 1);
        vm.prank(recipient);
        vault.escalate(vaultId, 0);

        vm.expectEmit(true, true, false, true);
        emit MilestoneVault.DisputeResolved(vaultId, 0, true);

        vm.prank(arbitrator);
        vault.resolveDispute(vaultId, 0, true);
    }

    function test_ResolveDispute_RevertsIfNotArbitrator() public {
        uint256 vaultId = _setupSubmittedMilestone();

        vm.warp(block.timestamp + DISPUTE_WINDOW + 1);
        vm.prank(recipient);
        vault.escalate(vaultId, 0);

        vm.prank(attacker);
        vm.expectRevert(MilestoneVault.Unauthorized.selector);
        vault.resolveDispute(vaultId, 0, true);
    }

    function test_ResolveDispute_RevertsIfMilestoneNotDisputed() public {
        uint256 vaultId = _setupSubmittedMilestone();
        // Milestone is Submitted, not Disputed
        vm.prank(arbitrator);
        vm.expectRevert(
            abi.encodeWithSelector(MilestoneVault.MilestoneNotDisputed.selector, vaultId, 0)
        );
        vault.resolveDispute(vaultId, 0, true);
    }

    function test_CancelVault_RevertsIfMilestoneDisputed() public {
        uint256 vaultId = _setupSubmittedMilestone();

        vm.warp(block.timestamp + DISPUTE_WINDOW + 1);
        vm.prank(recipient);
        vault.escalate(vaultId, 0);

        vm.prank(funder);
        vm.expectRevert();
        vault.cancelVault(vaultId);
    }
}
