// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Base, PrizeTest} from "./Pyra.t.sol";
import {PyraPrizePool} from "../src/PyraPrizePool.sol";
import {PyraPrizePoolAccelerated} from "../src/testnet/PyraPrizePoolAccelerated.sol";
import {PyraVault} from "../src/PyraVault.sol";

/// Every existing prize test, run against the accelerated pool set to the normal two days. Same calls, same errors, same money.
contract AcceleratedBehavesLikeProduction is PrizeTest {
    function setUp() public override {
        vm.chainId(46630);
        super.setUp();
        usd.mint(dave, 100e6 + 1); // the shared setup already funded the normal pool with this much
        prizes = PyraPrizePool(
            address(new PyraPrizePoolAccelerated(address(usd), address(factory), admin, coord, arbiter, 2 days))
        );
        vm.prank(coord);
        id = prizes.createEpoch(uint64(block.timestamp), uint64(block.timestamp + 7 days), keccak256("rules"));
        vm.startPrank(dave);
        usd.approve(address(prizes), 100e6 + 1);
        prizes.fund(id, 100e6 + 1);
        vm.stopPrank();
    }
}

contract AcceleratedWindowTest is Base {
    PyraPrizePoolAccelerated fast;
    PyraVault a;
    PyraVault b;
    PyraVault c;
    uint256 id;

    function setUp() public override {
        vm.chainId(46630);
        super.setUp();
        a = mk(alice, "a");
        b = mk(bob, "b");
        c = mk(carol, "c");
        fast = new PyraPrizePoolAccelerated(address(usd), address(factory), admin, coord, arbiter, 15 minutes);
        prizes = PyraPrizePool(address(fast));
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

    function test_fifteenMinutesExactly() public {
        _propose(w());
        uint64 at = prizes.epoch(id).finalizableAt;
        assertEq(at, uint64(block.timestamp) + 900);
        vm.warp(at - 1);
        vm.expectRevert(PyraPrizePool.BadState.selector);
        prizes.finalize(id);
        vm.expectRevert(PyraPrizePool.BadState.selector);
        prizes.claim(id, 0);
        vm.warp(at);
        prizes.finalize(id);
        for (uint8 i; i < 3; ++i) {
            prizes.claim(id, i);
        }
        assertEq(usd.balanceOf(address(a)), 50e6 + 1);
        assertEq(usd.balanceOf(address(b)), 30e6);
        assertEq(usd.balanceOf(address(c)), 20e6);
        assertEq(usd.balanceOf(address(fast)), 0);
    }

    function test_disputeExtendsOnceByTheSameWindow() public {
        _propose(w());
        uint256 t = block.timestamp;
        vm.warp(t + 14 minutes);
        vm.prank(alice);
        prizes.flag(id, address(a), keccak256("why"));
        assertEq(prizes.epoch(id).finalizableAt, t + 14 minutes + 15 minutes);
        vm.prank(bob);
        vm.expectRevert(PyraPrizePool.BadState.selector);
        prizes.flag(id, address(b), keccak256("again"));
        vm.warp(t + 16 minutes);
        vm.expectRevert(PyraPrizePool.BadState.selector);
        prizes.finalize(id);
        vm.prank(arbiter);
        prizes.reject(id, keccak256("rejected"));
        vm.prank(coord);
        prizes.propose(id, w(), keccak256("scores again"));
        vm.warp(block.timestamp + 15 minutes);
        prizes.finalize(id);
    }

    function test_noDisputeOrRejectionAfterTheWindow() public {
        _propose(w());
        vm.warp(block.timestamp + 15 minutes);
        vm.prank(alice);
        vm.expectRevert(PyraPrizePool.BadState.selector);
        prizes.flag(id, address(a), keccak256("late"));
        vm.prank(arbiter);
        vm.expectRevert(PyraPrizePool.BadState.selector);
        prizes.reject(id, keccak256("late"));
    }

    function test_testnetOnly(uint64 chain) public {
        vm.assume(chain != 46630 && chain != 0);
        vm.chainId(chain);
        vm.expectRevert(PyraPrizePoolAccelerated.TestnetOnly.selector);
        new PyraPrizePoolAccelerated(address(usd), address(factory), admin, coord, arbiter, 15 minutes);
    }

    function test_windowBounds(uint64 x) public {
        if (x < 15 minutes || x > 2 days) {
            vm.expectRevert(PyraPrizePoolAccelerated.BadParams.selector);
            new PyraPrizePoolAccelerated(address(usd), address(factory), admin, coord, arbiter, x);
        } else {
            assertEq(
                new PyraPrizePoolAccelerated(address(usd), address(factory), admin, coord, arbiter, x).DISPUTE_WINDOW(),
                x
            );
        }
    }

    /// Nobody can change it afterwards: there is nothing to call.
    function test_windowCannotChange() public {
        bytes4[4] memory tries = [
            bytes4(keccak256("setDisputeWindow(uint64)")),
            bytes4(keccak256("setWindow(uint64)")),
            bytes4(keccak256("DISPUTE_WINDOW(uint64)")),
            bytes4(keccak256("initialize(uint64)"))
        ];
        for (uint256 i; i < 4; ++i) {
            vm.prank(admin);
            (bool ok,) = address(fast).call(abi.encodeWithSelector(tries[i], uint64(1)));
            assertFalse(ok);
        }
        assertEq(fast.DISPUTE_WINDOW(), 900);
    }

    function test_productionIsStillTwoDays() public {
        assertEq(
            new PyraPrizePool(address(usd), address(factory), admin, coord, arbiter).DISPUTE_WINDOW(), uint64(2 days)
        );
    }
}

/// The two sources are read side by side. Anything changed besides the window makes this fail.
contract AcceleratedSourceTest is Test {
    function test_onlyTheWindowDiffers() public view {
        string memory p = vm.readFile("src/PyraPrizePool.sol");
        string memory f = vm.readFile("src/testnet/PyraPrizePoolAccelerated.sol");
        p = vm.replace(p, "\r\n", "\n");
        f = vm.replace(f, "\r\n", "\n");
        p = vm.replace(p, "/// @title PyraPrizePool\n/// @notice Sponsor", "/// Sponsor");
        f = vm.replace(
            f,
            "/// @title PyraPrizePoolAccelerated\n/// @notice TESTNET ONLY. PyraPrizePool with a shorter dispute window, for testing the reward lifecycle.\n///         It cannot be deployed on any chain but Robinhood Chain testnet. Every other line is PyraPrizePool's,\n///         and test/Accelerated.t.sol fails if that stops being true.\n///         Sponsor",
            "/// Sponsor"
        );
        f = vm.replace(f, "contract PyraPrizePoolAccelerated is", "contract PyraPrizePool is");
        f = vm.replace(f, "../interfaces/IPyra.sol", "./interfaces/IPyra.sol");
        f = vm.replace(
            f,
            "    uint64 public immutable DISPUTE_WINDOW;\n    uint64 public constant MIN_WINDOW = 15 minutes;\n    uint64 public constant MAX_WINDOW = 2 days;\n    uint256 public constant TESTNET = 46630;\n",
            "    uint64 public constant DISPUTE_WINDOW = 2 days;\n"
        );
        f = vm.replace(f, "    error TestnetOnly();\n", "");
        f = vm.replace(
            f,
            "    constructor(address asset_, address factory_, address admin, address scorer_, address arbiter_, uint64 window_)\n        Ownable(admin)\n    {\n        if (block.chainid != TESTNET) revert TestnetOnly();\n        if (window_ < MIN_WINDOW || window_ > MAX_WINDOW) revert BadParams();\n        DISPUTE_WINDOW = window_;\n",
            "    constructor(address asset_, address factory_, address admin, address scorer_, address arbiter_) Ownable(admin) {\n"
        );
        assertEq(keccak256(bytes(f)), keccak256(bytes(p)), "the two pools differ in more than the window");
    }
}
