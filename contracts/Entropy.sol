// contracts/Entropy.sol
// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity 0.8.4;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

error Unauthorized();
error AuctionNotStarted(uint16 auctionId);
error AuctionStillInProgress();
error AuctionDoesNotExist(uint16 auctionId);
error AuctionHasEnded(uint16 auctionId);
error InvalidDeck(uint8 deck);
error InvalidGeneration();
error InsufficientFunds();
error EthTransferFailed();

struct Auction {    
    uint startPrice;    
    uint8 deck;
    uint8 generation;    
    uint32 startTime;
    address purchaser;
    uint16 tokenId;
    address prevPurchaser;
}

struct Deck { uint8 generation; }

contract Entropy is ERC721URIStorage, AccessControl, ReentrancyGuard {    
    uint24 public _auctionDuration = 7200; // seconds
    uint16 public _chainPurchaseWindow = 3600; // seconds
    uint8 public _chainPurchaseDiscount = 25; // percent
    uint16 public _nextAuctionId;
    mapping(uint16 => Auction) public _auctions;
    
    bytes32 public constant OWNER_ROLE = keccak256("OWNER_ROLE");
    bytes32 public constant AUCTIONEER_ROLE = keccak256("AUCTIONEER_ROLE");
    uint8 public constant MAX_DECKS = 50;
    uint8 public constant MAX_GENERATIONS = 60;
    uint8 public constant FIRST_DECK = 1;
    uint8 public constant FIRST_GEN = 1;

    string public _baseTokenURI = "ipfs://";            
    uint16 private _nextTokenId;
    mapping(uint8 => Deck) public _decks;
    
    event AuctionCreated(
        uint16 indexed auctionId, 
        address indexed creator, 
        uint8 indexed deck, 
        uint8 generation, 
        uint32 startTime,
        address prevPurchaser
    );    
    event CardPurchased(
        uint16 indexed auctionId, 
        uint16 tokenId, 
        address indexed purchaser, 
        uint8 indexed deck, 
        uint8 generation
    );    
    event SaleFinalized(uint16 indexed auctionId, address indexed purchaser, uint indexed tokenId, uint8 deck, uint8 generation);
    
    modifier onlyAuctioneer() {
        if (
            !hasRole(DEFAULT_ADMIN_ROLE, msg.sender) && 
            !hasRole(AUCTIONEER_ROLE, msg.sender)
        ) revert Unauthorized();            
        _;
    }

    constructor(address minter) ERC721("Entropy", "ENTR") {      
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _setupRole(AUCTIONEER_ROLE, minter);
        // Initialize decks to FIRST_GEN
        for (uint8 i; i <= MAX_DECKS; i++) {
            _decks[i].generation = FIRST_GEN;
        }
    }

    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC721, AccessControl) returns (bool) {
        return super.supportsInterface(interfaceId);
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
    
    function createAuction(
        uint8 deck, 
        uint startPrice, 
        uint32 startTime, 
        address prevPurchaser
    ) external onlyAuctioneer {
        _doCreateAuction(deck, startPrice, startTime, prevPurchaser);
    }

    function _doCreateAuction(uint8 deck, uint startPrice, uint32 startTime, address prevPurchaser) internal onlyAuctioneer {
        if (deck > MAX_DECKS || deck == 0) revert InvalidDeck(deck);        
        uint8 generation = _decks[deck].generation++;            
        uint16 auctionId = _nextAuctionId++;
        _auctions[auctionId] = Auction(
            startPrice,            
            deck,
            generation,
            startTime,            
            address(0),
            0,
            prevPurchaser
        );
        emit AuctionCreated(auctionId, msg.sender, deck, generation, startTime, prevPurchaser);
    }

    // TODO - Finer grained control
    /// @notice - Allows auctioneer to create auctions for a specified generation. Decks that have either
    /// exceeded or not advanced to this generation are ignored. This allows auctions to be created in bulk
    /// (for example on some release schedule) while allowing individual decks to advance at their own rates
    /// through chained purchases.
    function createAuctionForGeneration(uint8 generation, uint startPrice, uint32 startTime) public onlyAuctioneer {
        if (generation > MAX_GENERATIONS || generation == 0) revert InvalidGeneration();
        for (uint8 i = 1; i <= MAX_DECKS; i++) {
            if (_decks[i].generation == generation) {
                _doCreateAuction(i, startPrice, startTime, address(0));
            }
        }
    }

    /// @notice - Purchaser doesn't actually get NFT at this point (it isn't even minted). Rather, they are sort of 
    /// buying a claim to the token that will be fulfilled when settleAuction is called.
    function purchaseCard(uint16 auctionId) external payable nonReentrant {        
        Auction memory auction = _auctions[auctionId];
        bool isChainPurchase = false;        
        if (auction.startPrice == 0) revert AuctionDoesNotExist(auctionId);
        if (auction.purchaser != address(0)) revert AuctionHasEnded(auctionId);
        if (block.timestamp < auction.startTime) {
            if (auction.prevPurchaser == address(0) || msg.sender != auction.prevPurchaser) revert AuctionNotStarted(auctionId);
            isChainPurchase = true;
        }
        uint price = isChainPurchase 
            ? getChainPurchasePrice(auction.startPrice)
            : getPurchasePrice(auction.startPrice, auction.startTime);
        if (msg.value < price) revert InsufficientFunds();        
        auction.purchaser = msg.sender;    
        uint refund = msg.value - price;
        if (refund > 0) {
            (bool sent, ) = payable(msg.sender).call{value: refund}("");
            if (!sent) revert EthTransferFailed();
        }             
        auction.tokenId = _nextTokenId++;
        _auctions[auctionId] = auction;
        _safeMint(msg.sender, auction.tokenId);
        emit CardPurchased(auctionId, auction.tokenId, msg.sender, auction.deck, auction.generation);
    }

    /// @notice - This function is intended to be called b yautomated auctioneer account in response to CardPurchased activity
    /// being emitted. 
    function settleAuction(uint16 auctionId, uint nextStartPrice, string calldata tokenURI) external onlyAuctioneer {
        Auction memory auction = _auctions[auctionId];        
        if (auction.startPrice == 0) revert AuctionDoesNotExist(auctionId);
        if (auction.purchaser == address(0)) revert AuctionStillInProgress();

        _setTokenURI(auction.tokenId, tokenURI);

        uint32 startTime = uint32(block.timestamp) + _chainPurchaseWindow;
        _doCreateAuction(auction.deck, nextStartPrice, startTime, auction.purchaser);
        delete _auctions[auctionId];
        emit SaleFinalized(auctionId, auction.purchaser, auction.tokenId, auction.deck, auction.generation);                
    }

    function getPurchasePrice(uint startPrice, uint32 startTime) public view returns (uint) {                
        uint32 timeElapsed = uint32(block.timestamp) - startTime;
        uint discountRate = startPrice / _auctionDuration;
        uint discount = discountRate * timeElapsed;
        uint minPrice = startPrice / 10;
        uint price = startPrice > discount ? startPrice - discount : minPrice;        
        return price;
    }

    function getChainPurchasePrice(uint startPrice) private view returns (uint) {
        uint discount = (startPrice * _chainPurchaseDiscount) / 100;
        return startPrice - discount;
    }

    function setAuctionDuration(uint24 auctionDuration) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _auctionDuration = auctionDuration;
    }

    function setChainPurchaseWindow(uint16 chainPurchaseWindow) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _chainPurchaseWindow = chainPurchaseWindow;
    }

    function setChainPurchaseDiscount(uint8 chainPurchaseDiscount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _chainPurchaseDiscount = chainPurchaseDiscount;
    }    
}