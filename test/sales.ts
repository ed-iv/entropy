import { expect } from "chai";
import { ethers } from "hardhat";
import { Entropy } from "../typechain";
import "hardhat-gas-reporter";
import { BigNumber, Contract, Signer } from "ethers";
import fs from "fs";

interface Card {
  deck: number;
  generation: number;
  rarity: number;
}

const getNow = () => Math.ceil(Date.now() / 1000);
let owner: Signer,
  minter: Signer,
  buyer1: Signer,
  buyer2: Signer,
  entropy: Entropy;
const startPrice = BigNumber.from(10).pow(18).mul(2); // 2 ETH
const ONE_HOUR = 60 * 60;
const ONE_DAY = 24 * 60 * 60;

describe("Entropy Card Listing & Sales", function () {
  before(async () => {
    const rarityKey: number[][] = [[]];
    const rawData = fs.readFileSync("test/data/rarity.json");
    const cards = JSON.parse(rawData.toString());
    cards.forEach((c: Card) => {
      if (rarityKey[c.deck] === undefined) {
        rarityKey[c.deck] = [];
      }
      rarityKey[c.deck][c.generation] = c.rarity;
    });
    const rarity = cards.map((c: any) => c.rarity);

    [owner, buyer1, buyer2] = await ethers.getSigners();
    const Entropy = await ethers.getContractFactory("Entropy");
    entropy = await Entropy.deploy(rarity);
    return entropy as Entropy;
  });

  it("Allows owner to start auctions for an entire generation", async () => {
    const startTime = getNow() - ONE_HOUR;
    let cardSale = await entropy._listings(1, 1);
    expect(cardSale.startTime).to.be.eq(0);
    await expect(entropy.listGeneration(1, startTime)).not.to.be.reverted;
    cardSale = await entropy._listings(1, 1);
    expect(cardSale.startTime).to.be.eq(startTime);

    const cardSale2 = await entropy._listings(1, 2);
    expect(cardSale2.startTime).to.be.eq(0);
  });

  it("Allows user to purchase card that is on sale.", async () => {
    await expect(await entropy.balanceOf(await buyer1.getAddress())).to.eq(0);
    await expect(entropy.ownerOf(1)).to.be.revertedWith(
      "ERC721: owner query for nonexistent token"
    );
    await expect(
      entropy.connect(buyer1).purchaseCard(1, 2, { value: startPrice })
    ).to.be.revertedWith("CardNotListed");
    await expect(
      entropy.connect(buyer1).purchaseCard(1, 1, { value: startPrice })
    )
      .to.emit(entropy, "CardPurchased")
      .withArgs(1, 1, 1, await buyer1.getAddress());
    await expect(await entropy.balanceOf(await buyer1.getAddress())).to.eq(1);
    expect(await entropy.ownerOf(1)).to.be.eq(await buyer1.getAddress());
    expect(await entropy.tokenURI(1)).to.be.eq("ipfs://foo/1.json");
  });

  it("Reverts when random user attempts chain purchase", async () => {
    await expect(
      entropy.connect(buyer2).purchaseCard(1, 2, { value: startPrice })
    ).to.be.revertedWith("Unauthorized");
  });

  it("Allows prev purchaser to make chain purchase", async () => {
    await expect(await entropy.balanceOf(await buyer1.getAddress())).to.eq(1);
    await expect(entropy.ownerOf(2)).to.be.revertedWith(
      "ERC721: owner query for nonexistent token"
    );
    await expect(
      entropy.connect(buyer1).purchaseCard(1, 2, { value: startPrice })
    )
      .to.emit(entropy, "CardPurchased")
      .withArgs(1, 2, 2, await buyer1.getAddress());
    await expect(await entropy.balanceOf(await buyer1.getAddress())).to.eq(2);
    expect(await entropy.ownerOf(2)).to.be.eq(await buyer1.getAddress());
    expect(await entropy.tokenURI(2)).to.be.eq("ipfs://foo/2.json");
  });

  it("Reverts when user tries to purchase card that has sold", async () => {
    await expect(
      entropy.connect(buyer1).purchaseCard(1, 1, { value: startPrice })
    ).to.be.revertedWith("CardSaleHasEnded");
  });

  it("Allows owner to start auctions for specific deck & generation.", async () => {
    const startTime = getNow() - ONE_HOUR;
    let cardSale = await entropy._listings(3, 5);
    expect(cardSale.startTime).to.be.eq(0);
    await expect(entropy.listCard(3, 5, startTime)).not.to.be.reverted;
    cardSale = await entropy._listings(3, 5);
    expect(cardSale.startTime).to.be.eq(startTime);
  });

  it("Allows user to purchase card that has been listed specifically", async () => {
    await expect(await entropy.balanceOf(await buyer2.getAddress())).to.eq(0);
    await expect(entropy.ownerOf(3)).to.be.revertedWith(
      "ERC721: owner query for nonexistent token"
    );
    await expect(
      entropy.connect(buyer2).purchaseCard(3, 5, { value: startPrice })
    )
      .to.emit(entropy, "CardPurchased")
      .withArgs(3, 5, 3, await buyer2.getAddress());
    await expect(await entropy.balanceOf(await buyer2.getAddress())).to.eq(1);
    expect(await entropy.ownerOf(3)).to.be.eq(await buyer2.getAddress());
    expect(await entropy.tokenURI(3)).to.be.eq("ipfs://foo/3.json");
  });

  it("Get the current purchase price", async () => {
    const startTime = getNow();
    await ethers.provider.send("evm_setNextBlockTimestamp", [startTime]);
    await ethers.provider.send("evm_mine", []);
    await expect(await entropy._price(1, 1, startTime)).to.be.eq(
      ethers.utils.parseEther("1.5")
    );
  });
});
