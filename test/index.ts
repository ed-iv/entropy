import { expect } from "chai";
import { ethers, } from "hardhat";
import { Entropy } from "../typechain";
import "hardhat-gas-reporter";
import { BigNumber, Contract, Signer } from "ethers";
import { Provider } from "@ethersproject/abstract-provider";

const getNow = () => Math.ceil(Date.now() / 1000);
let owner: Signer, minter: Signer, buyer1: Signer, buyer2: Signer, entropy: Entropy;
const startPrice = BigNumber.from(10).pow(18).div(2); // .5 ETH
const ONE_HOUR = 60 * 60;
const ONE_DAY = 24 * 60 * 60;

describe("Entropy Auctions", function () {

  
  const deploy = async (user: Signer | Provider): Promise<Entropy> => {
    const Entropy = await ethers.getContractFactory("Entropy");
    entropy = (await Entropy.deploy(ethers.constants.AddressZero)).connect(user);
    return entropy as Entropy;
  }
  

  beforeEach( async () => {
    [owner, minter, buyer1, buyer2] = await ethers.getSigners();
  });

  it("Allows auctioneer to start auctions for specific deck & generation.", async function () {
    const entropy = await deploy(owner);
    let auction1 = await entropy._auctions(0);
    let auction2 = await entropy._auctions(2);
    await expect(auction1.startPrice).to.be.eq(0);
    await expect(auction2.startPrice).to.be.eq(0);
    const startTime = getNow() - ONE_HOUR;    
    // Can't start w/ deck = 0 or deck > 50
    await expect(entropy.createAuction(0, startPrice, startTime, ethers.constants.AddressZero))
      .to.be.revertedWith('InvalidDeck()');
    await expect(entropy.createAuction(51, startPrice, startTime, ethers.constants.AddressZero))
      .to.be.revertedWith('InvalidDeck()');
    // Can create auction w/ valid deck#        
    await expect(entropy.createAuction(50, startPrice, startTime, ethers.constants.AddressZero))
      .not.to.be.reverted;      
    await expect(entropy.createAuction(1, startPrice, startTime, ethers.constants.AddressZero))
      .not.to.be.reverted;      
    // Verify auction creation
    auction1 = await entropy._auctions(0);
    auction2 = await entropy._auctions(2);
    await expect(auction1.startPrice).to.be.eq(startPrice);
    await expect(auction2.startPrice).to.be.eq(0);
  });

  it("Allows auctioneer to start auctions for entire generation.", async function () {
    const entropy = await deploy(owner);
    await expect(entropy.ownerOf(0)).to.be.revertedWith("ERC721: owner query for nonexistent token");
    let auction = await entropy._auctions(0);
    await expect(auction.startPrice).to.be.eq(0);
    const startTime = getNow() - ONE_HOUR;
    await expect(entropy.createAuctionForGeneration(0, startPrice, startTime))
      .to.be.revertedWith('InvalidGeneration()');
    await expect(entropy.createAuctionForGeneration(1, startPrice, startTime))
      .not.to.be.reverted;      
    auction = await entropy._auctions(0);
    await expect(auction.startPrice).to.be.eq(startPrice);

  });

  it("Allows user to make purchase on running auction", async function () {
    const entropy = await deploy(buyer1);
    const startTime = getNow() - ONE_HOUR;
    
    await expect(
      entropy.connect(owner).createAuctionForGeneration(1, startPrice, startTime)
    ).not.to.be.reverted;      
    await expect(entropy.ownerOf(0)).to.be.revertedWith("ERC721: owner query for nonexistent token");
    await expect(await entropy.balanceOf(await buyer1.getAddress())).to.eq(0);
    await expect(entropy.purchaseCard(0)).to.be.revertedWith('InsufficientFunds()');
    await expect(entropy.purchaseCard(0, {value: startPrice})).not.to.be.reverted;
    await expect(await entropy.balanceOf(await buyer1.getAddress())).to.eq(1);

    const block = await ethers.provider.getBlockNumber();
    const events = await entropy.queryFilter(
      entropy.filters.CardPurchased(
        null,
        null,
        null,
        null,        
      ),
      block
    );
    expect(events.length).eq(1);
    const eventDetails = entropy.interface.parseLog(events[0]);
    expect(eventDetails.name).to.eq("CardPurchased");
    expect(eventDetails.args.auctionId).to.eq(0);
    expect(eventDetails.args.purchaser).to.eq(await buyer1.getAddress());
    expect(eventDetails.args.deck).to.eq(1);
    expect(eventDetails.args.generation).to.eq(1);
  });

  it("Allows auctioneer to settle purchase", async function () {        
    // await entropy.connect(owner).settleAuction(0, startPrice, 'foo');
    expect(await entropy.balanceOf(await buyer1.getAddress())).to.eq(1);
    expect(await entropy.ownerOf(0)).to.be.eq(await buyer1.getAddress())
    // expect(await entropy.tokenURI(0)).to.be.eq('ipfs://foo');

    const block = await ethers.provider.getBlockNumber();

    const creationEvents = await entropy.queryFilter(
      entropy.filters.AuctionCreated(
        null,
        null,
        null,
        null,        
      ),
      block
    );

    expect(creationEvents.length).eq(1);
    let eventDetails = entropy.interface.parseLog(creationEvents[0]);
    expect(eventDetails.name).to.eq("AuctionCreated");
    expect(eventDetails.args.auctionId).to.eq(50);
    expect(eventDetails.args.creator).to.eq(await buyer1.getAddress());
    expect(eventDetails.args.deck).to.eq(1);
    expect(eventDetails.args.generation).to.eq(2); 
  });

  it("Allows chain purchases", async function () {        
    // Make sure random buyer can't execute a chain purchase.    
    await expect(
      entropy.connect(buyer2).purchaseCard(50, {value: startPrice})
    ).to.be.revertedWith('AuctionNotStarted()');

    await expect((await entropy._auctions(50)).purchaser).to.eq(ethers.constants.AddressZero);
    await expect(
      entropy.purchaseCard(50, {value: startPrice})
    ).not.to.be.reverted;
    await expect((await entropy._auctions(50)).startTime).to.eq(0);
    await expect(await (await entropy._auctions(51)).prevPurchaser).to.eq(await buyer1.getAddress());

  });
});
