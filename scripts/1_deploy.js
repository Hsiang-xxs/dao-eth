const { ethers } = require("hardhat");

async function main() {
  let tx, receipt, totalGasUsed;
  const [deployer] = await ethers.getSigners();
  const Strategy = await ethers.getContractFactory("Strategy");
  const strategy = await Strategy.deploy(
    "0xdd6c35aFF646B2fB7d8A8955Ccbe0994409348d0", // Community wallet
    "0x54D003d451c973AD7693F825D5b78Adfc0efe934", // Strategist
    "0x3f68A3c1023d736D8Be867CA49Cb18c543373B99" // Admin
  );
  //   receipt = await strategy.deployTransaction.wait();
  //   totalGasUsed = new ethers.BigNumber.from(receipt.gasUsed.toString());

  //   const Vault = await ethers.getContractFactory("Vault", deployer);
  //   const vault = await Vault.deploy(
  //     strategy.address,
  // "0x59E83877bD248cBFe392dbB5A8a29959bcb48592", // Treasury wallet
  // "0xdd6c35aFF646B2fB7d8A8955Ccbe0994409348d0", // Community wallet
  // "0x3f68A3c1023d736D8Be867CA49Cb18c543373B99", // Admin
  // "0x54D003d451c973AD7693F825D5b78Adfc0efe934" // Strategist
  //   );
  //   receipt = await vault.deployTransaction.wait();
  //   totalGasUsed = totalGasUsed.add(receipt.gasUsed.toString());

  //   tx = await strategy.setVault(vault.address);
  //   receipt = await tx.wait();
  //   totalGasUsed = totalGasUsed.add(receipt.gasUsed.toString());

  //   const res = await axios.get(
  //     `https://api.bscscan.com/api?module=proxy&action=eth_gasPrice&apikey=${process.env.ETHERSCAN_API_KEY}`
  //   );
  //   const proposeGasPriceInGwei = ethers.BigNumber.from(
  //     res.data.result.ProposeGasPrice
  //   ); // Can choose between SafeGasPrice, ProposeGasPrice and FastGasPrice
  //   const proposeGasPrice = proposeGasPriceInGwei.mul("1000000000");
  //   //   const deployerMainnet = new ethers.Wallet(process.env.PRIVATE_KEY);
  //   //   const deployerBalance = await ethers.provider.getBalance(deployerMainnet.address);

  //   console.log("Estimated gas used:", totalGasUsed.toString());
  //   console.log(`Estimated gas price(Etherscan): ${proposeGasPriceInGwei} Gwei`);
  //   console.log(
  //     `Estimated deployment fee: ${ethers.utils.formatEther(
  //       totalGasUsed.mul(proposeGasPrice)
  //     )} ETH`
  //   );
  //   //   console.log(`Your balance: ${ethers.utils.formatEther(deployerBalance)} ETH`);
  //   console.log("Please make sure you have enough ETH before deploy.");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
