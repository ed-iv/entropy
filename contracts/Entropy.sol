// contracts/Entropy.sol
// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity 0.8.4;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

error Unauthorized();
error AuctionNotStarted();
error AuctionStillInProgress();
error AuctionDoesNotExist();
error AuctionHasEnded();
error InvalidDeck();
error InvalidGeneration();
error InsufficientFunds();
error EthTransferFailed();
error RarityNotSet();

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
    uint8[] public _rarity;
    
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

    constructor(address minter, uint8[] memory rarity) ERC721("Entropy", "ENTR") {      
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _setupRole(AUCTIONEER_ROLE, minter);
        // Initialize decks to FIRST_GEN
        for (uint8 i; i <= MAX_DECKS; i++) {
            _decks[i].generation = FIRST_GEN;
        }        
        _rarity = rarity;        
    }

    function setRarity(uint8[] calldata rarity) external onlyAuctioneer {
        _rarity = rarity;
    }

    function getRarity(uint8 deck, uint8 generation) internal view returns (uint8) {
        if (_rarity.length != 3000) revert RarityNotSet();
        if (deck == 0 || deck > MAX_DECKS) revert InvalidDeck();
        if (generation == 0 || generation > MAX_GENERATIONS) revert InvalidDeck();
        uint8 deckIndex = (deck * 50) - 1;
        uint8 genIndex = generation - 1;
        return _rarity[deckIndex + genIndex];
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

    function _doCreateAuction(uint8 deck, uint startPrice, uint32 startTime, address prevPurchaser) internal {
        if (deck > MAX_DECKS || deck == 0) revert InvalidDeck();        
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

    /// @notice - Create auctions for all decks given a specific generation
    function createAuctionForGeneration(uint8 generation, uint startPrice, uint32 startTime) public onlyAuctioneer {
        if (generation > MAX_GENERATIONS || generation == 0) revert InvalidGeneration();
        for (uint8 i = 1; i <= MAX_DECKS; i++) {
            if (_decks[i].generation == generation) {
                _doCreateAuction(i, startPrice, startTime, address(0));
            }
        }
    }

    /// @notice - Purchasing a card mints the token and initializes the next auction.
    function purchaseCard(uint16 auctionId) external payable nonReentrant {        
        Auction memory auction = _auctions[auctionId];
        bool isChainPurchase = false;        
        if (auction.startPrice == 0) revert AuctionDoesNotExist();
        if (auction.purchaser != address(0)) revert AuctionHasEnded();
        if (block.timestamp < auction.startTime) {
            if (auction.prevPurchaser == address(0) || msg.sender != auction.prevPurchaser) revert AuctionNotStarted();
            isChainPurchase = true;
        }
        uint price = isChainPurchase 
            ? getChainPurchasePrice(auction)
            : getPurchasePrice(auction);
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
        // Make user settle auction                         
        uint32 startTime = uint32(block.timestamp) + _chainPurchaseWindow;
        delete _auctions[auctionId];
        _doCreateAuction(auction.deck, 0.5 ether, startTime, auction.purchaser);        
    }

    function getPurchasePrice(Auction memory auction) public view returns (uint) {   
        uint rarity = getRarity(auction.deck, auction.generation);        
        uint startPrice = ((rarity - 1) / 9) + 0.5 ether;             
        uint32 timeElapsed = uint32(block.timestamp) - auction.startTime;
        uint discountRate = startPrice / _auctionDuration;
        uint discount = discountRate * timeElapsed;
        uint minPrice = startPrice / 10;
        uint price = startPrice > discount ? startPrice - discount : minPrice;        
        return price;
    }

    function getChainPurchasePrice(Auction memory auction) private view returns (uint) {
        uint rarity = getRarity(auction.deck, auction.generation);        
        uint startPrice = ((rarity - 1) / 9) + 0.5 ether;         
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