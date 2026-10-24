// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {RouletteVault} from "src/RouletteVault.sol";
import {BaseTest} from "test/utils/BaseTest.sol";

contract RouletteVaultTest is BaseTest {
    /*//////////////////////////////////////////////////////////////
                             LP ACCOUNTING
    //////////////////////////////////////////////////////////////*/
    function test_Decimals_IncludeOffset() public view {
        assertEq(vault.decimals(), 12);
    }

    function testFuzz_DepositRedeem_RoundTrip(uint256 amount) public {
        amount = bound(amount, 1, MAX_VAULT_CAPACITY);
        uint256 shares = _lpDeposit(lp1, amount);

        assertEq(vault.totalAssets(), amount);
        assertEq(usdc.balanceOf(address(vault)), amount);

        vm.prank(lp1);
        uint256 assets = vault.redeem(shares, lp1, lp1);
        assertEq(assets, amount);
        assertEq(vault.totalAssets(), 0);
    }

    function testFuzz_TotalAssets_IsVaultBalance(uint256 deposit, uint256 profit) public {
        deposit = bound(deposit, 1e6, MAX_VAULT_CAPACITY);
        profit = bound(profit, 0, 1e30);
        _lpDeposit(lp1, deposit);

        // House profit arrives as a plain transfer from Roulette
        usdc.mint(address(roulette), profit);
        vm.prank(address(roulette));
        usdc.transfer(address(vault), profit);

        assertEq(vault.totalAssets(), deposit + profit);
    }

    function test_HouseProfit_SplitByShares() public {
        _lpDeposit(lp1, 30_000e6);
        _lpDeposit(lp2, 10_000e6);
        usdc.mint(address(vault), 4_000e6);

        assertApproxEqAbs(vault.maxWithdraw(lp1), 33_000e6, 1);
        assertApproxEqAbs(vault.maxWithdraw(lp2), 11_000e6, 1);
    }

    /// @dev Classic donation attack: attacker deposits 1 wei, donates a lot, victim's shares round down
    function test_DonationAttack_VictimKeepsAlmostAllValue() public {
        _lpDeposit(lp1, 1);
        usdc.mint(address(vault), 10_000e6); // donation by lp1 (attacker)

        uint256 victimDeposit = 1_000e6;
        _lpDeposit(lp2, victimDeposit);

        assertApproxEqRel(vault.maxWithdraw(lp2), victimDeposit, 0.001e18, "victim loses < 0.1%");
    }

    /*//////////////////////////////////////////////////////////////
                                CAPACITY
    //////////////////////////////////////////////////////////////*/
    function testFuzz_MaxDeposit_IsRemainingCapacity(uint256 deposited) public {
        deposited = bound(deposited, 0, MAX_VAULT_CAPACITY);
        if (deposited > 0) _lpDeposit(lp1, deposited);
        assertEq(vault.maxDeposit(lp2), MAX_VAULT_CAPACITY - deposited);
    }

    function test_Deposit_RevertWhen_OverCapacity() public {
        _lpDeposit(lp1, MAX_VAULT_CAPACITY);
        usdc.mint(lp2, 1);
        vm.startPrank(lp2);
        usdc.approve(address(vault), 1);
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxDeposit.selector, lp2, 1, 0));
        vault.deposit(1, lp2);
        vm.stopPrank();
    }

    function test_Mint_RespectsCapacity() public {
        _lpDeposit(lp1, MAX_VAULT_CAPACITY - 1e6);
        uint256 maxShares = vault.maxMint(lp2);
        assertEq(vault.previewMint(maxShares), 1e6);
    }

    function test_MaxDeposit_UnlimitedCapacity() public {
        vm.prank(owner);
        vault.setMaxCapacity(type(uint256).max);
        assertEq(vault.maxDeposit(lp1), type(uint256).max);
        assertEq(vault.maxMint(lp1), type(uint256).max);
    }

    function test_SetMaxCapacity() public {
        vm.prank(owner);
        vault.setMaxCapacity(5e6);
        assertEq(vault.maxCapacity(), 5e6);

        vm.prank(lp1);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, lp1));
        vault.setMaxCapacity(1);
    }

    /*//////////////////////////////////////////////////////////////
                              ROULETTE LINK
    //////////////////////////////////////////////////////////////*/
    function test_SetRoulette_RevertWhen_AlreadySet() public {
        vm.prank(owner);
        vm.expectRevert(RouletteVault.RouletteVault__RouletteAlreadySet.selector);
        vault.setRoulette(lp1);
    }

    function test_SetRoulette_RevertWhen_ZeroAddress() public {
        RouletteVault fresh = new RouletteVault(address(usdc), "V", "V", 1);
        vm.expectRevert(RouletteVault.RouletteVault__InvalidAddress.selector);
        fresh.setRoulette(address(0));
    }

    function test_NoRoulette_NeverLocked() public {
        RouletteVault fresh = new RouletteVault(address(usdc), "V", "V", 100e6);
        assertFalse(fresh.isLpLocked());
        assertEq(fresh.maxDeposit(lp1), 100e6);
    }

    function testFuzz_FundPayout_RevertWhen_NotRoulette(address caller) public {
        vm.assume(caller != address(roulette));
        _lpDeposit(lp1, 1_000e6);
        vm.prank(caller);
        vm.expectRevert(RouletteVault.RouletteVault__UnauthorizedCaller.selector);
        vault.fundPayout(1e6);
    }

    function test_FundPayout_SendsToRoulette() public {
        _lpDeposit(lp1, 1_000e6);
        vm.prank(address(roulette));
        vault.fundPayout(400e6);
        assertEq(usdc.balanceOf(address(roulette)), 400e6);
        assertEq(vault.totalAssets(), 600e6);
    }

    function test_FundPayout_RevertWhen_Zero() public {
        vm.prank(address(roulette));
        vm.expectRevert(RouletteVault.RouletteVault__InvalidAmount.selector);
        vault.fundPayout(0);
    }

    /*//////////////////////////////////////////////////////////////
                                LP LOCK
    //////////////////////////////////////////////////////////////*/
    function test_EmergencyStop_LocksLpsUntilResumed() public {
        _lpDeposit(lp1, LP_LIQUIDITY);
        vm.prank(owner);
        roulette.emergencyStopBetting();
        assertTrue(vault.isLpLocked());
        assertEq(vault.maxRedeem(lp1), 0);

        vm.prank(owner);
        roulette.emergencyResumeBetting();
        assertFalse(vault.isLpLocked());
        assertEq(vault.maxWithdraw(lp1), LP_LIQUIDITY);
    }

    function test_Ownership_TwoStep() public {
        vm.prank(owner);
        vault.transferOwnership(lp1);
        assertEq(vault.owner(), owner);

        vm.prank(lp1);
        vault.acceptOwnership();
        assertEq(vault.owner(), lp1);
    }
}
