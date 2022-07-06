import * as dotenv from "dotenv";
import { ethers } from "hardhat";
import fs from 'fs';
dotenv.config();

interface Card {
  deck: number;
  generation: number;
  rarity: number;
}

async function main() {  
  
  let cards: Card[];    
  const rawData = fs.readFileSync('test/data/rarity.json');
  cards = JSON.parse(rawData.toString());    
  const rarity: number[] = cards.map(c => c.rarity);    

  const Entropy = await ethers.getContractFactory("Entropy");
  const entropy = await Entropy.deploy("https://entropycards.fun/meta");
  await entropy.deployed();
  await entropy.setRarity(rarity);
  console.log("Entropy Contract Deployed:", entropy.address);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
