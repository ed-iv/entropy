import * as dotenv from "dotenv";
import { ethers } from "hardhat";


dotenv.config();

async function main() {
  const Entropy = await ethers.getContractFactory("Entropy");
  const entropy = await Entropy.deploy(process.env.MINTER_ADDRESS!);

  await entropy.deployed();
  console.log("Entropy Contract Deployed:", entropy.address);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
