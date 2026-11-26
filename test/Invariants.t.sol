// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Base, TestUSD} from "./Pyra.t.sol";
import {PyraVault} from "../src/PyraVault.sol";
import {PyraVaultFactory} from "../src/PyraVaultFactory.sol";
import {PyraEscrow} from "../src/PyraEscrow.sol";
import {PyraPrizePool} from "../src/PyraPrizePool.sol";

/// Random callers do random things in random order. Anything may revert; the books may never be wrong.
contract Handler is Test {
    TestUSD usd;
    PyraVaultFactory factory;
    PyraEscrow escrow;
    PyraPrizePool prizes;
    address operator;
    address coord;
    address verifier;
    address arbiter;
    address payee;
    address[] public people;
    PyraVault[] public vaults;
    bytes32[] public jobs;
    uint256 public paidOut; // by the operator, from every vault
    uint256 public permitted; // the most the owners ever signed for
    uint256 refs;
    uint256 keys;
    mapping(address => uint256) public received; // prizes and job pay, per vault
    mapping(uint8 => uint256) public done;

    constructor(
        TestUSD u,
        PyraVaultFactory f,
        PyraEscrow e,
        PyraPrizePool p,
        address[5] memory r,
        address[] memory who,
        PyraVault[] memory v
    ) {
        usd = u;
        factory = f;
        escrow = e;
        prizes = p;
        (operator, coord, verifier, arbiter, payee) = (r[0], r[1], r[2], r[3], r[4]);
        people = who;
        vaults = v;
        permitted = v.length * 10e6;
    }

    function _v(uint256 i) internal view returns (PyraVault) {
        return vaults[i % vaults.length];
    }

    function _j(uint256 i) internal view returns (bytes32) {
        return jobs.length == 0 ? bytes32(0) : jobs[i % jobs.length];
    }

    function vaultCount() external view returns (uint256) {
        return vaults.length;
    }

    function jobCount() external view returns (uint256) {
        return jobs.length;
    }

    function warp(uint32 s) external {
        vm.warp(block.timestamp + (s % 3 days));
    }

    function deposit(uint256 i, uint128 a) external {
        PyraVault v = _v(i);
        a = uint128(bound(a, 1, 1_100e6));
        vm.startPrank(v.owner());
        usd.approve(address(v), a);
        try v.deposit(a) {
            done[0]++;
        } catch {}
        vm.stopPrank();
    }

    function withdraw(uint256 i, uint128 a) external {
        PyraVault v = _v(i);
        uint256 b = usd.balanceOf(address(v));
        if (b == 0) return;
        address o = v.owner();
        a = uint128(bound(a, 1, b));
        vm.prank(o);
        v.withdraw(address(usd), a, o);
        done[1]++;
    }

    function pay(uint256 i, uint128 a, bool right, bool again) external {
        PyraVault v = _v(i);
        a = uint128(bound(a, 0, 6e6));
        bytes32 ref = bytes32(again && refs > 0 ? refs : ++refs);
        uint256 before = usd.balanceOf(payee);
        vm.prank(right ? operator : people[i % people.length]);
        try v.pay(payee, a, ref) {
            assertTrue(right, "only the operator pays");
            paidOut += a;
            assertEq(usd.balanceOf(payee) - before, a);
            done[2]++;
        } catch {}
    }

    function grant(uint256 i, uint128 tx_, uint128 day, uint128 total) external {
        PyraVault v = _v(i);
        tx_ = uint128(bound(tx_, 1, 4e6));
        day = uint128(bound(day, tx_, 8e6));
        total = uint128(bound(total, day, 12e6));
        vm.prank(v.owner());
        try v.grantPermission(PyraVault.Permission(operator, uint64(block.timestamp + 5 days), 100, tx_, day, total)) {
            permitted += total;
        } catch {}
    }

    function revoke(uint256 i) external {
        PyraVault v = _v(i);
        vm.prank(v.owner());
        v.revokePermission();
    }

    function hire(uint256 i, uint128 a) external {
        PyraVault v = _v(i);
        a = uint128(bound(a, 1, 5e6));
        vm.prank(operator);
        try v.fundJob(
            address(escrow), bytes32(++keys), a, uint64(block.timestamp + 3 days), 1 days, keccak256("s"), bytes32(++refs)
        ) returns (bytes32 id) {
            jobs.push(id);
            paidOut += a;
            done[3]++;
        } catch {}
    }

    function post(uint256 i, uint128 a) external {
        address c = people[i % people.length];
        a = uint128(bound(a, 1, 50e6));
        vm.startPrank(c);
        usd.approve(address(escrow), a);
        try escrow.createJob(bytes32(++keys), a, uint64(block.timestamp + 3 days), 1 days, keccak256("s")) returns (
            bytes32 id
        ) {
            jobs.push(id);
            done[4]++;
        } catch {}
        vm.stopPrank();
    }

    function step(uint256 i, uint256 w, uint8 what, uint128 x, uint256 who) external {
        bytes32 id = _j(i);
        if (id == 0) return;
        (address client, address worker, uint128 amount,,,,,,,) = escrow.jobs(id);
        address stranger = people[who % people.length];
        what = what % 9;
        if (what == 0) {
            vm.prank(coord);
            try escrow.assign(id, address(_v(w))) {} catch {}
        } else if (what == 1) {
            vm.prank(coord);
            try escrow.submit(id, keccak256("e")) {} catch {}
        } else if (what == 2) {
            vm.prank(verifier);
            try escrow.attest(id, x % 4 != 0, keccak256("r")) {} catch {}
        } else if (what == 3) {
            vm.prank(x % 2 == 0 ? client : stranger);
            uint256 b = usd.balanceOf(worker);
            try escrow.release(id) {
                assertEq(usd.balanceOf(worker) - b, amount);
                done[5]++;
            } catch {}
        } else if (what == 4) {
            vm.prank(x % 2 == 0 ? client : stranger);
            try escrow.dispute(id) {} catch {}
        } else if (what == 5) {
            vm.prank(arbiter);
            try escrow.resolve(id, uint128(bound(x, 0, amount))) {
                done[6]++;
            } catch {}
        } else if (what == 6) {
            vm.prank(x % 2 == 0 ? client : stranger);
            try escrow.cancel(id) {} catch {}
        } else if (what == 7) {
            vm.prank(stranger);
            try escrow.refundExpired(id) {
                done[7]++;
            } catch {}
        } else {
            PyraVault v = _v(w);
            vm.prank(operator);
            try v.settleJob(address(escrow), id, uint8(x % 3)) {} catch {}
        }
    }

    function epochStep(uint256 i, uint8 what, uint128 x, uint256 who) external {
        address p = people[who % people.length];
        uint256 n = prizes.epochCount();
        uint256 id = n == 0 ? 0 : i % n + 1;
        what = what % 9;
        if (what == 0) {
            vm.prank(coord);
            try prizes.createEpoch(uint64(block.timestamp), uint64(block.timestamp + 2 days), keccak256("r")) {} catch {}
        } else if (what == 1) {
            x = uint128(bound(x, 1, 100e6));
            vm.startPrank(p);
            usd.approve(address(prizes), x);
            try prizes.fund(id, x) {
                done[8]++;
            } catch {}
            vm.stopPrank();
        } else if (what == 2) {
            address[3] memory w;
            w[0] = address(_v(x));
            if (x % 3 > 0) w[1] = address(_v(uint256(x) + 1));
            if (x % 3 > 1) w[2] = address(_v(uint256(x) + 2));
            vm.prank(x % 5 == 0 ? p : coord);
            try prizes.propose(id, w, keccak256("s")) {} catch {}
        } else if (what == 3) {
            PyraVault v = _v(x);
            address o = v.owner();
            vm.prank(x % 2 == 0 ? o : p);
            try prizes.flag(id, address(v), keccak256("f")) {} catch {}
        } else if (what == 4) {
            vm.prank(x % 2 == 0 ? arbiter : p);
            try prizes.reject(id, keccak256("n")) {} catch {}
        } else if (what == 5) {
            try prizes.finalize(id) {} catch {}
        } else if (what == 6) {
            uint8 r = uint8(x % 4);
            try prizes.claim(id, r) {
                done[9]++;
            } catch {}
        } else if (what == 7) {
            vm.warp(block.timestamp + (x % 5 == 0 ? 33 days : 0));
            try prizes.cancelStale(id) {} catch {}
        } else {
            vm.prank(p);
            try prizes.reclaim(id) {
                done[10]++;
            } catch {}
        }
    }
}

/// forge-config: default.invariant.runs = 64
/// forge-config: default.invariant.depth = 250
contract InvariantTest is Base {
    Handler h;

    function setUp() public override {
        super.setUp();
        address[] memory who = new address[](4);
        (who[0], who[1], who[2], who[3]) = (alice, bob, carol, dave);
        PyraVault[] memory v = new PyraVault[](4);
        for (uint256 i; i < 4; ++i) {
            PyraVault.Config memory c;
            c.permission = PyraVault.Permission(operator, uint64(block.timestamp + 7 days), 100, 4e6, 6e6, 10e6);
            c.payees = new address[](1);
            c.payees[0] = payee;
            c.escrows = new address[](1);
            c.escrows[0] = address(escrow);
            vm.startPrank(who[i]);
            v[i] = PyraVault(payable(factory.createVault(bytes32(i + 1), c)));
            usd.approve(address(v[i]), 100e6);
            v[i].deposit(100e6);
            vm.stopPrank();
        }
        h = new Handler(usd, factory, escrow, prizes, [operator, coord, verifier, arbiter, payee], who, v);
        targetContract(address(h));
    }

    /// Escrow holds exactly what is still owed to somebody.
    function invariant_escrowIsSolvent() public view {
        uint256 owed;
        for (uint256 i; i < h.jobCount(); ++i) {
            (,, uint128 amount,,,, PyraEscrow.Status s,,,) = escrow.jobs(h.jobs(i));
            if (uint8(s) >= 1 && uint8(s) <= 4) owed += amount;
        }
        assertEq(usd.balanceOf(address(escrow)), owed);
    }

    /// The prize pool holds exactly: open pools, unclaimed prizes, what sponsors may take back, and the rollover.
    function invariant_prizePoolIsSolvent() public view {
        uint256 owed = prizes.rollover();
        for (uint256 id = 1; id <= prizes.epochCount(); ++id) {
            PyraPrizePool.Epoch memory e = prizes.epoch(id);
            if (e.status == PyraPrizePool.Status.Open || e.status == PyraPrizePool.Status.Proposed) owed += e.pool;
            if (e.status == PyraPrizePool.Status.Finalized) {
                uint128 second = e.pool * 30 / 100;
                uint128 third = e.pool * 20 / 100;
                uint128[3] memory s = [e.pool - second - third, second, third];
                for (uint256 r; r < 3; ++r) {
                    if (e.winners[r] != address(0) && !e.claimed[r]) owed += s[r];
                }
            }
            if (e.status == PyraPrizePool.Status.Cancelled) {
                for (uint256 i; i < 4; ++i) {
                    owed += prizes.contributed(id, h.people(i));
                }
            }
        }
        assertEq(usd.balanceOf(address(prizes)), owed);
    }

    /// The operator never moves more than the owners signed for, in total, whatever it tries.
    function invariant_operatorStaysInsideWhatWasSigned() public view {
        assertLe(h.paidOut(), h.permitted());
    }

    function invariant_vaultLimitsHold() public view {
        for (uint256 i; i < h.vaultCount(); ++i) {
            PyraVault v = h.vaults(i);
            (,,,, uint128 daily, uint128 total) = v.permission();
            assertLe(v.fundedPrincipal(), v.MAX_FUNDED());
            if (total != 0) {
                assertLe(v.spentTotal(), total);
                assertLe(v.remainingToday(), daily);
            }
        }
    }

    /// Nothing is made or lost between everybody who can hold it.
    function invariant_moneyIsConserved() public view {
        uint256 sum = usd.balanceOf(address(escrow)) + usd.balanceOf(address(prizes)) + usd.balanceOf(payee);
        for (uint256 i; i < 4; ++i) {
            sum += usd.balanceOf(h.people(i)) + usd.balanceOf(address(h.vaults(i)));
        }
        assertEq(sum, 40_000e6);
    }
}
