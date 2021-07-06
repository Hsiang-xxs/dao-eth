const { expect } = require("chai");
const { BigNumber } = require("ethers");
const { parseEther } = require("ethers/lib/utils");
const { expectRevert, time } = require("@openzeppelin/test-helpers");
const { ethers } = require("hardhat");
const ETHABI = require("./ETH.json");

describe("Anti IL ETH", function () {
  let vault;
  let strategy;
  let richGuyAddr = "0x6f501562d279c70644b77f0342422a456f948acf";
  let treasuryAddr = "0x59E83877bD248cBFe392dbB5A8a29959bcb48592"; // Treasury wallet
  let communityAddr = "0xdd6c35aFF646B2fB7d8A8955Ccbe0994409348d0"; // Community wallet
  let adminAddr = "0x3f68A3c1023d736D8Be867CA49Cb18c543373B99"; // Admin
  let strategistAddr = "0x54D003d451c973AD7693F825D5b78Adfc0efe934"; // Strategist

  let tempAdminAddr;
  let tempAdmin;

  let richGuy;
  let treasury;
  let community;
  let admin;
  let strategist;

  const formatEther = (bigNumber) =>
    ethers.utils.formatEther(bigNumber.toString());

  const startImpersonate = async (address) => {
    await hre.network.provider.request({
      method: "hardhat_impersonateAccount",
      params: [address],
    });
    return await ethers.provider.getSigner(richGuyAddr);
  };

  const stopImpersonate = async (address) => {
    await hre.network.provider.request({
      method: "hardhat_stopImpersonatingAccount",
      params: [address],
    });
  };

  before(async function () {
    // console.log("🚀 | ETHABI", ETHABI);
    // runs once before the first test in this block

    richGuy = await startImpersonate(richGuyAddr);
    // treasury = await startImpersonate(treasuryAddr);
    // community = await startImpersonate(communityAddr);
    // strategist = await startImpersonate(strategistAddr);

    ETHToken = await new ethers.Contract(
      "0x2170Ed0880ac9A755fd29B2688956BD959F933F8",
      ETHABI,
      richGuy
    );

    [deployer, tempAdmin] = await ethers.getSigners();

    // Deploy LogicOne Implementation and assign its address to a Proxy Contract
    const Strategy = await ethers.getContractFactory("Strategy");
    strategy = await Strategy.deploy(
      communityAddr, // Community wallet
      strategistAddr, // Strategist
      tempAdmin.address // Admin
    );
    console.log("Strategy Deployed at", strategy.address);

    // Deploy LogicOne Implementation and assign its address to a Proxy Contract
    const Vault = await ethers.getContractFactory("Vault");
    vault = await Vault.deploy(
      strategy.address,
      treasuryAddr, // Treasury wallet
      communityAddr, // Community wallet
      strategistAddr, // Strategist
      tempAdmin.address // Admin
    );

    console.log("Vault Deployed at", vault.address);

    tx = await strategy.setVault(vault.address);
    tx.wait();

    const vaultPool = await vault.getVaultPool();
    console.log("🚀 | vaultPool", vaultPool.toString(), "ETH");
    const strategyPool = await strategy.getStrategyPool();
    console.log("🚀 | strategyPool", strategyPool.toString(), "ETH");
    const priceETH_BETH = await strategy["_calcPriceETH_BETH_LP"]();
    console.log("🚀 | priceETH_BETH", priceETH_BETH.toString());
    const priceETH_ANYETH = await strategy["_calcPriceETH_ANYETH_LP"]();
    console.log("🚀 | priceETH_ANYETH", priceETH_ANYETH.toString());
  });

  describe("Deployment", async function () {
    it("deposit", async function () {
      const _vaultContract = vault.connect(richGuy);
      const balanceBefore = await ETHToken.balanceOf(richGuyAddr);
      const depositAmount = ethers.utils.parseUnits("1.0", "ether");
      console.log("🚀 | balanceBefore", formatEther(balanceBefore), "ETH");

      tx = await ETHToken.approve(vault.address, balanceBefore);
      await tx.wait();
      tx = await _vaultContract.deposit(depositAmount);
      await tx.wait();

      const balanceAfter = await ETHToken.balanceOf(richGuyAddr);

      console.log("🚀 | balanceAfter", formatEther(balanceAfter), "ETH");
      console.log(
        "🚀 | balanceBefore - balanceAfter",
        balanceBefore.sub(balanceAfter)
      );

      const daoETHBalance = await vault.balanceOf(richGuyAddr);
      console.log("🚀 | daoETHBalance", formatEther(daoETHBalance));

      const totalPool = await vault.getTotalPool();
      console.log("🚀 | totalPool", formatEther(totalPool));

      expect(balanceBefore.sub(balanceAfter)).to.equal(depositAmount);
    });

    it("invest", async function () {
      //   admin = await startImpersonate(adminAddr);
      const _vaultContract = vault.connect(tempAdmin);

      const balanceBefore = await ETHToken.balanceOf(vault.address);
      console.log(
        "🚀 | Vault balanceBefore",
        formatEther(balanceBefore),
        "ETH"
      );

      tx = await _vaultContract.invest();
      await tx.wait();

      const balanceAfter = await ETHToken.balanceOf(vault.address);
      console.log("🚀 | Vault balanceAfter", formatEther(balanceAfter), "ETH");
      console.log(
        "🚀 | balanceBefore - balanceAfter",
        balanceBefore.sub(balanceAfter)
      );

      const vaultPool = await vault.getVaultPool();
      console.log("🚀 | vaultPool", formatEther(vaultPool), "ETH");
      const strategyPool = await strategy.getStrategyPool();
      console.log("🚀 | strategyPool", formatEther(strategyPool), "ETH");
      const totalPool = await vault.getTotalPool();
      console.log("🚀 | totalPool", formatEther(totalPool));

      expect(balanceAfter.lt(balanceBefore)).to.equal(true);
      const latestBlock = await ethers.provider.getBlockNumber();
      await time.advanceBlockTo(latestBlock + 20000);
    });

    it("yield", async function () {
      //   admin = await startImpersonate(adminAddr);
      const _vaultContract = vault.connect(tempAdmin);
      tx = await _vaultContract.yield();
      await tx.wait();

      const vaultPool = await vault.getVaultPool();
      console.log("🚀 | vaultPool", formatEther(vaultPool), "ETH");
      const strategyPool = await strategy.getStrategyPool();
      console.log("🚀 | strategyPool", formatEther(strategyPool), "ETH");
      const totalPool = await vault.getTotalPool();
      console.log("🚀 | totalPool", formatEther(totalPool));
      const totalWaultYield = await strategy.totalWaultYield();
      console.log("🚀 | totalWaultYield", formatEther(totalWaultYield));
      const totalNerveYield = await strategy.totalNerveYield();
      console.log("🚀 | totalNerveYield", formatEther(totalNerveYield));

      const latestBlock = await ethers.provider.getBlockNumber();
      await time.advanceBlockTo(latestBlock + 20000);
    });

    it("withdraw", async function () {
      // Deploy LogicOne Implementation and assign its address to a Proxy Contract
      const _vaultContract = vault.connect(richGuy);
      const balanceBefore = await ETHToken.balanceOf(richGuyAddr);
      const withdrawAmount = await vault.balanceOf(richGuyAddr);
      console.log("🚀 | balanceBefore", formatEther(balanceBefore), "ETH");
      console.log("🚀 | withdrawAmount", withdrawAmount);

      tx = await _vaultContract.withdraw(withdrawAmount);
      await tx.wait();

      const balanceAfter = await ETHToken.balanceOf(richGuyAddr);
      console.log("🚀 | balanceAfter", formatEther(balanceAfter), "ETH");
      const balanceDelta = balanceAfter - balanceBefore;
      console.log("🚀 | it | balanceDelta", balanceDelta);
      const vaultPool = await vault.getVaultPool();
      console.log("🚀 | vaultPool", formatEther(vaultPool), "ETH");
      const strategyPool = await strategy.getStrategyPool();
      console.log("🚀 | strategyPool", formatEther(strategyPool), "ETH");
      const totalPool = await vault.getTotalPool();
      console.log("🚀 | totalPool", formatEther(totalPool));
      expect(balanceAfter.gt(balanceBefore)).to.equal(true);
    });
  });
});
