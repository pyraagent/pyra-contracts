// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {PyraVault} from "../src/PyraVault.sol";
import {PyraVaultFactory} from "../src/PyraVaultFactory.sol";
import {PyraEscrow} from "../src/PyraEscrow.sol";
import {PyraPrizePool} from "../src/PyraPrizePool.sol";
import {ISwapAdapter} from "../src/interfaces/IPyra.sol";

/// Test-only six-decimal token. Never deployed by the deploy script.
contract TestUSD is ERC20Permit {
    constructor() ERC20("Test USD", "TUSD") ERC20Permit("Test USD") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 a) external {
        _mint(to, a);
    }
}

/// Adapter that takes input and returns less than it promised.
contract ShortAdapter is ISwapAdapter {
    function swapExactIn(address tokenIn, address, uint256 amountIn, uint256, uint16)
        external
        payable
        returns (uint256)
    {
        ERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        (bool ok,) = msg.sender.call{value: 1}("");
        require(ok);
        return type(uint256).max;
    }

    receive() external payable {}
}

/// Adapter that tries to re-enter the vault during a swap.
contract ReentrantAdapter is ISwapAdapter {
    function swapExactIn(address, address, uint256, uint256, uint16) external payable returns (uint256) {
        PyraVault(payable(msg.sender)).pay(address(this), 1, keccak256("again"));
        return 0;
    }
}

contract Base is Test {
    TestUSD usd;
    PyraVaultFactory factory;
    PyraEscrow escrow;
    PyraPrizePool prizes;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address dave = makeAddr("dave");
    address operator = makeAddr("operator");
    address payee = makeAddr("payee");
    address mallory = makeAddr("mallory");
    address admin = makeAddr("admin");
    address coord = makeAddr("coordinator");
    address verifier = makeAddr("verifier");
    address arbiter = makeAddr("arbiter");

    function setUp() public virtual {
        vm.warp(1_800_000_000);
        usd = new TestUSD();
        factory = new PyraVaultFactory(address(usd));
        escrow = new PyraEscrow(address(usd), address(factory), admin, coord, verifier, arbiter);
        prizes = new PyraPrizePool(address(usd), address(factory), admin, coord, arbiter);
        address[4] memory who = [alice, bob, carol, dave];
        for (uint256 i; i < 4; ++i) {
            usd.mint(who[i], 10_000e6);
        }
    }

    function perm() internal view returns (PyraVault.Permission memory) {
        return PyraVault.Permission(operator, uint64(block.timestamp + 7 days), 100, 4e6, 6e6, 10e6);
    }

    function cfg() internal view returns (PyraVault.Config memory c) {
        c.permission = perm();
        c.payees = new address[](1);
        c.payees[0] = payee;
        c.escrows = new address[](1);
        c.escrows[0] = address(escrow);
        c.adapters = new address[](0);
        c.tokens = new address[](1);
        c.tokens[0] = address(0);
    }

    function mk(address owner, string memory id) internal returns (PyraVault v) {
        vm.prank(owner);
        v = PyraVault(payable(factory.createVault(keccak256(bytes(id)), cfg())));
    }

    function fundVault(PyraVault v, uint256 a) internal {
        address o = v.owner();
        vm.startPrank(o);
        usd.approve(address(v), a);
        v.deposit(a);
        vm.stopPrank();
    }
}

contract VaultTest is Base {
    PyraVault v;

    function setUp() public override {
        super.setUp();
        v = mk(alice, "OWA");
        fundVault(v, 10e6);
    }

    function test_fundingFloorAndCap() public {
        PyraVault w = mk(bob, "x");
        vm.startPrank(bob);
        usd.approve(address(w), type(uint256).max);
        vm.expectRevert(PyraVault.FundingFloor.selector);
        w.deposit(4_999_999);
        w.deposit(5e6);
        vm.expectRevert(PyraVault.FundingCap.selector);
        w.deposit(995e6 + 1);
        w.deposit(995e6);
        assertEq(w.fundedPrincipal(), 1000e6);
        vm.stopPrank();
    }

    function test_onlyOwnerCanDeposit() public {
        vm.startPrank(mallory);
        vm.expectRevert(PyraVault.NotOwner.selector);
        v.deposit(5e6);
    }

    function test_payWithinLimits() public {
        vm.prank(operator);
        v.pay(payee, 4e6, "r1");
        assertEq(usd.balanceOf(payee), 4e6);
        assertEq(v.remainingToday(), 2e6);
    }

    function test_payReplayRefReverts() public {
        vm.startPrank(operator);
        v.pay(payee, 1e6, "r1");
        vm.expectRevert(PyraVault.RefUsed.selector);
        v.pay(payee, 1e6, "r1");
        vm.expectRevert(PyraVault.RefUsed.selector);
        v.pay(payee, 1e6, bytes32(0));
    }

    function test_limits() public {
        vm.startPrank(operator);
        vm.expectRevert(PyraVault.OverPerTxLimit.selector);
        v.pay(payee, 4e6 + 1, "a");
        v.pay(payee, 4e6, "b");
        vm.expectRevert(PyraVault.OverDailyLimit.selector);
        v.pay(payee, 2e6 + 1, "c");
        v.pay(payee, 2e6, "d");
        vm.warp(block.timestamp + 1 days);
        v.pay(payee, 4e6, "e");
        vm.expectRevert(PyraVault.OverTotalLimit.selector);
        v.pay(payee, 1, "f");
    }

    function test_revokeStopsOperatorImmediately() public {
        vm.prank(alice);
        v.revokePermission();
        vm.prank(operator);
        vm.expectRevert(PyraVault.NotOperator.selector);
        v.pay(payee, 1e6, "a");
    }

    function test_expiry() public {
        vm.warp(block.timestamp + 7 days);
        vm.prank(operator);
        vm.expectRevert(PyraVault.PermissionExpired.selector);
        v.pay(payee, 1e6, "a");
        assertEq(v.remainingToday(), 0);
    }

    function test_unlistedPayee() public {
        vm.prank(operator);
        vm.expectRevert(PyraVault.NotAllowlisted.selector);
        v.pay(mallory, 1e6, "a");
    }

    function test_operatorCannotWithdrawOrConfigure() public {
        vm.startPrank(operator);
        vm.expectRevert(PyraVault.NotOwner.selector);
        v.withdraw(address(usd), 1e6, operator);
        address[] memory a = new address[](1);
        a[0] = operator;
        vm.expectRevert(PyraVault.NotOwner.selector);
        v.setPayees(a, true);
        vm.expectRevert(PyraVault.NotOwner.selector);
        v.grantPermission(perm());
        vm.expectRevert(PyraVault.NotOwner.selector);
        v.retire();
    }

    function test_ownerWithdrawsWhileOperatorLive() public {
        vm.prank(alice);
        v.withdraw(address(usd), 10e6, bob);
        assertEq(usd.balanceOf(bob), 10_010e6);
        assertEq(v.fundedPrincipal(), 0);
    }

    function test_ownerWithdrawsNative() public {
        vm.deal(address(v), 1 ether);
        vm.prank(alice);
        v.withdraw(address(0), 1 ether, alice);
        assertEq(alice.balance, 1 ether);
    }

    function test_badPermissionsRejected() public {
        PyraVault.Permission memory p = perm();
        vm.startPrank(alice);
        p.expiresAt = uint64(block.timestamp + 91 days);
        vm.expectRevert(PyraVault.BadPermission.selector);
        v.grantPermission(p);
        p = perm();
        p.maxImpactBps = 501;
        vm.expectRevert(PyraVault.BadPermission.selector);
        v.grantPermission(p);
        p = perm();
        p.perTxLimit = 7e6;
        vm.expectRevert(PyraVault.BadPermission.selector);
        v.grantPermission(p);
    }

    function test_regrantDoesNotResetDailySpend() public {
        vm.prank(operator);
        v.pay(payee, 4e6, "a");
        vm.prank(alice);
        v.grantPermission(perm());
        vm.prank(operator);
        vm.expectRevert(PyraVault.OverDailyLimit.selector);
        v.pay(payee, 3e6, "b");
    }

    function test_initializeLocked() public {
        PyraVault.Config memory c = cfg();
        vm.expectRevert(PyraVault.AlreadyInitialized.selector);
        v.initialize(mallory, address(usd), "x", c);
        PyraVault impl = PyraVault(payable(factory.implementation()));
        vm.expectRevert(PyraVault.AlreadyInitialized.selector);
        impl.initialize(mallory, address(usd), "x", c);
    }

    function test_maxFiveActiveThenRetireFreesSlot() public {
        for (uint256 i = 1; i < 5; ++i) {
            mk(alice, string(abi.encodePacked("a", i)));
        }
        PyraVault.Config memory c = cfg();
        vm.startPrank(alice);
        vm.expectRevert(PyraVaultFactory.TooManyAgents.selector);
        factory.createVault("sixth", c);
        v.retire();
        vm.expectRevert(PyraVault.VaultRetired.selector);
        v.retire();
        factory.createVault("sixth", c);
        usd.approve(address(v), 5e6);
        vm.expectRevert(PyraVault.VaultRetired.selector);
        v.deposit(5e6);
        v.withdraw(address(usd), 10e6, alice);
    }

    function test_onRetiredOnlyVault() public {
        vm.prank(mallory);
        vm.expectRevert(PyraVaultFactory.NotVault.selector);
        factory.onRetired(alice);
    }

    function test_swapUnlistedAdapter() public {
        vm.prank(operator);
        vm.expectRevert(PyraVault.NotAllowlisted.selector);
        v.swap(address(0xdead), address(usd), address(0), 1e6, 1, "s");
    }

    function test_swapLyingAdapterCaughtByBalanceDelta() public {
        ShortAdapter s = new ShortAdapter();
        vm.deal(address(s), 1 ether);
        address[] memory a = new address[](1);
        a[0] = address(s);
        vm.prank(alice);
        v.setAdapters(a, true);
        vm.prank(operator);
        vm.expectRevert(PyraVault.InsufficientOutput.selector);
        v.swap(address(s), address(usd), address(0), 1e6, 2, "s");
    }

    function test_swapReentrancyBlocked() public {
        ReentrantAdapter r = new ReentrantAdapter();
        address[] memory a = new address[](1);
        a[0] = address(r);
        vm.prank(alice);
        v.setAdapters(a, true);
        vm.prank(operator);
        vm.expectRevert();
        v.swap(address(r), address(usd), address(0), 1e6, 1, "s");
    }

    function test_depositWithPermit() public {
        (address signer, uint256 pk) = makeAddrAndKey("signer");
        usd.mint(signer, 10e6);
        PyraVault w = mk(signer, "p");
        uint256 dl = block.timestamp + 1 hours;
        bytes32 h = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                signer,
                address(w),
                uint256(10e6),
                uint256(0),
                dl
            )
        );
        (uint8 vv, bytes32 r, bytes32 s) = vm.sign(pk, keccak256(abi.encodePacked("\x19\x01", usd.DOMAIN_SEPARATOR(), h)));
        vm.prank(signer);
        w.depositWithPermit(10e6, dl, vv, r, s);
        assertEq(w.fundedPrincipal(), 10e6);
    }

    /// No sequence of payments can exceed the daily or lifetime budget.
    function testFuzz_spendNeverExceedsBudget(uint96[12] memory amts, uint32[12] memory gaps) public {
        uint256 total;
        uint256 dayTotal;
        uint256 day = block.timestamp / 1 days;
        for (uint256 i; i < 12; ++i) {
            vm.warp(block.timestamp + gaps[i] % 12 hours);
            if (block.timestamp / 1 days != day) {
                day = block.timestamp / 1 days;
                dayTotal = 0;
            }
            uint128 a = uint128(bound(amts[i], 1, 5e6));
            vm.prank(operator);
            try v.pay(payee, a, keccak256(abi.encode(i))) {
                total += a;
                dayTotal += a;
            } catch {}
            assertLe(dayTotal, 6e6);
            assertLe(total, 10e6);
        }
        assertEq(usd.balanceOf(payee), total);
    }
}

contract EscrowTest is Base {
    PyraVault worker;
    bytes32 id;

    function setUp() public override {
        super.setUp();
        worker = mk(alice, "OWA");
        id = post(bob, "k1", 8e6);
    }

    function post(address c, bytes32 k, uint128 a) internal returns (bytes32) {
        vm.startPrank(c);
        usd.approve(address(escrow), a);
        bytes32 j = escrow.createJob(k, a, uint64(block.timestamp + 3 days), 1 days, keccak256("spec"));
        vm.stopPrank();
        return j;
    }

    function toVerified() internal {
        vm.prank(coord);
        escrow.assign(id, address(worker));
        vm.prank(coord);
        escrow.submit(id, keccak256("evidence"));
        vm.prank(verifier);
        escrow.attest(id, true, keccak256("report"));
    }

    function st() internal view returns (PyraEscrow.Status s) {
        (,,,,,, s,,,) = escrow.jobs(id);
    }

    function test_happyPathAutoRelease() public {
        toVerified();
        vm.prank(mallory);
        vm.expectRevert(PyraEscrow.Unauthorized.selector);
        escrow.release(id);
        vm.warp(block.timestamp + 1 days);
        vm.prank(mallory);
        escrow.release(id);
        assertEq(usd.balanceOf(address(worker)), 8e6);
        vm.expectRevert(PyraEscrow.BadState.selector);
        escrow.release(id);
    }

    function test_noDoubleSettlementAcrossPaths() public {
        toVerified();
        vm.prank(bob);
        escrow.release(id);
        vm.warp(block.timestamp + 60 days);
        vm.expectRevert(PyraEscrow.BadState.selector);
        escrow.refundExpired(id);
        vm.prank(bob);
        vm.expectRevert(PyraEscrow.BadState.selector);
        escrow.dispute(id);
        assertEq(usd.balanceOf(address(escrow)), 0);
    }

    function test_sameKeyCannotBeReused() public {
        vm.startPrank(bob);
        usd.approve(address(escrow), 8e6);
        vm.expectRevert(PyraEscrow.JobExists.selector);
        escrow.createJob("k1", 8e6, uint64(block.timestamp + 3 days), 1 days, keccak256("spec"));
    }

    function test_selfDealingBlocked() public {
        bytes32 j = post(alice, "mine", 5e6);
        vm.prank(coord);
        vm.expectRevert(PyraEscrow.SelfDealing.selector);
        escrow.assign(j, address(worker));
    }

    function test_selfDealingThroughSecondVaultBlocked() public {
        PyraVault client = mk(alice, "client");
        fundVault(client, 10e6);
        vm.prank(operator);
        bytes32 j =
            client.fundJob(address(escrow), "k", 3e6, uint64(block.timestamp + 1 days), 1 hours, keccak256("s"), "ref");
        vm.prank(coord);
        vm.expectRevert(PyraEscrow.SelfDealing.selector);
        escrow.assign(j, address(worker));
    }

    function test_agentHiresAgent() public {
        PyraVault client = mk(bob, "client");
        fundVault(client, 10e6);
        vm.prank(operator);
        bytes32 j =
            client.fundJob(address(escrow), "k", 3e6, uint64(block.timestamp + 1 days), 1 hours, keccak256("s"), "ref");
        vm.startPrank(coord);
        escrow.assign(j, address(worker));
        escrow.submit(j, keccak256("e"));
        vm.stopPrank();
        vm.prank(verifier);
        escrow.attest(j, true, "r");
        vm.prank(operator);
        client.settleJob(address(escrow), j, 0);
        assertEq(usd.balanceOf(address(worker)), 3e6);
    }

    function test_vaultClientCancelRefundsVault() public {
        PyraVault client = mk(bob, "client");
        fundVault(client, 10e6);
        vm.prank(operator);
        bytes32 j =
            client.fundJob(address(escrow), "k", 3e6, uint64(block.timestamp + 1 days), 1 hours, keccak256("s"), "ref");
        vm.prank(mallory);
        vm.expectRevert(PyraVault.NotOperator.selector);
        client.settleJob(address(escrow), j, 2);
        vm.prank(bob);
        client.settleJob(address(escrow), j, 2);
        assertEq(usd.balanceOf(address(client)), 10e6);
    }

    function test_onlyVaultsCanWork() public {
        vm.prank(coord);
        vm.expectRevert(PyraEscrow.BadParams.selector);
        escrow.assign(id, mallory);
    }

    function test_failedAttestationReopens() public {
        vm.startPrank(coord);
        escrow.assign(id, address(worker));
        escrow.submit(id, keccak256("bad"));
        vm.stopPrank();
        vm.prank(verifier);
        escrow.attest(id, false, keccak256("why"));
        assertEq(uint8(st()), uint8(PyraEscrow.Status.Assigned));
        vm.prank(coord);
        escrow.submit(id, keccak256("good"));
    }

    function test_verifierOnlyAttests() public {
        vm.startPrank(coord);
        escrow.assign(id, address(worker));
        escrow.submit(id, "e");
        vm.expectRevert(PyraEscrow.Unauthorized.selector);
        escrow.attest(id, true, "r");
    }

    function test_unverifiedNeverAutoReleases() public {
        vm.startPrank(coord);
        escrow.assign(id, address(worker));
        escrow.submit(id, "e");
        vm.stopPrank();
        vm.warp(block.timestamp + 2 days);
        vm.expectRevert(PyraEscrow.Unauthorized.selector);
        escrow.release(id);
        vm.warp(block.timestamp + 2 days);
        escrow.refundExpired(id);
        assertEq(usd.balanceOf(bob), 10_000e6);
    }

    function test_disputeAndSplit() public {
        toVerified();
        vm.prank(bob);
        escrow.dispute(id);
        vm.warp(block.timestamp + 5 days);
        vm.expectRevert(PyraEscrow.BadState.selector);
        escrow.release(id);
        vm.prank(arbiter);
        escrow.resolve(id, 3e6);
        assertEq(usd.balanceOf(address(worker)), 3e6);
        assertEq(usd.balanceOf(bob), 10_000e6 - 3e6);
    }

    function test_abandonedDisputeRefunds() public {
        toVerified();
        vm.prank(bob);
        escrow.dispute(id);
        vm.expectRevert(PyraEscrow.BadState.selector);
        escrow.refundExpired(id);
        vm.warp(block.timestamp + 30 days);
        escrow.refundExpired(id);
        assertEq(usd.balanceOf(bob), 10_000e6);
    }

    function test_cancelOnlyWhileOpen() public {
        vm.prank(mallory);
        vm.expectRevert(PyraEscrow.Unauthorized.selector);
        escrow.cancel(id);
        vm.prank(coord);
        escrow.assign(id, address(worker));
        vm.prank(bob);
        vm.expectRevert(PyraEscrow.BadState.selector);
        escrow.cancel(id);
    }

    function test_adminCannotActOnJobs() public {
        vm.startPrank(admin);
        vm.expectRevert(PyraEscrow.Unauthorized.selector);
        escrow.assign(id, address(worker));
        vm.expectRevert(PyraEscrow.Unauthorized.selector);
        escrow.resolve(id, 8e6);
        vm.expectRevert(PyraEscrow.BadState.selector);
        escrow.release(id);
        vm.expectRevert(PyraEscrow.Unauthorized.selector);
        escrow.cancel(id);
    }

    /// The admin swaps in keys it controls and tries to take money that was already in escrow.
    function test_roleChangeCannotReachFundedJobs() public {
        address c2 = makeAddr("c2");
        address v2 = makeAddr("v2");
        address a2 = makeAddr("a2");
        vm.prank(admin);
        escrow.proposeRoles(c2, v2, a2);
        vm.expectRevert(PyraEscrow.BadState.selector);
        escrow.applyRoles();
        vm.warp(block.timestamp + 2 days);
        escrow.applyRoles();

        PyraVault theirs = mk(mallory, "theirs");
        vm.prank(c2);
        vm.expectRevert(PyraEscrow.Unauthorized.selector);
        escrow.assign(id, address(theirs));
        vm.startPrank(coord);
        escrow.assign(id, address(worker));
        escrow.submit(id, keccak256("e"));
        vm.stopPrank();
        vm.prank(v2);
        vm.expectRevert(PyraEscrow.Unauthorized.selector);
        escrow.attest(id, true, "r");
        vm.prank(verifier);
        escrow.attest(id, true, "r");
        vm.prank(bob);
        escrow.dispute(id);
        vm.prank(a2);
        vm.expectRevert(PyraEscrow.Unauthorized.selector);
        escrow.resolve(id, 8e6);
        vm.prank(arbiter);
        escrow.resolve(id, 0);
        assertEq(usd.balanceOf(bob), 10_000e6);

        bytes32 later = post(bob, "later", 1e6);
        (address c,,) = escrow.jobRoles(later);
        assertEq(c, c2);
    }

    function test_rolesMustBeDistinctAndNotAdmin() public {
        vm.startPrank(admin);
        vm.expectRevert(PyraEscrow.BadParams.selector);
        escrow.proposeRoles(admin, verifier, arbiter);
        vm.expectRevert(PyraEscrow.BadParams.selector);
        escrow.proposeRoles(coord, coord, arbiter);
        vm.expectRevert(PyraEscrow.BadParams.selector);
        escrow.proposeRoles(coord, verifier, address(0));
        vm.stopPrank();
        vm.prank(mallory);
        vm.expectRevert();
        escrow.proposeRoles(address(11), address(12), address(13));
    }

    /// The arbiter can only split between the two parties, whatever number it picks.
    function testFuzz_arbiterPaysOnlyTheTwoParties(uint128 cut) public {
        toVerified();
        vm.prank(bob);
        escrow.dispute(id);
        uint128 amount = uint128(bound(cut, 0, 8e6));
        vm.prank(arbiter);
        escrow.resolve(id, amount);
        assertEq(usd.balanceOf(address(worker)) + usd.balanceOf(bob), 10_000e6);
        assertEq(usd.balanceOf(arbiter), 0);
        assertEq(usd.balanceOf(address(escrow)), 0);
    }
}

contract PrizeTest is Base {
    PyraVault a;
    PyraVault b;
    PyraVault c;
    uint256 id;

    function setUp() public virtual override {
        super.setUp();
        a = mk(alice, "a");
        b = mk(bob, "b");
        c = mk(carol, "c");
        vm.prank(coord);
        id = prizes.createEpoch(uint64(block.timestamp), uint64(block.timestamp + 7 days), keccak256("rules"));
        vm.startPrank(dave);
        usd.approve(address(prizes), 100e6 + 1);
        prizes.fund(id, 100e6 + 1);
        vm.stopPrank();
    }

    function w() internal view returns (address[3] memory) {
        return [address(a), address(b), address(c)];
    }

    function _propose(address[3] memory x) internal {
        vm.warp(block.timestamp + 7 days);
        vm.prank(coord);
        prizes.propose(id, x, keccak256("scores"));
    }

    function test_split() public {
        _propose(w());
        vm.expectRevert(PyraPrizePool.BadState.selector);
        prizes.finalize(id);
        vm.warp(block.timestamp + 2 days);
        prizes.finalize(id);
        for (uint8 i; i < 3; ++i) {
            prizes.claim(id, i);
        }
        assertEq(usd.balanceOf(address(a)), 50e6 + 1);
        assertEq(usd.balanceOf(address(b)), 30e6);
        assertEq(usd.balanceOf(address(c)), 20e6);
        vm.expectRevert(PyraPrizePool.BadState.selector);
        prizes.claim(id, 0);
    }

    function testFuzz_splitSumsToPool(uint96 extra) public {
        uint128 x = uint128(bound(extra, 1, 5_000e6));
        vm.startPrank(dave);
        usd.approve(address(prizes), x);
        prizes.fund(id, x);
        vm.stopPrank();
        _propose(w());
        vm.warp(block.timestamp + 2 days);
        prizes.finalize(id);
        for (uint8 i; i < 3; ++i) {
            prizes.claim(id, i);
        }
        assertEq(usd.balanceOf(address(prizes)), 0);
    }

    function test_onePrizePerOwner() public {
        PyraVault a2 = mk(alice, "a2");
        vm.warp(block.timestamp + 7 days);
        vm.prank(coord);
        vm.expectRevert(PyraPrizePool.BadParams.selector);
        prizes.propose(id, [address(a), address(a2), address(c)], "s");
    }

    function test_missingThirdRollsOver() public {
        _propose([address(a), address(b), address(0)]);
        vm.warp(block.timestamp + 2 days);
        prizes.finalize(id);
        assertEq(prizes.rollover(), 20e6);
        vm.prank(coord);
        uint256 n = prizes.createEpoch(uint64(block.timestamp), uint64(block.timestamp + 1 days), "r");
        assertEq(prizes.epoch(n).pool, 20e6);
        assertEq(prizes.rollover(), 0);
    }

    function test_flagExtendsOnceAndArbiterRejects() public {
        _propose(w());
        vm.warp(block.timestamp + 1 days);
        vm.prank(mallory);
        vm.expectRevert(PyraPrizePool.Unauthorized.selector);
        prizes.flag(id, address(a), "x");
        vm.startPrank(alice);
        prizes.flag(id, address(a), "x");
        vm.expectRevert(PyraPrizePool.BadState.selector);
        prizes.flag(id, address(a), "y");
        vm.stopPrank();
        vm.warp(block.timestamp + 1 days + 1);
        vm.expectRevert(PyraPrizePool.BadState.selector);
        prizes.finalize(id);
        vm.prank(arbiter);
        prizes.reject(id, "bad");
        vm.prank(coord);
        prizes.propose(id, w(), "s2");
    }

    function test_roleChangeCannotRedirectFundedPrizes() public {
        address s2 = makeAddr("s2");
        address a2 = makeAddr("a2");
        vm.prank(admin);
        prizes.proposeRoles(s2, a2);
        vm.warp(block.timestamp + 7 days);
        prizes.applyRoles();
        PyraVault theirs = mk(mallory, "theirs");
        vm.prank(s2);
        vm.expectRevert(PyraPrizePool.Unauthorized.selector);
        prizes.propose(id, [address(theirs), address(0), address(0)], "s");
        vm.prank(coord);
        prizes.propose(id, w(), "s");
        vm.prank(a2);
        vm.expectRevert(PyraPrizePool.Unauthorized.selector);
        prizes.reject(id, "r");
        vm.prank(arbiter);
        prizes.reject(id, "r");
        vm.prank(admin);
        vm.expectRevert(PyraPrizePool.BadParams.selector);
        prizes.proposeRoles(admin, arbiter);
    }

    function test_cannotProposeEarlyOrAsOutsider() public {
        vm.prank(coord);
        vm.expectRevert(PyraPrizePool.BadState.selector);
        prizes.propose(id, w(), "s");
        vm.warp(block.timestamp + 7 days);
        vm.prank(mallory);
        vm.expectRevert(PyraPrizePool.Unauthorized.selector);
        prizes.propose(id, w(), "s");
    }

    function test_staleEpochReclaim() public {
        vm.warp(block.timestamp + 7 days + 30 days);
        prizes.cancelStale(id);
        vm.prank(dave);
        prizes.reclaim(id);
        assertEq(usd.balanceOf(dave), 10_000e6);
        vm.prank(dave);
        vm.expectRevert(PyraPrizePool.BadState.selector);
        prizes.reclaim(id);
    }
}
