// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {UniversalRWAToken} from "../src/UniversalRWAToken.sol";

interface Vm {
    function prank(address caller) external;
    function expectRevert(bytes calldata revertData) external;
    function expectEmit(bool checkTopic1, bool checkTopic2, bool checkTopic3, bool checkData, address emitter) external;
}

contract UniversalRWATokenTest {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Frozen(address indexed account, uint256 amount);
    event ForcedTransfer(address indexed from, address indexed to, uint256 amount);
    event TransferRejected(address indexed from, address indexed to, uint256 amount, uint8 reason);

    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);
    address private constant RECOVERY = address(0xCAFE);
    address private constant UNLISTED = address(0xDEAD);

    UniversalRWAToken private token;

    function setUp() public {
        token = new UniversalRWAToken("Campus Bond", "CBOND", 1_000 ether);
        token.setAllowlisted(ALICE, true);
        token.setAllowlisted(BOB, true);
        token.setAllowlisted(RECOVERY, true);
        token.mint(ALICE, 100 ether);
    }

    function test_InitialAdminIsAllowlistedAndReceivesSupply() public view {
        assertTrue(token.isAllowlisted(address(this)), "admin should be allowlisted");
        assertEq(token.balanceOf(address(this)), 1_000 ether, "initial supply should belong to admin");
    }

    function test_AllowlistedHolderCanTransfer() public {
        vm.prank(ALICE);
        bool success = token.transfer(BOB, 40 ether);

        assertTrue(success, "allowlisted transfer should succeed");
        assertEq(token.balanceOf(ALICE), 60 ether, "sender balance incorrect");
        assertEq(token.balanceOf(BOB), 40 ether, "recipient balance incorrect");
    }

    function test_CanTransferReportsComplianceWithoutReverting() public view {
        assertTrue(token.canSend(ALICE), "allowlisted account should be able to send");
        assertTrue(token.canReceive(BOB), "allowlisted account should be able to receive");
        assertTrue(token.canTransfer(ALICE, BOB, 100 ether), "unfrozen transfer should be allowed");
        assertFalse(token.canTransfer(ALICE, UNLISTED, 1 ether), "unlisted recipient should be denied");
    }

    function test_UnallowlistedSenderTransferReturnsFalseAndEmitsRejection() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit TransferRejected(UNLISTED, BOB, 1 ether, 0);

        vm.prank(UNLISTED);
        bool success = token.transfer(BOB, 1 ether);

        assertFalse(success, "unallowlisted sender must not transfer");
        assertEq(token.balanceOf(BOB), 0, "rejected transfer must not move tokens");
    }

    function test_UnallowlistedRecipientTransferReturnsFalseAndEmitsRejection() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit TransferRejected(ALICE, UNLISTED, 1 ether, 1);

        vm.prank(ALICE);
        bool success = token.transfer(UNLISTED, 1 ether);

        assertFalse(success, "unallowlisted recipient must not receive");
        assertEq(token.balanceOf(ALICE), 100 ether, "rejected transfer must not debit sender");
    }

    function test_FreezeBlocksAllTransfersAndUnfreezeRestoresThem() public {
        vm.expectEmit(true, false, false, true, address(token));
        emit Frozen(ALICE, type(uint256).max);
        token.freeze(ALICE);

        vm.prank(ALICE);
        bool blocked = token.transfer(BOB, 1 ether);
        assertFalse(blocked, "fully frozen holder must not transfer");

        vm.expectEmit(true, false, false, true, address(token));
        emit Frozen(ALICE, 0);
        token.unfreeze(ALICE);

        vm.prank(ALICE);
        bool success = token.transfer(BOB, 1 ether);
        assertTrue(success, "unfrozen holder should transfer");
    }

    function test_PartialFreezeAllowsOnlyUnfrozenBalance() public {
        token.setFrozenTokens(ALICE, 70 ether);

        assertEq(token.getFrozenTokens(ALICE), 70 ether, "frozen amount incorrect");
        assertTrue(token.canTransfer(ALICE, BOB, 30 ether), "unfrozen amount should transfer");
        assertFalse(token.canTransfer(ALICE, BOB, 31 ether), "frozen amount must be unavailable");

        vm.expectEmit(true, true, false, true, address(token));
        emit TransferRejected(ALICE, BOB, 31 ether, 2);
        vm.prank(ALICE);
        bool blocked = token.transfer(BOB, 31 ether);
        assertFalse(blocked, "transfer exceeding unfrozen balance must fail");

        vm.prank(ALICE);
        bool success = token.transfer(BOB, 30 ether);
        assertTrue(success, "exact unfrozen balance should transfer");
    }

    function test_FrozenAmountMayExceedBalanceAndWithholdsFutureBalance() public {
        token.setFrozenTokens(ALICE, 1_000 ether);
        assertEq(token.getFrozenTokens(ALICE), 1_000 ether, "standard permits excess frozen amount");

        vm.prank(ALICE);
        bool blocked = token.transfer(BOB, 1 ether);
        assertFalse(blocked, "excess frozen amount should block transfer");
    }

    function test_NonAdminCannotChangeAllowlistOrFreeze() public {
        vm.expectRevert(abi.encodeWithSelector(UniversalRWAToken.NotAdmin.selector, ALICE));
        vm.prank(ALICE);
        token.setAllowlisted(UNLISTED, true);

        vm.expectRevert(abi.encodeWithSelector(UniversalRWAToken.NotAdmin.selector, ALICE));
        vm.prank(ALICE);
        token.freeze(BOB);
    }

    function test_AdminFunctionsRejectZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(UniversalRWAToken.ZeroAddress.selector));
        token.setAllowlisted(address(0), true);

        vm.expectRevert(abi.encodeWithSelector(UniversalRWAToken.ZeroAddress.selector));
        token.freeze(address(0));

        vm.expectRevert(abi.encodeWithSelector(UniversalRWAToken.ZeroAddress.selector));
        token.forcedTransfer(address(0), RECOVERY, 1 ether);
    }

    function test_ForcedTransferMovesFrozenTokensToCompliantRecoveryAddress() public {
        token.freeze(ALICE);

        vm.expectEmit(true, false, false, true, address(token));
        emit Frozen(ALICE, 60 ether);
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(ALICE, RECOVERY, 40 ether);
        vm.expectEmit(true, true, false, true, address(token));
        emit ForcedTransfer(ALICE, RECOVERY, 40 ether);

        bool success = token.forcedTransfer(ALICE, RECOVERY, 40 ether);

        assertTrue(success, "admin recovery should succeed");
        assertEq(token.balanceOf(ALICE), 60 ether, "source balance incorrect");
        assertEq(token.balanceOf(RECOVERY), 40 ether, "recovery balance incorrect");
        assertEq(token.getFrozenTokens(ALICE), 60 ether, "remaining balance should remain frozen");
    }

    function test_NonAdminCannotForceTransfer() public {
        token.freeze(ALICE);

        vm.expectRevert(abi.encodeWithSelector(UniversalRWAToken.NotAdmin.selector, BOB));
        vm.prank(BOB);
        token.forcedTransfer(ALICE, RECOVERY, 1 ether);
    }

    function test_ForcedTransferRequiresFrozenSource() public {
        vm.expectRevert(abi.encodeWithSelector(UniversalRWAToken.SourceNotFrozen.selector, ALICE));
        token.forcedTransfer(ALICE, RECOVERY, 1 ether);
    }

    function test_ForcedTransferRequiresSufficientSourceBalance() public {
        token.freeze(ALICE);

        vm.expectRevert(
            abi.encodeWithSelector(UniversalRWAToken.InsufficientBalance.selector, ALICE, 100 ether, 101 ether)
        );
        token.forcedTransfer(ALICE, RECOVERY, 101 ether);
    }

    function test_ForcedTransferConsumesOnlyFrozenAmountWhenPartiallyFrozen() public {
        token.setFrozenTokens(ALICE, 20 ether);

        token.forcedTransfer(ALICE, RECOVERY, 40 ether);

        assertEq(token.getFrozenTokens(ALICE), 0, "forced transfer should unfreeze moved frozen amount");
        assertEq(token.balanceOf(ALICE), 60 ether, "source balance incorrect");
        assertEq(token.balanceOf(RECOVERY), 40 ether, "recovery balance incorrect");
    }

    function test_ForcedTransferRejectsUnallowlistedRecoveryAddress() public {
        token.freeze(ALICE);

        vm.expectRevert(abi.encodeWithSelector(IERC7943CannotReceiveSelector(), UNLISTED));
        token.forcedTransfer(ALICE, UNLISTED, 1 ether);
    }

    function test_TransferFromAlsoEnforcesCompliance() public {
        vm.prank(ALICE);
        token.approve(BOB, 10 ether);
        token.freeze(ALICE);

        vm.prank(BOB);
        bool blocked = token.transferFrom(ALICE, BOB, 10 ether);

        assertFalse(blocked, "delegated transfer must honor freeze");
        assertEq(token.allowance(ALICE, BOB), 10 ether, "rejected transfer must preserve allowance");
    }

    function test_TransferFromRevertsForInsufficientAllowanceAfterCompliancePasses() public {
        vm.prank(ALICE);
        token.approve(BOB, 9 ether);

        vm.expectRevert(
            abi.encodeWithSelector(UniversalRWAToken.InsufficientAllowance.selector, ALICE, BOB, 9 ether, 10 ether)
        );
        vm.prank(BOB);
        token.transferFrom(ALICE, BOB, 10 ether);
    }

    function test_TransferFromDoesNotDecreaseInfiniteAllowance() public {
        vm.prank(ALICE);
        token.approve(BOB, type(uint256).max);

        vm.prank(BOB);
        bool success = token.transferFrom(ALICE, BOB, 10 ether);

        assertTrue(success, "approved delegated transfer should succeed");
        assertEq(token.allowance(ALICE, BOB), type(uint256).max, "infinite allowance should remain unchanged");
    }

    function test_SupportsERC165AndERC7943FungibleInterfaces() public view {
        assertTrue(token.supportsInterface(0x01ffc9a7), "ERC-165 should be supported");
        assertTrue(token.supportsInterface(0x3edbb4c4), "ERC-7943 fungible should be supported");
        assertFalse(token.supportsInterface(0xffffffff), "unknown interface should not be supported");
    }

    function test_MintRequiresCompliantRecipient() public {
        vm.expectRevert(abi.encodeWithSelector(IERC7943CannotReceiveSelector(), UNLISTED));
        token.mint(UNLISTED, 1 ether);
    }

    function testFuzz_TransferExactlyUnfrozenAmount(uint96 rawBalance, uint96 rawFrozen) public {
        uint256 mintedAmount = uint256(rawBalance % 1_000_000) + 1;
        token.mint(ALICE, mintedAmount);
        uint256 aliceBalance = token.balanceOf(ALICE);
        uint256 frozen = uint256(rawFrozen) % (aliceBalance + 1);
        token.setFrozenTokens(ALICE, frozen);
        uint256 unfrozen = aliceBalance - frozen;

        vm.prank(ALICE);
        bool success = token.transfer(BOB, unfrozen);

        assertTrue(success, "exact unfrozen amount should always transfer");
    }

    function IERC7943CannotReceiveSelector() private pure returns (bytes4) {
        return bytes4(keccak256("ERC7943CannotReceive(address)"));
    }

    function assertTrue(bool condition, string memory message) private pure {
        if (!condition) revert(message);
    }

    function assertFalse(bool condition, string memory message) private pure {
        if (condition) revert(message);
    }

    function assertEq(uint256 actual, uint256 expected, string memory message) private pure {
        if (actual != expected) revert(message);
    }
}
