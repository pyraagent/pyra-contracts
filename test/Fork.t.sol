// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PyraVault} from "../src/PyraVault.sol";
import {PyraVaultFactory} from "../src/PyraVaultFactory.sol";
import {UniV4Adapter, IStateView} from "../src/UniV4Adapter.sol";

/// Runs against a fork of Robinhood Chain testnet or mainnet: real USDG, real Uniswap v4 pool.
/// forge test --match-contract ForkTest --fork-url robinhood_testnet (or robinhood_mainnet)
contract ForkTest is Test {
    IERC20 USDG;
    address constant PM = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant SV = 0xF3334192D15450CdD385c8B70e03f9A6bD9E673b;
    bytes32 constant POOL = 0xf76eb83b8bb6de286ef58daac9dc52ae5c22b1cf2b0cce47041b17375b0a1669;

    address owner = makeAddr("owner");
    address operator = makeAddr("operator");
    PyraVault vault;
    UniV4Adapter adapter;

    function _live() internal view returns (bool) {
        return block.chainid == 46630 || block.chainid == 4663;
    }

    function setUp() public {
        if (!_live()) return;
        USDG = IERC20(block.chainid == 4663 ? 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168 : 0x7E955252E15c84f5768B83c41a71F9eba181802F);
        PyraVaultFactory f = new PyraVaultFactory(address(USDG));
        adapter = new UniV4Adapter(PM, SV, address(0), address(USDG), 3000, 60);
        PyraVault.Config memory c;
        c.permission = PyraVault.Permission(operator, uint64(block.timestamp + 1 days), 300, 10e6, 10e6, 10e6);
        c.adapters = new address[](1);
        c.adapters[0] = address(adapter);
        c.tokens = new address[](1);
        vm.prank(owner);
        vault = PyraVault(payable(f.createVault("VEX", c)));
        // Moves real forked balance out of the pool manager instead of writing token storage.
        vm.prank(PM);
        USDG.transfer(owner, 50e6);
        vm.startPrank(owner);
        USDG.approve(address(vault), 10e6);
        vault.deposit(10e6);
        vm.stopPrank();
    }

    modifier onlyFork() {
        if (!_live()) {
            vm.skip(true);
            return;
        }
        _;
    }

    function test_poolIdMatchesDeployedPool() public onlyFork {
        if (block.chainid == 46630) assertEq(adapter.poolId(), POOL);
        (uint160 p,,, uint24 fee) = IStateView(SV).getSlot0(adapter.poolId());
        assertGt(p, 0);
        assertEq(fee, 3000);
    }

    function test_buyAndSellRoundTrip() public onlyFork {
        vm.prank(operator);
        uint256 got = vault.swap(address(adapter), address(USDG), address(0), 5e5, 1, "buy");
        assertEq(address(vault).balance, got);
        assertEq(USDG.balanceOf(address(vault)), 95e5);
        vm.prank(operator);
        uint256 back = vault.swap(address(adapter), address(0), address(USDG), uint128(got), 1, "sell");
        assertGt(back, 48e4); // two 0.30% fees plus rounding
        assertLt(back, 5e5);
        assertEq(USDG.balanceOf(address(adapter)), 0);
        assertEq(address(adapter).balance, 0);
    }

    function test_minOutEnforced() public onlyFork {
        vm.prank(operator);
        vm.expectRevert();
        vault.swap(address(adapter), address(USDG), address(0), 2e6, 1 ether, "buy");
    }

    function test_priceImpactCapRejectsLargeTrade() public onlyFork {
        deal(address(this), 1 ether);
        uint256 big = USDG.balanceOf(PM) / 2; // far beyond a 0.5% price move on either network
        vm.prank(PM);
        USDG.transfer(address(this), big);
        USDG.approve(address(adapter), type(uint256).max);
        vm.expectRevert();
        adapter.swapExactIn(address(USDG), address(0), uint128(big), 1, 50);
    }

    function test_strangerCannotCallCallback() public onlyFork {
        vm.expectRevert(UniV4Adapter.NotManager.selector);
        adapter.unlockCallback("");
    }

    receive() external payable {}
}
