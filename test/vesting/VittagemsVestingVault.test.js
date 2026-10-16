const { expect } = require("chai");
const { ethers } = require("hardhat");
const { loadFixture, time } = require("@nomicfoundation/hardhat-network-helpers");

describe("VittagemsVestingVault", function () {
  const ONE_DAY = 86400;
  const ONE_MONTH = 30 * ONE_DAY;
  const SIX_MONTHS = 180 * ONE_DAY;
  const ONE_YEAR = 365 * ONE_DAY;

  const PAUSER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("PAUSER_ROLE"));
  const MINTER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("MINTER_ROLE"));
  const DEFAULT_ADMIN_ROLE = ethers.ZeroHash;

  async function deployVestingFixture() {
    const [admin, pauser, beneficiary1, beneficiary2, externalUser] = await ethers.getSigners();

    // 1. Deploy MockReserveOracle with 10M reserve for Vittagems
    const initialReserve = ethers.parseEther("10000000"); // 10,000,000 VGMG
    const MockOracle = await ethers.getContractFactory("MockReserveOracle");
    const oracle = await MockOracle.deploy(initialReserve);
    await oracle.waitForDeployment();

    // 2. Deploy Vittagems ERC20 token
    const Vittagems = await ethers.getContractFactory("contracts/erc20.sol:Vittagems");
    const vgmg = await Vittagems.deploy(
      admin.address,
      pauser.address,
      admin.address, // initial minter
      3600 // staleness threshold
    );
    await vgmg.waitForDeployment();

    // Set & lock oracle on Vittagems token
    await vgmg.connect(admin).setReserveOracle(await oracle.getAddress());
    await vgmg.connect(admin).lockReserveOracle();

    // 3. Deploy VittagemsVestingVault (ERC4626)
    const VittagemsVestingVault = await ethers.getContractFactory("VittagemsVestingVault");
    const vault = await VittagemsVestingVault.deploy(
      await vgmg.getAddress(),
      "Vittagems Vesting Vault",
      "vVGMG",
      admin.address,
      pauser.address
    );
    await vault.waitForDeployment();

    // 4. Grant MINTER_ROLE on Vittagems to the Vesting Vault so adminMintAndVest can mint directly
    await vgmg.connect(admin).grantRole(MINTER_ROLE, await vault.getAddress());

    // 5. Pre-mint some VGMG to admin, beneficiary1, and externalUser for deposit tests
    const preMintAmount = ethers.parseEther("100000"); // 100k VGMG
    await vgmg.connect(admin).mint(admin.address, preMintAmount);
    await vgmg.connect(admin).mint(beneficiary1.address, preMintAmount);
    await vgmg.connect(admin).mint(externalUser.address, preMintAmount);

    return {
      vgmg,
      vault,
      oracle,
      admin,
      pauser,
      beneficiary1,
      beneficiary2,
      externalUser,
    };
  }

  // =========================================================================
  // 1. Deployment & Constructor
  // =========================================================================
  describe("Deployment & Configuration", function () {
    it("should deploy with correct name, symbol, and underlying asset", async function () {
      const { vault, vgmg } = await loadFixture(deployVestingFixture);
      expect(await vault.name()).to.equal("Vittagems Vesting Vault");
      expect(await vault.symbol()).to.equal("vVGMG");
      expect(await vault.asset()).to.equal(await vgmg.getAddress());
      expect(await vault.decimals()).to.equal(18);
    });

    it("should assign DEFAULT_ADMIN_ROLE and PAUSER_ROLE", async function () {
      const { vault, admin, pauser } = await loadFixture(deployVestingFixture);
      expect(await vault.hasRole(DEFAULT_ADMIN_ROLE, admin.address)).to.be.true;
      expect(await vault.hasRole(PAUSER_ROLE, pauser.address)).to.be.true;
    });

    it("should initialize default vesting parameters", async function () {
      const { vault } = await loadFixture(deployVestingFixture);
      expect(await vault.defaultVestingDuration()).to.equal(SIX_MONTHS);
      expect(await vault.defaultCliffDuration()).to.equal(0);
      expect(await vault.defaultRevocable()).to.be.true;
    });

    it("should revert if initialized with zero addresses", async function () {
      const { vgmg, admin, pauser } = await loadFixture(deployVestingFixture);
      const VittagemsVestingVault = await ethers.getContractFactory("VittagemsVestingVault");

      await expect(
        VittagemsVestingVault.deploy(ethers.ZeroAddress, "Vault", "V", admin.address, pauser.address)
      ).to.be.revertedWithCustomError(VittagemsVestingVault, "InvalidAddress");

      await expect(
        VittagemsVestingVault.deploy(await vgmg.getAddress(), "Vault", "V", ethers.ZeroAddress, pauser.address)
      ).to.be.revertedWithCustomError(VittagemsVestingVault, "InvalidAddress");

      await expect(
        VittagemsVestingVault.deploy(await vgmg.getAddress(), "Vault", "V", admin.address, ethers.ZeroAddress)
      ).to.be.revertedWithCustomError(VittagemsVestingVault, "InvalidAddress");
    });
  });

  // =========================================================================
  // 2. Admin Mint and Vest
  // =========================================================================
  describe("adminMintAndVest", function () {
    it("should allow admin to mint VGMG directly into vault and vest for beneficiary", async function () {
      const { vault, vgmg, admin, beneficiary1 } = await loadFixture(deployVestingFixture);
      const vestAmount = ethers.parseEther("10000");

      const tx = await vault.connect(admin).adminMintAndVest(
        beneficiary1.address,
        vestAmount,
        ONE_YEAR,
        ONE_MONTH,
        true
      );

      await expect(tx)
        .to.emit(vault, "AdminMintedAndVested")
        .withArgs(beneficiary1.address, vestAmount, 0);

      // Verify shares allocated to beneficiary
      expect(await vault.balanceOf(beneficiary1.address)).to.equal(vestAmount);
      expect(await vault.totalSupply()).to.equal(vestAmount);
      expect(await vault.totalAssets()).to.equal(vestAmount);

      // Verify schedule details
      const schedule = await vault.getSchedule(0);
      expect(schedule.id).to.equal(0);
      expect(schedule.beneficiary).to.equal(beneficiary1.address);
      expect(schedule.funder).to.equal(admin.address);
      expect(schedule.totalAssets).to.equal(vestAmount);
      expect(schedule.duration).to.equal(ONE_YEAR);
      expect(schedule.cliffDuration).to.equal(ONE_MONTH);
      expect(schedule.revocable).to.be.true;
      expect(schedule.initialized).to.be.true;

      // Beneficiary schedule list
      const schedules = await vault.getBeneficiarySchedules(beneficiary1.address);
      expect(schedules.length).to.equal(1);
      expect(schedules[0]).to.equal(0);
    });

    it("should revert if non-admin calls adminMintAndVest", async function () {
      const { vault, beneficiary1, externalUser } = await loadFixture(deployVestingFixture);
      const vestAmount = ethers.parseEther("1000");

      await expect(
        vault.connect(externalUser).adminMintAndVest(
          beneficiary1.address,
          vestAmount,
          ONE_YEAR,
          0,
          true
        )
      ).to.be.revertedWithCustomError(vault, "Unauthorized");
    });

    it("should revert if parameters are invalid", async function () {
      const { vault, admin, beneficiary1 } = await loadFixture(deployVestingFixture);
      const vestAmount = ethers.parseEther("1000");

      // Zero address beneficiary
      await expect(
        vault.connect(admin).adminMintAndVest(ethers.ZeroAddress, vestAmount, ONE_YEAR, 0, true)
      ).to.be.revertedWithCustomError(vault, "InvalidAddress");

      // Zero amount
      await expect(
        vault.connect(admin).adminMintAndVest(beneficiary1.address, 0, ONE_YEAR, 0, true)
      ).to.be.revertedWithCustomError(vault, "ZeroAmount");

      // Zero duration
      await expect(
        vault.connect(admin).adminMintAndVest(beneficiary1.address, vestAmount, 0, 0, true)
      ).to.be.revertedWithCustomError(vault, "InvalidVestingParameters");

      // Cliff exceeds duration
      await expect(
        vault.connect(admin).adminMintAndVest(beneficiary1.address, vestAmount, ONE_MONTH, ONE_YEAR, true)
      ).to.be.revertedWithCustomError(vault, "InvalidVestingParameters");
    });
  });

  // =========================================================================
  // 3. Admin Deposit and Vest
  // =========================================================================
  describe("adminDepositAndVest", function () {
    it("should allow admin to transfer existing VGMG and vest for beneficiary", async function () {
      const { vault, vgmg, admin, beneficiary1 } = await loadFixture(deployVestingFixture);
      const vestAmount = ethers.parseEther("5000");

      await vgmg.connect(admin).approve(await vault.getAddress(), vestAmount);

      await expect(
        vault.connect(admin).adminDepositAndVest(
          beneficiary1.address,
          vestAmount,
          SIX_MONTHS,
          0,
          false
        )
      )
        .to.emit(vault, "AdminDepositedAndVested")
        .withArgs(beneficiary1.address, vestAmount, 0);

      expect(await vault.balanceOf(beneficiary1.address)).to.equal(vestAmount);
    });
  });

  // =========================================================================
  // 4. Beneficiary Approval for Admin Vesting
  // =========================================================================
  describe("Beneficiary Approval & adminCreateVestingFromBeneficiary", function () {
    it("should revert if beneficiary has not approved admin to create vesting from their funds", async function () {
      const { vault, vgmg, admin, beneficiary1 } = await loadFixture(deployVestingFixture);
      const vestAmount = ethers.parseEther("2000");

      await vgmg.connect(beneficiary1).approve(await vault.getAddress(), vestAmount);

      await expect(
        vault.connect(admin).adminCreateVestingFromBeneficiary(
          beneficiary1.address,
          vestAmount,
          ONE_YEAR,
          0,
          true
        )
      ).to.be.revertedWithCustomError(vault, "BeneficiaryApprovalRequired");
    });

    it("should succeed after beneficiary calls setVestingApproval and gives token allowance", async function () {
      const { vault, vgmg, admin, beneficiary1 } = await loadFixture(deployVestingFixture);
      const vestAmount = ethers.parseEther("2000");

      // 1. Beneficiary approves admin on vault
      await expect(vault.connect(beneficiary1).setVestingApproval(admin.address, true))
        .to.emit(vault, "VestingApprovalUpdated")
        .withArgs(beneficiary1.address, admin.address, true);

      expect(await vault.isApprovedForVesting(beneficiary1.address, admin.address)).to.be.true;

      // 2. Beneficiary approves VGMG allowance to vault
      await vgmg.connect(beneficiary1).approve(await vault.getAddress(), vestAmount);

      // 3. Admin creates vesting from beneficiary funds
      await expect(
        vault.connect(admin).adminCreateVestingFromBeneficiary(
          beneficiary1.address,
          vestAmount,
          ONE_YEAR,
          ONE_MONTH,
          true
        )
      )
        .to.emit(vault, "BeneficiaryVestingCreatedByAdmin")
        .withArgs(beneficiary1.address, admin.address, vestAmount, 0);

      // Verify schedule has beneficiary as both funder and beneficiary
      const schedule = await vault.getSchedule(0);
      expect(schedule.funder).to.equal(beneficiary1.address);
      expect(schedule.beneficiary).to.equal(beneficiary1.address);
      expect(schedule.totalAssets).to.equal(vestAmount);
    });
  });

  // =========================================================================
  // 5. User Direct Deposit
  // =========================================================================
  describe("depositAndVest (Direct Deposit)", function () {
    it("should allow a user to directly deposit and vest their own VGMG tokens", async function () {
      const { vault, vgmg, externalUser } = await loadFixture(deployVestingFixture);
      const vestAmount = ethers.parseEther("3000");

      await vgmg.connect(externalUser).approve(await vault.getAddress(), vestAmount);

      await expect(
        vault.connect(externalUser).depositAndVest(
          vestAmount,
          SIX_MONTHS,
          ONE_MONTH,
          true
        )
      )
        .to.emit(vault, "UserDirectDepositVested")
        .withArgs(externalUser.address, vestAmount, 0);

      expect(await vault.balanceOf(externalUser.address)).to.equal(vestAmount);
      const schedule = await vault.getSchedule(0);
      expect(schedule.beneficiary).to.equal(externalUser.address);
      expect(schedule.funder).to.equal(externalUser.address);
    });

    it("should allow standard ERC4626 deposit using default parameters", async function () {
      const { vault, vgmg, externalUser } = await loadFixture(deployVestingFixture);
      const depositAmount = ethers.parseEther("1000");

      await vgmg.connect(externalUser).approve(await vault.getAddress(), depositAmount);

      await vault.connect(externalUser).deposit(depositAmount, externalUser.address);

      expect(await vault.balanceOf(externalUser.address)).to.equal(depositAmount);
      const schedule = await vault.getSchedule(0);
      expect(schedule.duration).to.equal(SIX_MONTHS); // default
      expect(schedule.cliffDuration).to.equal(0);
    });
  });

  // =========================================================================
  // 6. Vesting Progression, Cliff, and Claiming
  // =========================================================================
  describe("Vesting Calculations & Token Claims", function () {
    it("should return 0 vested amount before cliff is reached", async function () {
      const { vault, admin, beneficiary1 } = await loadFixture(deployVestingFixture);
      const vestAmount = ethers.parseEther("12000");

      await vault.connect(admin).adminMintAndVest(
        beneficiary1.address,
        vestAmount,
        ONE_YEAR, // 365 days
        ONE_MONTH, // 30 days cliff
        true
      );

      // Fast-forward 15 days (before cliff)
      await time.increase(15 * ONE_DAY);

      expect(await vault.vestedAmount(0)).to.equal(0);
      expect(await vault.releasableAmount(0)).to.equal(0);

      // Claiming before cliff should revert
      await expect(
        vault.connect(beneficiary1).claim(0, ethers.parseEther("100"), beneficiary1.address)
      ).to.be.revertedWithCustomError(vault, "InvalidClaimAmount");
    });

    it("should calculate linear vesting accurately after cliff", async function () {
      const { vault, admin, beneficiary1 } = await loadFixture(deployVestingFixture);
      const vestAmount = ethers.parseEther("12000");
      const duration = 120 * ONE_DAY; // 120 days
      const cliff = 30 * ONE_DAY;    // 30 days

      await vault.connect(admin).adminMintAndVest(
        beneficiary1.address,
        vestAmount,
        duration,
        cliff,
        true
      );

      // Fast-forward to day 60 (halfway through 120 days)
      await time.increase(60 * ONE_DAY);

      const vested = await vault.vestedAmount(0);
      const expectedVested = vestAmount / 2n;

      // Allow 1-2 seconds margin for block timestamp advancement
      const diff = vested > expectedVested ? vested - expectedVested : expectedVested - vested;
      expect(diff).to.be.lte(ethers.parseEther("1")); // within 1 token
    });

    it("should allow beneficiary to claim vested VGMG tokens", async function () {
      const { vault, vgmg, admin, beneficiary1 } = await loadFixture(deployVestingFixture);
      const vestAmount = ethers.parseEther("10000");
      const duration = 100 * ONE_DAY;

      await vault.connect(admin).adminMintAndVest(
        beneficiary1.address,
        vestAmount,
        duration,
        0, // no cliff
        true
      );

      // Advance 50 days (50% vested = 5,000 VGMG)
      await time.increase(50 * ONE_DAY);

      const releasable = await vault.releasableAmount(0);
      expect(releasable).to.be.gte(ethers.parseEther("5000"));

      const beforeBalance = await vgmg.balanceOf(beneficiary1.address);

      // Claim 5000 tokens
      const claimAmount = ethers.parseEther("5000");
      await expect(vault.connect(beneficiary1).claim(0, claimAmount, beneficiary1.address))
        .to.emit(vault, "TokensClaimed")
        .withArgs(0, beneficiary1.address, beneficiary1.address, claimAmount);

      const afterBalance = await vgmg.balanceOf(beneficiary1.address);
      expect(afterBalance - beforeBalance).to.equal(claimAmount);

      // Shares burned 1:1
      expect(await vault.balanceOf(beneficiary1.address)).to.equal(vestAmount - claimAmount);
    });

    it("should support claimAll and claimAllSchedules", async function () {
      const { vault, vgmg, admin, beneficiary1 } = await loadFixture(deployVestingFixture);
      const vestAmount1 = ethers.parseEther("1000");
      const vestAmount2 = ethers.parseEther("2000");

      await vault.connect(admin).adminMintAndVest(beneficiary1.address, vestAmount1, 100, 0, true);
      await vault.connect(admin).adminMintAndVest(beneficiary1.address, vestAmount2, 100, 0, true);

      // Advance 100 seconds to fully vest both
      await time.increase(101);

      const beforeBalance = await vgmg.balanceOf(beneficiary1.address);
      await vault.connect(beneficiary1).claimAllSchedules(beneficiary1.address);
      const afterBalance = await vgmg.balanceOf(beneficiary1.address);

      expect(afterBalance - beforeBalance).to.equal(vestAmount1 + vestAmount2);
      expect(await vault.balanceOf(beneficiary1.address)).to.equal(0);
    });

    it("should allow ERC4626 redeem and withdraw up to maxRedeem/maxWithdraw", async function () {
      const { vault, vgmg, admin, beneficiary1 } = await loadFixture(deployVestingFixture);
      const vestAmount = ethers.parseEther("1000");

      await vault.connect(admin).adminMintAndVest(beneficiary1.address, vestAmount, 100, 0, true);

      // Advance 50 seconds (50% vested)
      await time.increase(50);

      const maxRedeem = await vault.maxRedeem(beneficiary1.address);
      expect(maxRedeem).to.be.gte(ethers.parseEther("500"));

      // Standard ERC4626 redeem
      const redeemShares = ethers.parseEther("500");
      await vault.connect(beneficiary1).redeem(redeemShares, beneficiary1.address, beneficiary1.address);

      expect(await vault.balanceOf(beneficiary1.address)).to.equal(ethers.parseEther("500"));
    });
  });

  // =========================================================================
  // 7. Share Transfer Lock (Unvested Protection)
  // =========================================================================
  describe("Share Transfer Protection", function () {
    it("should prevent transferring unvested vault shares to another user", async function () {
      const { vault, admin, beneficiary1, beneficiary2 } = await loadFixture(deployVestingFixture);
      const vestAmount = ethers.parseEther("1000");

      await vault.connect(admin).adminMintAndVest(beneficiary1.address, vestAmount, ONE_YEAR, 0, true);

      // Attempt to transfer unvested shares immediately
      await expect(
        vault.connect(beneficiary1).transfer(beneficiary2.address, ethers.parseEther("100"))
      ).to.be.revertedWithCustomError(vault, "SharesLockedInVesting");
    });

    it("should allow transferring vault shares once they are unlocked/vested", async function () {
      const { vault, admin, beneficiary1, beneficiary2 } = await loadFixture(deployVestingFixture);
      const vestAmount = ethers.parseEther("1000");

      await vault.connect(admin).adminMintAndVest(beneficiary1.address, vestAmount, 100, 0, true);

      // Fast forward past duration
      await time.increase(101);

      // Now all shares are vested, transfer of 200 shares is allowed
      await expect(vault.connect(beneficiary1).transfer(beneficiary2.address, ethers.parseEther("200")))
        .to.not.be.reverted;

      expect(await vault.balanceOf(beneficiary2.address)).to.equal(ethers.parseEther("200"));
    });
  });

  // =========================================================================
  // 8. Revocation Lifecycle (Request -> Admin Approve / Reject)
  // =========================================================================
  describe("Revocation Lifecycle", function () {
    it("should not allow revocation request on non-revocable schedule", async function () {
      const { vault, admin, beneficiary1 } = await loadFixture(deployVestingFixture);
      await vault.connect(admin).adminMintAndVest(beneficiary1.address, ethers.parseEther("1000"), ONE_YEAR, 0, false);

      await expect(
        vault.connect(beneficiary1).requestRevocation(0)
      ).to.be.revertedWithCustomError(vault, "ScheduleNotRevocable");
    });

    it("should allow beneficiary to request revocation and admin to approve", async function () {
      const { vault, vgmg, admin, beneficiary1 } = await loadFixture(deployVestingFixture);
      const vestAmount = ethers.parseEther("10000");
      const duration = 100 * ONE_DAY;

      await vault.connect(admin).adminMintAndVest(
        beneficiary1.address,
        vestAmount,
        duration,
        0,
        true
      );

      // Advance 40 days (40% vested = 4000 VGMG, 6000 unvested)
      await time.increase(40 * ONE_DAY);

      // 1. Beneficiary requests revocation
      await expect(vault.connect(beneficiary1).requestRevocation(0))
        .to.emit(vault, "RevocationRequested")
        .withArgs(0, beneficiary1.address, beneficiary1.address);

      const schedReq = await vault.getSchedule(0);
      expect(schedReq.revocationStatus).to.equal(1); // Requested

      // 2. Non-admin cannot approve
      await expect(
        vault.connect(beneficiary1).approveRevocation(0)
      ).to.be.revertedWithCustomError(vault, "Unauthorized");

      // 3. Admin approves revocation
      const adminBalanceBefore = await vgmg.balanceOf(admin.address);
      await vault.connect(admin).approveRevocation(0);
      const adminBalanceAfter = await vgmg.balanceOf(admin.address);

      // Admin was the funder, so unvested VGMG (approx 6,000) was refunded to admin
      const refunded = adminBalanceAfter - adminBalanceBefore;
      expect(refunded).to.be.closeTo(ethers.parseEther("6000"), ethers.parseEther("100"));

      // Unvested shares burned from beneficiary
      const remainingShares = await vault.balanceOf(beneficiary1.address);
      expect(remainingShares).to.be.closeTo(ethers.parseEther("4000"), ethers.parseEther("100"));

      // 4. Beneficiary can still claim the remaining vested tokens
      const releasable = await vault.releasableAmount(0);
      expect(releasable).to.equal(remainingShares);
      await vault.connect(beneficiary1).claimAll(0, beneficiary1.address);
      expect(await vault.balanceOf(beneficiary1.address)).to.equal(0);
    });

    it("should refund to beneficiary when user-funded schedule is revoked", async function () {
      const { vault, vgmg, admin, externalUser } = await loadFixture(deployVestingFixture);
      const vestAmount = ethers.parseEther("5000");

      await vgmg.connect(externalUser).approve(await vault.getAddress(), vestAmount);
      await vault.connect(externalUser).depositAndVest(vestAmount, 100 * ONE_DAY, 0, true);

      // Advance 50 days (50% = 2500 vested, 2500 unvested)
      await time.increase(50 * ONE_DAY);

      await vault.connect(externalUser).requestRevocation(0);

      const beforeBalance = await vgmg.balanceOf(externalUser.address);
      await vault.connect(admin).approveRevocation(0);
      const afterBalance = await vgmg.balanceOf(externalUser.address);

      // User funded it, so user received the unvested refund
      expect(afterBalance - beforeBalance).to.be.closeTo(ethers.parseEther("2500"), ethers.parseEther("50"));
    });

    it("should allow admin to reject revocation request and allow schedule to continue", async function () {
      const { vault, admin, beneficiary1 } = await loadFixture(deployVestingFixture);
      await vault.connect(admin).adminMintAndVest(beneficiary1.address, ethers.parseEther("1000"), 100, 0, true);

      await vault.connect(beneficiary1).requestRevocation(0);

      await expect(vault.connect(admin).rejectRevocation(0, "Schedule must continue"))
        .to.emit(vault, "RevocationRejected")
        .withArgs(0, beneficiary1.address, admin.address, "Schedule must continue");

      const schedule = await vault.getSchedule(0);
      expect(schedule.revocationStatus).to.equal(0); // None / resumed
    });

    it("should allow beneficiary to cancel their pending revocation request", async function () {
      const { vault, admin, beneficiary1 } = await loadFixture(deployVestingFixture);
      await vault.connect(admin).adminMintAndVest(beneficiary1.address, ethers.parseEther("1000"), 100, 0, true);

      await vault.connect(beneficiary1).requestRevocation(0);
      await expect(vault.connect(beneficiary1).cancelRevocationRequest(0))
        .to.emit(vault, "RevocationCancelled")
        .withArgs(0, beneficiary1.address);

      const schedule = await vault.getSchedule(0);
      expect(schedule.revocationStatus).to.equal(0);
    });
  });

  // =========================================================================
  // 9. Pause & Emergency Recovery
  // =========================================================================
  describe("Pause & Emergency Token Recovery", function () {
    it("should pause and unpause operations", async function () {
      const { vault, pauser, externalUser } = await loadFixture(deployVestingFixture);

      await vault.connect(pauser).pause();
      expect(await vault.paused()).to.be.true;

      await expect(
        vault.connect(externalUser).depositAndVest(ethers.parseEther("100"), 100, 0, true)
      ).to.be.revertedWithCustomError(vault, "EnforcedPause");

      await vault.connect(pauser).unpause();
      expect(await vault.paused()).to.be.false;
    });

    it("should prevent recovering underlying VGMG tokens", async function () {
      const { vault, vgmg, admin } = await loadFixture(deployVestingFixture);

      await expect(
        vault.connect(admin).recoverERC20(await vgmg.getAddress(), admin.address, 100)
      ).to.be.revertedWithCustomError(vault, "CannotRecoverVestingAsset");
    });

    it("should allow recovering other ERC20 tokens sent by accident", async function () {
      const { vault, admin } = await loadFixture(deployVestingFixture);

      // Deploy mock token
      const MockERC20 = await ethers.getContractFactory("MockERC20Stablecoin");
      const mockToken = await MockERC20.deploy("Random Token", "RND", 18);
      await mockToken.waitForDeployment();

      // Send 500 tokens to vault
      await mockToken.mint(await vault.getAddress(), ethers.parseEther("500"));

      await expect(
        vault.connect(admin).recoverERC20(await mockToken.getAddress(), admin.address, ethers.parseEther("500"))
      )
        .to.emit(vault, "EmergencyTokenRecovered")
        .withArgs(await mockToken.getAddress(), admin.address, ethers.parseEther("500"));

      expect(await mockToken.balanceOf(admin.address)).to.equal(ethers.parseEther("500"));
    });
  });
});
