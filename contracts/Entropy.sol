// contracts/Entropy.sol
// SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "hardhat/console.sol";

error CardNotListed();
error CardSaleHasEnded();
error ListingAlreadyExists();
error ListingDoesNotExist();
error EthTransferFailed();
error InsufficientFunds();
error InvalidDeck();
error InvalidGeneration();
error InvalidCard(uint8 deckNum, uint8 genNum);
error Unauthorized();
error NoEtherBalance();
error InvalidStartTime();

// uint256 public _priceCoeff = 1 ether;
// uint256 public _priceConstant = 0.5 ether;

struct CardListing {
    uint16 tokenId;
    uint32 startTime;
    address prevPurchaser;
}

struct ListingId {
    uint8 deck;
    uint8 generation;
}

contract Entropy is ERC721, Ownable, ReentrancyGuard {
    using Strings for uint256;    
    using Strings for uint8;    

    uint8 public constant MAX_DECKS = 50;
    uint8 public constant MAX_GENERATIONS = 60;

    uint256 public _priceCoeff = 0.01 ether;
    uint256 public _priceConstant = 0.005 ether;    
    uint24 public _listingDuration = 86400; // 24 Hours
    uint16 public _chainPurchaseWindow = 3600; // 1 Hour
    uint8 public _chainPurchaseDiscount = 25; // percent

    string public _baseTokenURI = "ipfs://foo";
    uint16 private _nextTokenId = 1;
    mapping(uint8 => mapping(uint8 => CardListing)) public _listings;
    mapping(uint16 => ListingId) public _listingIds;
    uint8[] public _rarity;

    event CardListed(
        uint8 indexed deck,
        uint8 indexed generation,
        address indexed prevPurchaser,
        uint32 startTime
    );

    event CardPurchased(
        uint8 indexed deck,
        uint8 generation,
        uint16 indexed tokenId,
        address indexed purchaser,
        uint256 purchasePrice,
        uint32 nextStartTime        
    );

    event ListingCanceled(uint8 deck, uint8 generation);

    constructor() ERC721("Entropy Test", "ENTRPY") {}

    /**
     * @dev - Each card has a rarity rating ranging from 1 - 10. Card pricing is
     * depedent on this rarity info, so in order to calculate the starting price 
     * for new listings, we need access to this data. Calculating the starting price
     * from rarity on the fly was cheaper than storing all start prices explicitly. As 
     * a result, this function allows us to provide the contract with rarity info required
     * for calculating start price.
     */
    function setRarity(uint8[] calldata rarity) external onlyOwner {
        _rarity = rarity;
    }

    function _baseURI() internal view virtual override returns (string memory) {
        return _baseTokenURI;
    }

    function setBaseURI(string calldata baseTokenURI) external onlyOwner {
        _baseTokenURI = baseTokenURI;
    }

    function tokenURI(uint256 tokenId)
        public
        view
        override
        returns (string memory)
    {
        ListingId storage listingId = _listingIds[uint16(tokenId)];
        require(
            _exists(tokenId) && _isValidCard(listingId.deck, listingId.generation),
            "ERC721Metadata: URI query for nonexistent token"
        );                         
        return (
            string(
                abi.encodePacked(
                    _baseTokenURI,
                    "/",
                    "D",
                    listingId.deck.toString(),
                    "-",
                    "G",
                    listingId.generation.toString(),
                    ".json"
                )
            )
        );
    }

    /**
     * @dev - This method returns quietly when an attempt is made to create a listing
     * that already exists. This is to allow flexibility for other methods utilizing this
     * logic. For example, when listing an entire generation, this allows us to silently 
     * skip over generations that may already have been listed for a given deck.
     */
    function _listCard(
        uint8 deckNum,
        uint8 genNum,
        uint32 startTime,
        address prevPurchaser
    ) internal {        
        if (!_isValidCard(deckNum, genNum)) revert InvalidCard(deckNum, genNum);
        if (startTime == 0) revert InvalidStartTime();
        CardListing memory listing = _listings[deckNum][genNum];
        if (listing.startTime == 0) {
            // Card has not been listed yet:
            listing.startTime = startTime;
            listing.prevPurchaser = prevPurchaser;
            _listings[deckNum][genNum] = listing;
            emit CardListed(deckNum, genNum, prevPurchaser, startTime);
        }
    }

    /**
     * @dev - Create auctions for all decks given a specific generation. Attempts to
     * list a card that has already been sold will be ignored.
     */
    function listGeneration(uint8 generation, uint32 startTime)
        external
        onlyOwner
    {
        if (generation > MAX_GENERATIONS || generation == 0)
            revert InvalidGeneration();
        for (uint8 i = 1; i <= MAX_DECKS; i++) {
            _listCard(i, generation, startTime, address(0));
        }
    }

    /**
     * @dev - List a specific card for sale by deck number and generation number.
     */
    function listCard(
        uint8 deckNum,
        uint8 genNum,
        uint32 startTime
    ) external onlyOwner {
        if (_listings[deckNum][genNum].startTime != 0)
            revert ListingAlreadyExists();
        _listCard(deckNum, genNum, startTime, address(0));
    }

    /**
     * @notice - List multiple cards by providing an array of deck numbers and generation numbers.
     * Attempts to list cards that have already been sold will be ignored. 
     */
    function listManyCards(
        uint8[] calldata deckNums,
        uint8[] calldata genNums,
        uint32 startTime
    ) external onlyOwner {
        for (uint8 i = 0; i < deckNums.length; i++) {
            for (uint8 j = 0; j < genNums.length; j++) {
                _listCard(deckNums[i], genNums[j], startTime, address(0));
            }
        }
    }

    /**
     * @dev - A listing can be canceled at any point prior to sale. Listings that are candidates
     * for cancelation will have a non-zero startTime and a tokenId of 0.
     */
    function cancelListing(uint8 deckNum, uint8 genNum) external onlyOwner {
        CardListing memory listing = _listings[deckNum][genNum];
        if (listing.startTime == 0) revert ListingDoesNotExist();
        if (listing.tokenId != 0) revert CardSaleHasEnded();
        delete _listings[deckNum][genNum];
        emit ListingCanceled(deckNum, genNum);
    }

    /**
     * @notice - Purchase a card that has an active listing. The purchaser of the previous card in the
     * deck (if any) will be able to purchase before startTime. Purchasing a card
     * flags the current listing as ended by setting tokenId, mints the token to the purchaser, and lists
     * the next card in the deck.     
     */
    function purchaseCard(uint8 deckNum, uint8 genNum)
        external
        payable
        nonReentrant
    {
        if (!_isValidCard(deckNum, genNum)) revert InvalidCard(deckNum, genNum);
        CardListing memory listing = _listings[deckNum][genNum];
        bool isChainPurchase = false;
        if (listing.startTime == 0) revert CardNotListed();
        if (listing.tokenId != 0) revert CardSaleHasEnded();
        if (block.timestamp < listing.startTime) {
            if (listing.prevPurchaser == address(0) || msg.sender != listing.prevPurchaser) 
                revert Unauthorized();
            isChainPurchase = true;
        }
        uint256 price = isChainPurchase
            ? _chainPrice(deckNum, genNum)
            : _price(deckNum, genNum, listing.startTime);

        if (msg.value < price) revert InsufficientFunds();

        uint256 refund = msg.value - price;
        if (refund > 0) {
            (bool sent, ) = payable(msg.sender).call{value: refund}("");
            if (!sent) revert EthTransferFailed();
        }

        uint16 tokenId = _nextTokenId++;
        ListingId memory listingId = ListingId(deckNum, genNum);
        _listings[deckNum][genNum].tokenId = tokenId;
        _listingIds[tokenId] = listingId;
        _safeMint(msg.sender, tokenId);

        uint8 nextGen = genNum + 1;
        uint32 startTime;
        if (_isValidGeneration(nextGen)) {
            // Only create next listing while nextGen is a valid generation, i.e. <= 60
            startTime = uint32(block.timestamp) + _chainPurchaseWindow;        
            _listCard(deckNum, nextGen, startTime, msg.sender);
        }
        
        emit CardPurchased(deckNum, genNum, tokenId, msg.sender, price, startTime);
    }

    function withdraw(address receipt) public onlyOwner {
        if (address(this).balance == 0) revert NoEtherBalance();
        (bool sent, ) = payable(receipt).call{value: address(this).balance}("");
        if (!sent) revert EthTransferFailed();
    }

    /**  
     * @notice - Rarity dependent price for normal purchases.
     */ 
    function _price(
        uint8 deckNum,
        uint8 genNum,
        uint32 startTime
    ) internal view returns (uint256) {
        uint256 rarity = getRarity(deckNum, genNum);
        uint256 startPrice = (((rarity - 1) * (_priceCoeff)) / 9) + _priceConstant;
        uint256 timeElapsed = block.timestamp - uint256(startTime);
        uint256 minPrice = startPrice / 10;
        uint256 discountRate = (startPrice - minPrice) / _listingDuration;
        uint256 discount = uint256(discountRate) * timeElapsed;        
        uint256 price = startPrice - minPrice > discount 
            ? startPrice - discount
            : minPrice;
        return price;
    }

    /** 
     * @notice - Rarity dependent price for chain purchases.
     */
    function _chainPrice(uint8 deckNum, uint8 genNum)
        internal
        view
        returns (uint256)
    {
        uint256 rarity = getRarity(deckNum, genNum);
        uint256 startPrice = (((rarity - 1) * (_priceCoeff)) / 9) + _priceConstant;
        uint256 discount = (startPrice * _chainPurchaseDiscount) / 100;
        return startPrice - discount;
    }

    /**
     * @dev Rarity is a 2D array indexed by deckNum, genNum translated into one dimension using
     * a striding technique that lays each deck out one after another. For example, _rarity[0] would
     * represent deck 1, generation 1, _rarity[1] = deck 1, gen 2 and so on.
     */
    function getRarity(uint16 deckNum, uint16 genNum)
        internal
        view
        returns (uint8)
    {
        if (deckNum == 0 || deckNum > MAX_DECKS) revert InvalidDeck();
        if (genNum == 0 || genNum > MAX_GENERATIONS) revert InvalidGeneration();
        uint16 index = ((deckNum - 1) * MAX_GENERATIONS) + (genNum - 1);
        return _rarity[index];
    }

    /**
     * @dev - Fetch tokenId for given deck & generation.
     */
    function getTokenId(uint8 deckNum, uint8 genNum)
        external
        view
        returns (uint16)
    {
        CardListing memory listing = _listings[deckNum][genNum];
        require(
            listing.tokenId != 0,
            "ERC721Metadata: URI query for nonexistent token"
        );
        require(
            _exists(listing.tokenId),
            "ERC721Metadata: URI query for nonexistent token"
        );
        return listing.tokenId;
    }

    /**
     * @dev - Look up ListingId (deck and generation) given a tokenId 
     */
    function getListingId(uint16 tokenId)
        external
        view
        returns (ListingId memory listingId)
    {
        return _listingIds[tokenId];
    }

    function setListingDuration(uint24 listingDuration) external onlyOwner {
        _listingDuration = listingDuration;
    }

    function setChainPurchaseWindow(uint16 chainPurchaseWindow)
        external
        onlyOwner
    {
        _chainPurchaseWindow = chainPurchaseWindow;
    }

    function setChainPurchaseDiscount(uint8 chainPurchaseDiscount)
        external
        onlyOwner
    {
        _chainPurchaseDiscount = chainPurchaseDiscount;
    }

    function _isValidDeck(uint8 deckNum) internal pure returns (bool) {
        return deckNum > 0 && deckNum <= MAX_DECKS;
    }

    function _isValidGeneration(uint8 genNum) internal pure returns (bool) {
        return  genNum > 0 && genNum <= MAX_GENERATIONS;
    }

    function _isValidCard (uint8 deckNum, uint8 genNum) internal pure returns (bool) {
        return _isValidDeck(deckNum) && _isValidGeneration(genNum);        
    }
}