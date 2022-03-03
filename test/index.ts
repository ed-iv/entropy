import { expect } from "chai";
import { ethers } from "hardhat";
import { Entropy } from "../typechain";
import "hardhat-gas-reporter";
import { Signer } from "ethers";
import { Provider } from "@ethersproject/abstract-provider";


describe("Entropy", function () {

  let owner: Signer, minter: Signer, somebody: Signer, entropy: Entropy;

  before( async () => {
    [owner, minter, somebody] = await ethers.getSigners();
  });

  beforeEach(async () => {
    const Entropy = await ethers.getContractFactory("Entropy");
    entropy = await Entropy.deploy(ethers.constants.AddressZero);
    await entropy.deployed();
  });

  it("Should allow admin to create auctions for an entire generation.", async function () {
    await expect(entropy.ownerOf(0)).to.be.revertedWith("ERC721: owner query for nonexistent token");
    

  });
});
