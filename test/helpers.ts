import { expect } from "chai";
import { ethers } from "hardhat";
import { Entropy } from "../typechain";
import "hardhat-gas-reporter";
import fs from "fs";
import { BigNumber, Signer } from "ethers";
import { start } from "repl";

const BASE_PRICE = ethers.utils.parseEther("1");
const BASE_CONSTANT = ethers.utils.parseEther("0.5");

interface Card {
  deck: number;
  generation: number;
  rarity: number;
}

let buyer1: Signer, owner: Signer;
let changeBalance: BigNumber;

const getNow = () => Math.ceil(Date.now() / 1000);

describe("Internal Helpers", function () {
  let entropy: Entropy;
  const rarityKey: number[][] = [[]];
  let cards: Card[];
  let rarity: number[];

  before(async () => {
    const rawData = fs.readFileSync("test/data/rarity.json");
    [buyer1, owner] = await ethers.getSigners();
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
    entropy = await Entropy.deploy();
    await entropy.setRarity(rarity);
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
    await expect(entropy.getRarity(1, 0)).to.be.revertedWith(
      "InvalidGeneration"
    );
    await expect(entropy.getRarity(1, 61)).to.be.revertedWith(
      "InvalidGeneration"
    );
  });

  it("Can get current price of card for a listing", async () => {
    const startTime = getNow();
    // Advance timestamp by 2 hours:
    const cardRarity = rarityKey[1][1];
    await expect(entropy.listCard(1, 1, startTime)).not.to.be.reverted;

    const DURATION = BigNumber.from(86400); // 24 hours
    
    const BASE_PRICE = ethers.utils.parseEther("1");
    const BASE_CONSTANT = ethers.utils.parseEther("0.5");

    const startPrice = BigNumber.from(cardRarity - 1)
      .mul(BASE_PRICE)
      .div(BigNumber.from(9))
      .add(BASE_CONSTANT);
      
    const minPrice = startPrice.div(BigNumber.from(10));
    const discountRate = startPrice.sub(minPrice).div(DURATION);

    // Test price in 2 hours
    let discount = discountRate.mul(BigNumber.from(7200));
    let expectedPrice = startPrice.sub(discount);

    await ethers.provider.send("evm_setNextBlockTimestamp", [startTime + 7200]);
    await ethers.provider.send("evm_mine", []);

    let price = await entropy.getPrice(1, 1, startTime);
    expect(ethers.utils.formatEther(price)).to.be.eq(
      ethers.utils.formatEther(expectedPrice)
    );

    // Test price in 4.5 hours
    discount = discountRate.mul(BigNumber.from(16200));
    expectedPrice = startPrice.sub(discount);

    await ethers.provider.send("evm_setNextBlockTimestamp", [
      startTime + 16200,
    ]);
    await ethers.provider.send("evm_mine", []);

    price = await entropy.getPrice(1, 1, startTime);
    expect(ethers.utils.formatEther(price)).to.be.eq(
      ethers.utils.formatEther(expectedPrice)
    );

    // Test price once minimum price has been reached (25 hrs after start time)
    expectedPrice = startPrice.div(BigNumber.from(10)); // min price

    await ethers.provider.send("evm_setNextBlockTimestamp", [
      startTime + 90000,
    ]);
    await ethers.provider.send("evm_mine", []);

    price = await entropy.getPrice(1, 1, startTime);
    expect(ethers.utils.formatEther(price)).to.be.eq(
      ethers.utils.formatEther(expectedPrice)
    );
  });

  it("Check the refund success when purchase the price after 27 hrs", async () => {
    const startTime = getNow();
    const initialPrice = BigNumber.from(10).pow(18).mul(2); // 2 ETH
    await ethers.provider.send("evm_setNextBlockTimestamp", [
      startTime + 90000 + 7200,
    ]);
    await ethers.provider.send("evm_mine", []);

    const price = await entropy.getPrice(1, 1, startTime);
    changeBalance = price;
    await expect(
      await entropy.connect(buyer1).purchaseCard(1, 1, { value: initialPrice })
    ).to.changeEtherBalance(entropy, price);
  });
  it("Withdraw token to the specific address", async () => {
    const ownerBalance = await owner.getBalance();
    await expect(entropy.withdraw(await owner.getAddress())).not.to.be.reverted;
    expect(await owner.getBalance()).to.equal(ownerBalance.add(changeBalance));
  });
});
