import { expect } from "chai";
import { ethers, } from "hardhat";
import { ExposedInternals } from "../typechain";
import "hardhat-gas-reporter";
import fs from 'fs';

interface Card {
  deck: number;
  generation: number;
  rarity: number;
}
describe("Internal Helpers", function () {  
  let entropy: ExposedInternals;
  let rarityKey: number[][] = [[]];
  let cards: Card[];    
  let rarity: number[];

  before(async () => {  
    const rawData = fs.readFileSync('test/data/rarity.json');
    cards = JSON.parse(rawData.toString());  
    cards.forEach(c => {
      if (rarityKey[c.deck] === undefined) {
        rarityKey[c.deck] = [];
      }
      rarityKey[c.deck][c.generation] = c.rarity;      
    });        
    rarity = cards.map(c => c.rarity);    
    const ExposedInternals = await ethers.getContractFactory("ExposedInternals");    
    entropy = await ExposedInternals.deploy(rarity);    
  });

  it("Allows rarity to be set and indexed by deck, generation", async () => {    
    expect(await entropy._getRarity(1, 1)).to.be.eq(rarityKey[1][1]);    
    expect(await entropy._getRarity(50, 60)).to.be.eq(rarityKey[50][60]);    
    expect(await entropy._getRarity(23, 14)).to.be.eq(rarityKey[23][14]);    
    expect(await entropy._getRarity(12, 55)).to.be.eq(rarityKey[12][55]);    
    expect(await entropy._getRarity(37, 18)).to.be.eq(rarityKey[37][18]);    
  });

  it("Reverts when checking rarity with invalid deck and/or generation", async () => {     
    await expect(entropy._getRarity(0, 1)).to.be.revertedWith('InvalidDeck');
    await expect(entropy._getRarity(51, 1)).to.be.revertedWith('InvalidDeck');    
    await expect(entropy._getRarity(51, 0)).to.be.revertedWith('InvalidDeck');    
    await expect(entropy._getRarity(51, 61)).to.be.revertedWith('InvalidDeck');    
    await expect(entropy._getRarity(1, 0)).to.be.revertedWith('InvalidGeneration');    
    await expect(entropy._getRarity(1, 61)).to.be.revertedWith('InvalidGeneration');    
  });


});
