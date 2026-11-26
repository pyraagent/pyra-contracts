// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Base, TestUSD} from "./Pyra.t.sol";
import {PyraDailyRewards} from "../src/testnet/PyraDailyRewards.sol";
import {PyraPrizePool} from "../src/PyraPrizePool.sol";
import {PyraVault} from "../src/PyraVault.sol";
import {PyraVaultFactory} from "../src/PyraVaultFactory.sol";

/// USDG's issuer can freeze an address or stop everything. This token can do both.
contract FreezableUSD is TestUSD {
    mapping(address => bool) public frozen;
    bool public stopped;

    function freeze(address a, bool on) external {
        frozen[a] = on;
    }

    function stop(bool on) external {
        stopped = on;
    }

    function _update(address from, address to, uint256 v) internal override {
        require(!stopped && !frozen[to] && !frozen[from], "frozen");
        super._update(from, to, v);
    }
}

abstract contract DailyBase is Base {
    PyraDailyRewards daily;
    PyraVault a;
    PyraVault b;
    PyraVault c;
    uint256 d;

    function setUp() public virtual override {
        vm.chainId(46630);
        super.setUp();
        FreezableUSD f = new FreezableUSD();
        usd = TestUSD(address(f));
        factory = new PyraVaultFactory(address(usd));
        usd.mint(dave, 10_000e6);
        usd.mint(carol, 10_000e6);
        a = mk(alice, "a");
        b = mk(bob, "b");
        c = mk(carol, "c");
        daily = new PyraDailyRewards(address(usd), address(factory), admin, coord, arbiter, 1 hours);
        vm.warp(1_800_000_000 / 1 days * 1 days + 10 hours);
        d = daily.today();
        vm.prank(dave);
        usd.approve(address(daily), type(uint256).max);
        vm.prank(carol);
        usd.approve(address(daily), type(uint256).max);
        _fund(dave, d, 1, 1e6);
    }

    function _fund(address who, uint256 first, uint256 n, uint128 per) internal {
        vm.prank(who);
        daily.fund(first, n, per);
    }

    function w() internal view returns (address[3] memory) {
        return [address(a), address(b), address(c)];
    }

    function _end(uint256 x) internal pure returns (uint256) {
        return (x + 1) * 1 days;
    }

    function _post(uint256 x, address[3] memory win) internal {
        vm.prank(coord);
        daily.post(x, win, keccak256("record"));
    }

    function _postAtEnd(address[3] memory win) internal {
        vm.warp(_end(d));
        _post(d, win);
    }

    function _bad() internal {
        vm.expectRevert(PyraDailyRewards.BadState.selector);
    }

    function _params() internal {
        vm.expectRevert(PyraDailyRewards.BadParams.selector);
    }

    function _unauthorized() internal {
        vm.expectRevert(PyraDailyRewards.Unauthorized.selector);
    }

    function _frz() internal view returns (FreezableUSD) {
        return FreezableUSD(address(usd));
    }
}

contract DailyTest is DailyBase {
    function test_paysAllThreeInOneCallByAnyone() public {
        _postAtEnd(w());
        vm.warp(_end(d) + 1 hours);
        vm.prank(mallory);
        daily.pay(d);
        assertEq(usd.balanceOf(address(a)), 500_000);
        assertEq(usd.balanceOf(address(b)), 300_000);
        assertEq(usd.balanceOf(address(c)), 200_000);
        assertEq(usd.balanceOf(address(daily)), 0);
        assertEq(daily.day(d).settled, 7);
    }

    /// The edge of a day, to the second.
    function test_midnightToTheSecond() public {
        vm.warp(_end(d) - 1);
        assertEq(daily.today(), d);
        vm.prank(coord);
        _bad();
        daily.post(d, w(), keccak256("r"));
        _fund(dave, d, 1, 5); // the last second still takes money
        vm.warp(_end(d));
        assertEq(daily.today(), d + 1);
        vm.prank(dave);
        _params();
        daily.fund(d, 1, 5);
        _post(d, w());
        assertEq(daily.day(d).pool, 1e6 + 5);
    }

    function test_reviewToTheSecond() public {
        _postAtEnd(w());
        uint64 at = daily.day(d).payableAt;
        assertEq(at, _end(d) + 1 hours);
        vm.warp(at - 1);
        _bad();
        daily.pay(d);
        vm.warp(at);
        daily.pay(d);
    }

    function test_neverPaidTwice() public {
        _postAtEnd(w());
        vm.warp(_end(d) + 1 hours);
        daily.pay(d);
        _bad();
        daily.pay(d);
        for (uint8 r; r < 3; ++r) {
            _bad();
            daily.retry(d, r);
        }
        _bad();
        daily.retry(d, 3);
        vm.prank(coord);
        _bad();
        daily.post(d, w(), keccak256("again"));
        vm.prank(arbiter);
        _bad();
        daily.reject(d, keccak256("late"));
        vm.warp(_end(d) + 60 days);
        _bad();
        daily.voidDay(d);
        _bad();
        daily.refund(d, dave);
        assertEq(usd.balanceOf(address(a)), 500_000);
    }

    function test_onlyTheScorerPosts() public {
        vm.warp(_end(d));
        address[4] memory no = [admin, arbiter, mallory, alice];
        for (uint256 i; i < 4; ++i) {
            vm.prank(no[i]);
            _unauthorized();
            daily.post(d, w(), keccak256("r"));
        }
    }

    function test_postChecksWinners() public {
        vm.warp(_end(d));
        PyraVault a2 = mk(alice, "a2");
        address[3][4] memory x = [
            [address(0), address(b), address(0)],
            [mallory, address(0), address(0)],
            [address(a), address(a2), address(0)],
            [address(a), address(b), address(a2)]
        ];
        for (uint256 i; i < 4; ++i) {
            vm.prank(coord);
            _params();
            daily.post(d, x[i], keccak256("r"));
        }
        vm.prank(coord);
        _bad();
        daily.post(d, w(), bytes32(0));
        vm.prank(coord);
        _bad();
        daily.post(d - 1, w(), keccak256("not funded"));
    }

    function test_emptyDayGoesBackToTheSponsor() public {
        _postAtEnd([address(0), address(0), address(0)]);
        vm.warp(_end(d) + 1 hours);
        daily.pay(d);
        uint256 x = usd.balanceOf(dave);
        vm.prank(mallory); // whoever calls, the sponsor is paid
        daily.refund(d, dave);
        assertEq(usd.balanceOf(dave) - x, 1e6);
        assertEq(usd.balanceOf(address(daily)), 0);
        _bad();
        daily.refund(d, dave);
        _bad();
        daily.refund(d, mallory);
    }

    function test_oneWinnerLeavesTheRestToSponsorsInProportion() public {
        _fund(carol, d, 1, 3e6);
        _postAtEnd([address(a), address(0), address(0)]);
        vm.warp(_end(d) + 1 hours);
        daily.pay(d);
        assertEq(usd.balanceOf(address(a)), 2e6);
        uint256 x = usd.balanceOf(dave);
        uint256 y = usd.balanceOf(carol);
        daily.refund(d, dave);
        daily.refund(d, carol);
        assertEq(usd.balanceOf(dave) - x, 500_000);
        assertEq(usd.balanceOf(carol) - y, 1_500_000);
        assertEq(usd.balanceOf(address(daily)), 0);
    }

    function test_noResultInTimeIsVoid() public {
        vm.warp(_end(d) + 36 hours - 1);
        _bad();
        daily.voidDay(d);
        vm.warp(_end(d) + 36 hours);
        vm.prank(coord);
        _bad();
        daily.post(d, w(), keccak256("late"));
        vm.prank(mallory);
        daily.voidDay(d);
        _bad();
        daily.voidDay(d);
        daily.refund(d, dave);
        assertEq(usd.balanceOf(address(daily)), 0);
    }

    function test_flagHoldsOnceAndBoundedly() public {
        _postAtEnd(w());
        vm.prank(mallory);
        _unauthorized();
        daily.flag(d, address(a), keccak256("f"));
        vm.warp(_end(d) + 1 hours - 1);
        vm.prank(alice);
        daily.flag(d, address(a), keccak256("f"));
        assertEq(daily.day(d).payableAt, _end(d) + 13 hours - 1);
        vm.prank(bob);
        _bad();
        daily.flag(d, address(b), keccak256("f"));
        vm.warp(_end(d) + 13 hours - 2);
        _bad();
        daily.pay(d);
        vm.warp(_end(d) + 13 hours - 1);
        daily.pay(d); // the arbiter said nothing, so the result stands
    }

    /// Flagging and clearing at once must not cut short the time everyone else was promised.
    function test_clearKeepsTheReview() public {
        _postAtEnd(w());
        vm.warp(_end(d) + 1 minutes);
        vm.prank(alice);
        daily.flag(d, address(a), keccak256("f"));
        vm.prank(mallory);
        _unauthorized();
        daily.clearFlag(d);
        vm.prank(arbiter);
        daily.clearFlag(d);
        assertEq(daily.day(d).payableAt, _end(d) + 1 hours);
        _bad();
        daily.pay(d);
    }

    function test_clearAfterTheReviewPaysAtOnce() public {
        _postAtEnd(w());
        vm.prank(arbiter);
        _bad();
        daily.clearFlag(d);
        vm.prank(alice);
        daily.flag(d, address(a), keccak256("f"));
        vm.warp(_end(d) + 2 hours);
        vm.prank(arbiter);
        daily.clearFlag(d);
        daily.pay(d);
    }

    function test_rejectedOnceCanBeCorrected() public {
        _postAtEnd([address(b), address(a), address(c)]);
        vm.prank(coord);
        _unauthorized();
        daily.reject(d, keccak256("wrong order"));
        vm.prank(arbiter);
        daily.reject(d, keccak256("wrong order"));
        _bad();
        daily.pay(d);
        _post(d, w());
        assertEq(daily.day(d).rejections, 1);
        vm.warp(block.timestamp + 1 hours);
        daily.pay(d);
        assertEq(usd.balanceOf(address(a)), 500_000);
    }

    function test_rejectedTwiceIsVoid() public {
        _postAtEnd(w());
        vm.prank(arbiter);
        daily.reject(d, keccak256("1"));
        _post(d, w());
        vm.prank(arbiter);
        daily.reject(d, keccak256("2"));
        vm.prank(coord);
        _bad();
        daily.post(d, w(), keccak256("third"));
        daily.refund(d, dave);
        assertEq(usd.balanceOf(address(daily)), 0);
    }

    /// A payment that is late, because the server was down, can still be stopped.
    function test_rejectWorksUntilPaid() public {
        _postAtEnd(w());
        vm.warp(_end(d) + 20 hours);
        vm.prank(arbiter);
        daily.reject(d, keccak256("late but right"));
    }

    function test_frozenWinnerDoesNotHoldUpTheOthers() public {
        _frz().freeze(address(b), true);
        _postAtEnd(w());
        vm.warp(_end(d) + 1 hours);
        daily.pay(d);
        assertEq(usd.balanceOf(address(a)), 500_000);
        assertEq(usd.balanceOf(address(b)), 0);
        assertEq(usd.balanceOf(address(c)), 200_000);
        assertEq(daily.day(d).settled, 5);
        _bad();
        daily.retry(d, 1);
        _bad();
        daily.retry(d, 0);
        _frz().freeze(address(b), false);
        daily.retry(d, 1);
        assertEq(usd.balanceOf(address(b)), 300_000);
        _bad();
        daily.retry(d, 1);
        assertEq(usd.balanceOf(address(daily)), 0);
    }

    function test_frozenForAMonthGoesBackToTheSponsor() public {
        _frz().freeze(address(b), true);
        _postAtEnd(w());
        vm.warp(_end(d) + 1 hours);
        daily.pay(d);
        vm.warp(_end(d) + 1 hours + 30 days - 1);
        _bad();
        daily.retry(d, 1);
        vm.warp(_end(d) + 1 hours + 30 days);
        daily.retry(d, 1);
        assertEq(daily.day(d).settled, 7);
        daily.refund(d, dave);
        assertEq(usd.balanceOf(address(daily)), 0);
        _frz().freeze(address(b), false);
        _bad();
        daily.retry(d, 1);
    }

    function test_lateButThawedIsPaidNotReturned() public {
        _frz().freeze(address(b), true);
        _postAtEnd(w());
        vm.warp(_end(d) + 1 hours);
        daily.pay(d);
        _frz().freeze(address(b), false);
        vm.warp(_end(d) + 90 days);
        daily.retry(d, 1);
        assertEq(usd.balanceOf(address(b)), 300_000);
    }

    function test_tokenStoppedEntirelyThenRecovered() public {
        _postAtEnd(w());
        vm.warp(_end(d) + 1 hours);
        _frz().stop(true);
        daily.pay(d);
        assertEq(daily.day(d).settled, 0);
        _frz().stop(false);
        for (uint8 r; r < 3; ++r) {
            daily.retry(d, r);
        }
        assertEq(usd.balanceOf(address(daily)), 0);
        assertEq(usd.balanceOf(address(a)), 500_000);
    }

    /// Too little gas to pay must undo the whole call, never mark a prize as failed and move on.
    function test_starvedCallCannotSkipAPrize() public {
        _postAtEnd(w());
        vm.warp(_end(d) + 1 hours);
        uint256 s = vm.snapshotState();
        for (uint256 g = 30_000; g < 400_000; g += 3_000) {
            (bool ok,) = address(daily).call{gas: g}(abi.encodeCall(daily.pay, (d)));
            if (ok) assertEq(daily.day(d).settled, 7, "paid means all three");
            vm.revertToState(s);
        }
    }

    function test_daysAreIndependent() public {
        _fund(dave, d + 1, 2, 2e6);
        // Day d is never posted. The next two are paid on time.
        vm.warp(_end(d + 1));
        _post(d + 1, w());
        vm.warp(_end(d + 1) + 1 hours);
        daily.pay(d + 1);
        assertEq(usd.balanceOf(address(a)), 1e6);
        assertEq(daily.day(d).pool, 1e6);
        assertEq(usd.balanceOf(address(daily)), 1e6 + 2e6);
        vm.warp(_end(d) + 36 hours);
        daily.voidDay(d);
        daily.refund(d, dave);
        assertEq(usd.balanceOf(address(daily)), 2e6);
    }

    function test_takeBackOnlyBeforeTheDayBegins() public {
        _fund(dave, d + 1, 1, 2e6);
        vm.prank(dave);
        _bad();
        daily.takeBack(d);
        vm.prank(mallory);
        _bad();
        daily.takeBack(d + 1);
        vm.warp(_end(d) - 1);
        uint256 x = usd.balanceOf(dave);
        vm.prank(dave);
        daily.takeBack(d + 1);
        assertEq(usd.balanceOf(dave) - x, 2e6);
        assertEq(daily.day(d + 1).pool, 0);
        _fund(dave, d + 1, 1, 2e6);
        vm.warp(_end(d));
        vm.prank(dave);
        _bad();
        daily.takeBack(d + 1);
    }

    function test_fundingBounds() public {
        vm.startPrank(dave);
        _params();
        daily.fund(d - 1, 1, 1e6);
        _params();
        daily.fund(d + 367, 1, 1e6);
        _params();
        daily.fund(d, 0, 1e6);
        _params();
        daily.fund(d, 32, 1e6);
        _params();
        daily.fund(d, 1, 0);
        _params();
        daily.fund(d, 1, 99e6 + 1);
        daily.fund(d, 1, 99e6);
        daily.fund(d + 1, 31, 100e6);
        vm.stopPrank();
        assertEq(usd.balanceOf(address(daily)), 100e6 + 3100e6);
    }

    /// A role change can never reach a day that had begun when it was announced.
    function test_rolesChangeOnlyAfterEveryPromisedDayIsDecided() public {
        address s2 = makeAddr("s2");
        address a2 = makeAddr("a2");
        uint256 t = vm.getBlockTimestamp();
        vm.prank(mallory);
        vm.expectRevert();
        daily.proposeRoles(s2, a2);
        vm.prank(admin);
        daily.proposeRoles(s2, a2);
        // The latest a day running at t can be payable: posted in the last second, flagged in the last second.
        uint256 worst = _end(d) + 36 hours - 1 + 1 hours - 1 + 12 hours;
        assertLt(worst, t + daily.ROLE_DELAY());
        vm.warp(t + 4 days - 1);
        _bad();
        daily.applyRoles();
        vm.warp(t + 4 days);
        daily.applyRoles();
        (address s,) = daily.roles();
        assertEq(s, s2);
    }

    function test_roleDelayCoversEveryConfiguration() public view {
        // A day that began a moment before the change, the longest review, and a flag in its last second.
        assertLt(
            uint256(1 days) + daily.POST_WINDOW() + daily.MAX_REVIEW() + daily.FLAG_HOLD(), uint256(daily.ROLE_DELAY())
        );
    }

    function test_rolesCannotOverlap() public {
        address[2][5] memory x =
            [[coord, coord], [admin, arbiter], [coord, admin], [address(0), arbiter], [coord, address(0)]];
        for (uint256 i; i < 5; ++i) {
            vm.prank(admin);
            _params();
            daily.proposeRoles(x[i][0], x[i][1]);
        }
        vm.prank(admin);
        _bad();
        daily.renounceOwnership();
    }

    /// The admin has no way to move money, and neither does any role.
    function test_noSweep() public {
        bytes4[6] memory tries = [
            bytes4(keccak256("withdraw(uint256)")),
            bytes4(keccak256("sweep(address)")),
            bytes4(keccak256("rescue(address,uint256)")),
            bytes4(keccak256("emergencyWithdraw()")),
            bytes4(keccak256("setWinners(uint256,address[3])")),
            bytes4(keccak256("setReview(uint64)"))
        ];
        for (uint256 i; i < 6; ++i) {
            vm.prank(admin);
            (bool ok,) = address(daily).call(abi.encodeWithSelector(tries[i], d, address(admin)));
            assertFalse(ok);
        }
    }

    function test_robinhoodChainsOnly(uint64 chain) public {
        vm.assume(chain != 46630 && chain != 4663 && chain != 0);
        vm.chainId(chain);
        vm.expectRevert(PyraDailyRewards.WrongChain.selector);
        new PyraDailyRewards(address(usd), address(factory), admin, coord, arbiter, 1 hours);
    }

    function test_mainnetAllowed() public {
        vm.chainId(4663);
        PyraDailyRewards m = new PyraDailyRewards(address(usd), address(factory), admin, coord, arbiter, 1 hours);
        assertEq(m.REVIEW(), 1 hours);
    }

    function test_reviewBounds(uint64 x) public {
        if (x < 15 minutes || x > 6 hours) _params();
        new PyraDailyRewards(address(usd), address(factory), admin, coord, arbiter, x);
    }

    /// Whatever the pool and whoever won, every micro ends with a winner or a sponsor.
    function testFuzz_everyMicroIsAccountedFor(uint128 x, uint128 y, uint8 n) public {
        x = uint128(bound(x, 1, 50e6));
        y = uint128(bound(y, 1, 49e6));
        n = n % 4;
        _fund(dave, d + 1, 1, x);
        _fund(carol, d + 1, 1, y);
        uint256 was = usd.balanceOf(address(daily)) - (x + y);
        uint256 people = usd.balanceOf(dave) + usd.balanceOf(carol);
        address[3] memory win;
        for (uint256 i; i < n; ++i) {
            win[i] = w()[i];
        }
        vm.warp(_end(d + 1));
        _post(d + 1, win);
        vm.warp(_end(d + 1) + 1 hours);
        daily.pay(d + 1);
        uint256 paid = usd.balanceOf(address(a)) + usd.balanceOf(address(b)) + usd.balanceOf(address(c));
        try daily.refund(d + 1, dave) {} catch {}
        try daily.refund(d + 1, carol) {} catch {}
        uint256 back = usd.balanceOf(dave) + usd.balanceOf(carol) - people;
        uint256 left = usd.balanceOf(address(daily)) - was;
        assertEq(paid + back + left, uint256(x) + y);
        assertLe(left, 1, "at most one micro of rounding for two sponsors");
        if (n == 0 || n == 3) assertEq(left, 0);
        if (n == 3) {
            assertEq(usd.balanceOf(address(b)), (uint256(x) + y) * 30 / 100);
            assertEq(usd.balanceOf(address(c)), (uint256(x) + y) * 20 / 100);
        }
    }

    function testFuzz_noPaymentBeforeReview(uint32 dt) public {
        _postAtEnd(w());
        dt = uint32(bound(dt, 0, 3599));
        vm.warp(_end(d) + dt);
        _bad();
        daily.pay(d);
    }

    /// The normal pool works beside it and cannot see it.
    function test_doesNotTouchTheNormalPool() public {
        PyraPrizePool p = new PyraPrizePool(address(usd), address(factory), admin, coord, arbiter);
        vm.prank(coord);
        uint256 id = p.createEpoch(uint64(block.timestamp), uint64(block.timestamp + 1 days), keccak256("r"));
        vm.startPrank(dave);
        usd.approve(address(p), 1e6);
        p.fund(id, 1e6);
        vm.stopPrank();
        _postAtEnd(w());
        vm.warp(_end(d) + 1 hours);
        daily.pay(d);
        assertEq(usd.balanceOf(address(p)), 1e6);
        assertEq(p.epoch(id).pool, 1e6);
        assertEq(uint8(p.epoch(id).status), 1);
    }
}

contract DailyHandler is Test {
    PyraDailyRewards daily;
    FreezableUSD usd;
    PyraVault[4] vaults;
    address[4] people;
    address coord;
    address arbiter;
    uint256 public first;
    uint256 public last;
    mapping(uint256 => mapping(uint8 => uint256)) public paidTimes;
    uint256 public paidCalls;
    uint256 public refunds;
    uint256 public voids;
    uint256 public delayed;

    constructor(
        PyraDailyRewards d_,
        FreezableUSD u,
        PyraVault[4] memory v,
        address[4] memory p,
        address c_,
        address ar
    ) {
        (daily, usd, vaults, people, coord, arbiter) = (d_, u, v, p, c_, ar);
        first = d_.today();
        last = first;
    }

    function person(uint256 i) external view returns (address) {
        return people[i];
    }

    function _d(uint256 x) internal view returns (uint256) {
        return first + x % (last - first + 1);
    }

    function warp(uint32 s) external {
        vm.warp(block.timestamp + s % 20 hours);
    }

    function fund(uint256 i, uint256 ahead, uint256 n, uint128 x) external {
        n = n % 4 + 1;
        uint256 f = daily.today() + ahead % 3;
        x = uint128(bound(x, 1, 40e6));
        vm.startPrank(people[i % 4]);
        usd.approve(address(daily), type(uint256).max);
        try daily.fund(f, n, x) {
            if (f + n - 1 > last) last = f + n - 1;
        } catch {}
        vm.stopPrank();
    }

    function takeBack(uint256 i, uint256 x) external {
        vm.prank(people[i % 4]);
        try daily.takeBack(_d(x)) {} catch {}
    }

    function post(uint256 x, uint256 k, uint8 n, bool right) external {
        address[3] memory w;
        for (uint256 i; i < n % 4; ++i) {
            w[i] = address(vaults[(k % 4 + i) % 4]);
        }
        vm.prank(right ? coord : people[k % 4]);
        try daily.post(_d(x), w, keccak256("r")) {} catch {}
    }

    function judge(uint256 x, uint8 what, uint256 i, bool right) external {
        address who = right ? arbiter : people[i % 4];
        uint256 d = _d(x);
        if (what % 3 == 0) {
            vm.prank(people[i % 4]);
            try daily.flag(d, address(vaults[i % 4]), keccak256("f")) {} catch {}
        } else if (what % 3 == 1) {
            vm.prank(who);
            try daily.clearFlag(d) {} catch {}
        } else if (i % 4 == 0) {
            vm.prank(who);
            try daily.reject(d, keccak256("no")) {} catch {}
        }
    }

    function _count(Vm.Log[] memory l) internal {
        for (uint256 i; i < l.length; ++i) {
            if (l[i].emitter == address(daily) && l[i].topics[0] == PyraDailyRewards.PrizePaid.selector) {
                paidTimes[uint256(l[i].topics[1])][uint8(uint256(l[i].topics[2]))]++;
            }
            if (l[i].emitter == address(daily) && l[i].topics[0] == PyraDailyRewards.PrizeDelayed.selector) delayed++;
        }
    }

    function pay(uint256 x) external {
        vm.recordLogs();
        try daily.pay(_d(x)) {
            paidCalls++;
        } catch {}
        _count(vm.getRecordedLogs());
    }

    function retry(uint256 x, uint8 r) external {
        vm.recordLogs();
        try daily.retry(_d(x), r % 4) {} catch {}
        _count(vm.getRecordedLogs());
    }

    function voidDay(uint256 x) external {
        try daily.voidDay(_d(x)) {
            voids++;
        } catch {}
    }

    function refund(uint256 x, uint256 i) external {
        try daily.refund(_d(x), people[i % 4]) {
            refunds++;
        } catch {}
    }

    function freeze(uint256 i, bool on) external {
        usd.freeze(address(vaults[i % 4]), on);
    }
}

/// forge-config: default.invariant.runs = 64
/// forge-config: default.invariant.depth = 300
contract DailyInvariantTest is DailyBase {
    DailyHandler h;

    function setUp() public override {
        super.setUp();
        PyraVault[4] memory v = [a, b, c, mk(dave, "d")];
        address[4] memory p = [alice, bob, carol, dave];
        usd.mint(alice, 10_000e6);
        usd.mint(bob, 10_000e6);
        h = new DailyHandler(daily, FreezableUSD(address(usd)), v, p, coord, arbiter);
        targetContract(address(h));
    }

    /// It holds at least everything still owed, and never more than that plus rounding.
    function invariant_solvent() public view {
        uint256 owed;
        for (uint256 x = h.first(); x <= h.last(); ++x) {
            PyraDailyRewards.Day memory y = daily.day(x);
            uint256 sum;
            uint256 back;
            for (uint256 i; i < 4; ++i) {
                sum += daily.given(x, h.person(i));
                back += daily.refunded(x, h.person(i));
            }
            assertEq(sum, y.pool, "a pool is exactly what was given");
            assertLe(back, y.refundable, "no more goes back than nobody won");
            if (y.status == PyraDailyRewards.Status.None || y.status == PyraDailyRewards.Status.Posted) {
                owed += y.pool;
                assertEq(y.refundable, 0);
            } else {
                owed += y.refundable - back;
                if (y.status == PyraDailyRewards.Status.Paid) {
                    uint128 second = y.pool * 30 / 100;
                    uint128 third = y.pool * 20 / 100;
                    uint128[3] memory s = [y.pool - second - third, second, third];
                    for (uint8 r; r < 3; ++r) {
                        if (y.settled & uint8(1 << r) == 0) owed += s[r];
                    }
                } else {
                    assertEq(y.refundable, y.pool);
                }
            }
        }
        assertEq(usd.balanceOf(address(daily)), owed);
    }

    function invariant_noPrizeIsPaidTwice() public view {
        for (uint256 x = h.first(); x <= h.last(); ++x) {
            for (uint8 r; r < 3; ++r) {
                assertLe(h.paidTimes(x, r), 1);
            }
        }
    }

    function invariant_capHolds() public view {
        for (uint256 x = h.first(); x <= h.last(); ++x) {
            assertLe(daily.day(x).pool, daily.MAX_POOL());
        }
    }

    /// Proves the run reached the interesting states at least in this fixed order.
    function test_handlerReachesEverything() public {
        h.fund(0, 0, 0, 5e6);
        h.warp(15 hours);
        h.post(0, 0, 3, true);
        h.freeze(1, true);
        h.warp(2 hours);
        h.pay(0);
        assertEq(h.paidCalls(), 1);
        assertEq(h.delayed(), 1);
        h.freeze(1, false);
        h.retry(0, 1);
        assertEq(h.paidTimes(d, 1), 1);
    }
}

interface IUsdg {
    function transfer(address, uint256) external returns (bool);
}

/// Against a fork of Robinhood Chain testnet: real USDG, the deployed factory and the vaults that are in epoch 1.
/// forge test --match-contract DailyForkTest --fork-url robinhood_testnet
contract DailyForkTest is Test {
    IERC20 constant USDG = IERC20(0x7E955252E15c84f5768B83c41a71F9eba181802F);
    address constant PM = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant FACTORY = 0x4cc7a39444b107CEC0D61288d4EEA5400C531e58;
    PyraPrizePool constant POOL = PyraPrizePool(0x659916f24A1759d74b13ff8D8564eA9f5fc1E82A);
    address[3] V = [
        0xE30ced5deb2905E30D44Cfee7b8889381229D6Fd,
        0xd5E4299f7e95909C9c4d547F6B8e2b3a47d9Afc6,
        0xCc10270151F160873F64e6C5f9Abe98459A74fFC
    ];
    address admin = makeAddr("admin");
    address scorer = makeAddr("scorer");
    address arbiter = makeAddr("arbiter");
    address sponsor = makeAddr("sponsor");
    PyraDailyRewards daily;

    modifier onlyFork() {
        if (block.chainid != 46630 || FACTORY.code.length == 0) {
            vm.skip(true);
            return;
        }
        _;
    }

    function setUp() public {
        if (block.chainid != 46630 || FACTORY.code.length == 0) return;
        daily = new PyraDailyRewards(address(USDG), FACTORY, admin, scorer, arbiter, 1 hours);
        vm.prank(PM);
        IUsdg(address(USDG)).transfer(sponsor, 10e6);
        vm.prank(sponsor);
        USDG.approve(address(daily), 10e6);
    }

    function test_realVaultsArePaidAndEpochOneIsUntouched() public onlyFork {
        bytes32 before = keccak256(abi.encode(POOL.epoch(1)));
        uint256 held = USDG.balanceOf(address(POOL));
        uint256 d = daily.today();
        vm.prank(sponsor);
        daily.fund(d, 1, 1e6);
        vm.warp((d + 1) * 1 days);
        vm.prank(scorer);
        daily.post(d, V, keccak256("record"));
        vm.warp(block.timestamp + 1 hours);
        uint256[3] memory b;
        for (uint256 i; i < 3; ++i) {
            b[i] = USDG.balanceOf(V[i]);
        }
        daily.pay(d);
        assertEq(USDG.balanceOf(V[0]) - b[0], 500_000);
        assertEq(USDG.balanceOf(V[1]) - b[1], 300_000);
        assertEq(USDG.balanceOf(V[2]) - b[2], 200_000);
        assertEq(USDG.balanceOf(address(daily)), 0);
        // The winner's owner takes it out of the vault with the vault's own rules.
        address o = PyraVault(payable(V[0])).owner();
        uint256 x = USDG.balanceOf(o);
        vm.prank(o);
        PyraVault(payable(V[0])).withdraw(address(USDG), 500_000, o);
        assertEq(USDG.balanceOf(o) - x, 500_000);
        assertEq(keccak256(abi.encode(POOL.epoch(1))), before);
        assertEq(USDG.balanceOf(address(POOL)), held);
    }

    function test_realUsdgRefund() public onlyFork {
        uint256 d = daily.today();
        vm.prank(sponsor);
        daily.fund(d, 2, 1e6);
        uint256 x = USDG.balanceOf(sponsor);
        vm.prank(sponsor);
        daily.takeBack(d + 1);
        vm.warp((d + 1) * 1 days + 36 hours);
        daily.voidDay(d);
        daily.refund(d, sponsor);
        assertEq(USDG.balanceOf(sponsor) - x, 2e6);
        assertEq(USDG.balanceOf(address(daily)), 0);
    }
}
