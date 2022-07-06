import { expect } from "chai";
import { ethers } from "hardhat";
import { Entropy } from "../typechain";
import "hardhat-gas-reporter";
import fs from "fs";
import { BigNumber, Signer } from "ethers";
import { start } from "repl";

const BASE_PRICE = ethers.utils.parseEther("1");
const BASE_CONSTANT = ethers.utils.parseEther("0.5");
const LISTER = '0x123dd8e2e33abc176f4930d6a95bd73c318b9cc6e5fd817449cfc3764544baf1';

const jumpToTimestamp = async (provider: any, timeStamp: number) => {
  await provider.send("evm_setNextBlockTimestamp", [timeStamp]);
  await provider.send("evm_mine", []);
}

interface Card {
  deck: number;
  generation: number;
  rarity: number;
}

let owner: Signer, beneficiary: Signer, lister: Signer, buyer1: Signer, rando: Signer;
let changeBalance: BigNumber;

const getNow = () => Math.ceil(Date.now() / 1000);

describe("Internal Helpers", function () {
  let entropy: Entropy;
  const rarityKey: number[][] = [[]];
  let cards: Card[];
  let rarity: number[];

  before(async () => {
    const rawData = fs.readFileSync("test/data/rarity.json");
    [owner, beneficiary, lister, buyer1, rando] = await ethers.getSigners();
    cards = JSON.parse(rawData.toString());
    cards.forEach((c) => {
      if (rarityKey[c.deck] === undefined) {
        rarityKey[c.deck] = [];
      }
      rarityKey[c.deck][c.generation] = c.rarity;
    });
    rarity = cards.map((c) => c.rarity);
    const Entropy = await ethers.getContractFactory(
      "Entropy"
    );
    entropy = await Entropy.deploy("foo");
    await entropy.setRarity(rarity);
    await entropy.grantRole(LISTER, await lister.getAddress());
  });

  it("Allows rarity to be set and indexed by deck, generation", async () => {
    expect(await entropy.getRarity(1, 1)).to.be.eq(rarityKey[1][1]);
    expect(await entropy.getRarity(50, 60)).to.be.eq(rarityKey[50][60]);
    expect(await entropy.getRarity(23, 14)).to.be.eq(rarityKey[23][14]);
    expect(await entropy.getRarity(12, 55)).to.be.eq(rarityKey[12][55]);
    expect(await entropy.getRarity(37, 18)).to.be.eq(rarityKey[37][18]);
  });

  it("Reverts when checking rarity with invalid deck and/or generation", async () => {
    await expect(entropy.getRarity(0, 1)).to.be.revertedWith("InvalidDeck");
    await expect(entropy.getRarity(51, 1)).to.be.revertedWith("InvalidDeck");
    await expect(entropy.getRarity(51, 0)).to.be.revertedWith("InvalidDeck");
    await expect(entropy.getRarity(51, 61)).to.be.revertedWith("InvalidDeck");
    await expect(entropy.getRarity(1, 0)).to.be.revertedWith("InvalidGeneration");
    await expect(entropy.getRarity(1, 61)).to.be.revertedWith("InvalidGeneration");
  });

  it("Can get current price of card for a listing", async () => {
    const startTime = getNow() + 7200; // starts in 2 hours
    const cardRarity = rarityKey[1][1];
    const DURATION = BigNumber.from(86400); // 24 hours
    let price: BigNumber, expectedPrice: BigNumber, discount: BigNumber;
    
    // List card with auction starting now.
    await expect(entropy.listCard(1, 1, startTime)).not.to.be.reverted;
  
    const startPrice = BigNumber.from(cardRarity - 1)
      .mul(BASE_PRICE)
      .div(BigNumber.from(9))
      .add(BASE_CONSTANT);
      
    const minPrice = startPrice.div(BigNumber.from(10));
    const discountRate = startPrice.sub(minPrice).div(DURATION);

    await jumpToTimestamp(ethers.provider, startTime);
    price = await entropy.getPrice(1, 1);
    expect(ethers.utils.formatEther(price)).to.be.eq(
      ethers.utils.formatEther(startPrice)
    );  

    // Test price ~2 hours from start
    discount = discountRate.mul(BigNumber.from(7263));
    expectedPrice = startPrice.sub(discount);

    await jumpToTimestamp(ethers.provider, startTime + 7263);    

    price = await entropy.getPrice(1, 1);
    expect(ethers.utils.formatEther(price)).to.be.eq(
      ethers.utils.formatEther(expectedPrice)
    );

    // Test price ~4.5 hours from start
    discount = discountRate.mul(BigNumber.from(16280));
    expectedPrice = startPrice.sub(discount);

    await jumpToTimestamp(ethers.provider, startTime + 16280);   
    
    price = await entropy.getPrice(1, 1);
    expect(ethers.utils.formatEther(price)).to.be.eq(
      ethers.utils.formatEther(expectedPrice)
    );

    // Test price once minimum price has been reached (25 hrs after start time)
    expectedPrice = startPrice.div(BigNumber.from(10)); // min price
    await jumpToTimestamp(ethers.provider, startTime + 90000); 

    price = await entropy.getPrice(1, 1);
    expect(ethers.utils.formatEther(price)).to.be.eq(
      ethers.utils.formatEther(expectedPrice)
    );
  });

  it("Check the refund success when purchase the price after 27 hrs", async () => {
    const startTime = getNow() + 7200;
    const initialPrice = BigNumber.from(10).pow(18).mul(2); // 2 ETH
    await jumpToTimestamp(ethers.provider, startTime + 90000 + 7200); 
  
    const price = await entropy.getPrice(1, 1);
    changeBalance = price;
    await expect(
      await entropy.connect(buyer1).purchaseCard(1, 1, { value: initialPrice })
    ).to.changeEtherBalance(entropy, price);
  });

  it("Reverts if lister or rando tries to withdraw", async () => {    
    expect(await entropy.hasRole(LISTER, await lister.getAddress())).to.be.eq(true);
    expect(await entropy.hasRole(LISTER, await buyer1.getAddress())).to.be.eq(false);
    await expect(entropy.connect(lister).withdraw(await owner.getAddress())).to.be.revertedWith('Unauthorized()');    
    await expect(entropy.connect(buyer1).withdraw(await owner.getAddress())).to.be.revertedWith('Unauthorized()');    
  });

  it("Allows owner to withdraw balance to the specific address", async () => {
    const originalBalance = await beneficiary.getBalance();
    await expect(entropy.withdraw(await beneficiary.getAddress())).not.to.be.reverted;
    const newBalance = await beneficiary.getBalance()
    expect(newBalance).not.to.eq(originalBalance)
    expect(newBalance).to.equal(originalBalance.add(changeBalance));
  });

  it("Reverts if unauthorized user tries to burn token", async() => {
    const buyerAddress = await buyer1.getAddress();
    expect(await entropy.ownerOf(1)).to.be.eq(buyerAddress);
    expect(await entropy.balanceOf(buyerAddress)).to.be.eq(1);
    await expect(entropy.burn(1)).to.be.revertedWith('ERC721: transfer caller is not owner nor approved');
    expect(await entropy.balanceOf(buyerAddress)).to.be.eq(1);
  });

  it("Allows owner to burn their token", async() => {
    const buyerAddress = await buyer1.getAddress();
    expect(await entropy.ownerOf(1)).to.be.eq(buyerAddress);
    expect(await entropy.balanceOf(buyerAddress)).to.be.eq(1);
    await expect(entropy.connect(buyer1).burn(1)).not.to.be.reverted;
    await expect(entropy.ownerOf(1)).to.be.revertedWith('ERC721: owner query for nonexistent token');
    expect(await entropy.balanceOf(buyerAddress)).to.be.eq(0);
  });
});
