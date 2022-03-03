// contracts/Entropy.sol
// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity 0.8.4;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "hardhat/console.sol";

error Unauthorized();
error AuctionNotStarted();
error AuctionStillInProgress();
error AuctionDoesNotExist();
error AuctionHasEnded();
error DeckDoesNotExist();
error MaxGenerationsExceeded();
error InsufficientFunds();
error EthTransferFailed();

struct Auction {    
    uint256 startPrice;    
    uint8 deck;
    uint8 generation;    
    uint256 startTime;
    address purchaser;
    address prevPurchaser;
}

struct Deck { uint8 generation; }

contract Entropy is ERC721URIStorage, AccessControl, ReentrancyGuard {    
    uint256 public _auctionDuration = 7200; // seconds
    uint256 public _chainPurchaseWindow = 3600; // seconds
    uint8 public _chainPurchaseDiscount = 25; // percent
    uint16 public _nextAuctionId;
    mapping(uint16 => Auction) public _auctions;
    
    bytes32 public constant OWNER_ROLE = keccak256("OWNER_ROLE");
    bytes32 public constant AUCTIONEER_ROLE = keccak256("AUCTIONEER_ROLE");
    uint8 public constant MAX_DECKS = 50;
    uint8 public constant MAX_GENERATIONS = 60;

    string public _baseTokenURI = "ipfs://";            
    uint16 private _nextTokenId;
    mapping(uint8 => Deck) public _decks;
    
    event AuctionEnded(address who, uint256 tokenId);
    event CardMinted(uint256 tokenId, uint8 deck);
    event AuctionCreated(uint16 indexed auctionId, address indexed creator, uint8 indexed deck, uint8 generation);
    event CardPurchased(uint16 indexed auctionId, address indexed purchaser, uint8 indexed deck, uint8 generation);    
    event SaleFinalized(uint16 indexed auctionId, address indexed purchaser, uint256 indexed tokenId, uint8 deck, uint8 generation);
    
    constructor(address minter) ERC721("Entropy", "ENTR") {      
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _setupRole(AUCTIONEER_ROLE, minter);
    }

    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC721, AccessControl) returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    function mintFromDeck(uint8 deck, address to, string memory tokenURI) public onlyRole(AUCTIONEER_ROLE) {
        uint256 tokenId = _nextTokenId++;
        _safeMint(to, tokenId);
        _setTokenURI(tokenId, tokenURI);
        _decks[deck].generation++;
    }

    function _baseURI() internal view virtual override returns (string memory) {
        return _baseTokenURI;
    }

    function setBaseURI(string calldata baseTokenURI) external onlyRole(OWNER_ROLE) {
        _baseTokenURI = baseTokenURI;
    }    

    function addMinter(address minter) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _grantRole(AUCTIONEER_ROLE, minter);
    }

    function removeMinter(address minter) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _revokeRole(AUCTIONEER_ROLE, minter);(AUCTIONEER_ROLE, minter);
    }
    
    function createAuction(uint8 deck, uint256 startPrice, uint256 startTime, address prevPurchaser) public onlyRole(AUCTIONEER_ROLE) {
        if (deck >= MAX_DECKS) revert DeckDoesNotExist();        
        uint8 generation = _decks[deck].generation;
        if (generation >= MAX_GENERATIONS) revert MaxGenerationsExceeded();
        _decks[deck].generation++;        
        uint16 auctionId = _nextAuctionId++;
        _auctions[auctionId] = Auction(
            startPrice,            
            deck,
            generation,
            startTime,            
            address(0),
            prevPurchaser
        );
        emit AuctionCreated(auctionId, msg.sender, deck, generation);
    }

    // TODO - Finer grained control
    /// @notice - Allows auctioneer to create auctions for a specified generation. Decks that have either
    /// exceeded or not advanced to this generation are ignored. This allows auctions to be created in bulk
    /// (for example on some release schedule) while allowing individual decks to advance at their own rates
    /// through chained purchases.
    function createAuctionForGeneration(uint8 generation, uint256 startPrice, uint256 startTime) public onlyRole(AUCTIONEER_ROLE) {
        for (uint8 i = 0; i < MAX_DECKS; i++) {
            if (_decks[i].generation == generation) {
                createAuction(i, startPrice, startTime, address(0));
            }
        }
    }

    /// @notice - Purchaser doesn't actually get NFT at this point (it isn't even minted). Rather, they are sort of 
    /// buying a claim to the token that will be fulfilled when settleAuction is called.
    function purchaseCard(uint16 auctionId) external payable nonReentrant {        
        Auction storage auction = _auctions[auctionId];
        bool isChainPurchase = false;        
        if (auction.startPrice == 0) revert AuctionDoesNotExist();
        if (auction.purchaser != address(0)) revert AuctionHasEnded();
        if (block.timestamp < auction.startTime) {
            if (auction.prevPurchaser == address(0) || msg.sender != auction.prevPurchaser) revert AuctionNotStarted();
            isChainPurchase = true;
        }
        uint256 price = isChainPurchase 
            ? _getChainPurchasePrice(auction.startPrice)
            : _getPurchasePrice(auction.startPrice, auction.startTime);
        if (msg.value < price) revert InsufficientFunds();        
        auction.purchaser = msg.sender;    
        uint256 refund = msg.value - price;
        if (refund > 0) {
            (bool sent, ) = payable(msg.sender).call{value: refund}("");
            if (!sent) revert EthTransferFailed();
        }     
        emit CardPurchased(auctionId, msg.sender, auction.deck, auction.generation);
    }

    /// @notice - This function is intended to be called by automated auctioneer account in response to CardPurchased activity
    /// being emitted. 
    function settleAuction(uint16 auctionId, uint256 nextStartPrice, string memory tokenURI) external onlyRole(AUCTIONEER_ROLE) {
        Auction storage auction = _auctions[auctionId];
        if (auction.startPrice == 0) revert AuctionDoesNotExist();
        if (auction.purchaser == address(0)) revert AuctionStillInProgress();
    
        address purchaser = auction.purchaser;
        uint256 tokenId = _nextTokenId++;
        _safeMint(purchaser, tokenId);
        _setTokenURI(tokenId, tokenURI);

        uint256 startTime = block.timestamp + _chainPurchaseWindow;
        createAuction(auction.deck, nextStartPrice, startTime, auction.purchaser);
        delete(_auctions[auctionId]);
        emit SaleFinalized(auctionId, purchaser, tokenId, auction.deck, auction.generation);                
    }

    function _getPurchasePrice(uint256 startPrice, uint256 startTime) public view returns (uint256) {                
        uint256 timeElapsed = block.timestamp - startTime;
        uint256 discountRate = startPrice / _auctionDuration;
        uint256 discount = discountRate * timeElapsed;
        uint256 price = startPrice - discount;
        uint256 minPrice = (startPrice * 10) / 100;
        return price >= minPrice ? price : minPrice;
    }

    function _getChainPurchasePrice(uint256 startPrice) private view returns (uint256) {
        uint256 discount = (startPrice * _chainPurchaseDiscount) / 100;
        return startPrice - discount;
    }

    function setAuctionDuration(uint256 auctionDuration) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _auctionDuration = auctionDuration;
    }

    function setChainPurchaseWindow(uint256 chainPurchaseWindow) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _chainPurchaseWindow = chainPurchaseWindow;
    }

    function setChainPurchaseDiscount(uint8 chainPurchaseDiscount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _chainPurchaseDiscount = chainPurchaseDiscount;
    }    
}