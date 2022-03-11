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
error EthTransferFailed();
error InsufficientFunds();
error InvalidDeck();
error InvalidGeneration();
error Unauthorized();

struct CardListing {
    uint16 tokenId;
    uint32 startTime;
    address prevPurchaser;
}

contract Entropy is ERC721, Ownable, ReentrancyGuard {
    using Strings for uint256;

    uint8 public constant MAX_DECKS = 50;
    uint8 public constant MAX_GENERATIONS = 60;

    uint24 public _listingDuration = 7200; // seconds
    uint16 public _chainPurchaseWindow = 3600; // seconds
    uint8 public _chainPurchaseDiscount = 25; // percent

    string public _baseTokenURI = "ipfs://foo";
    uint16 private _nextTokenId = 1;
    mapping(uint8 => mapping(uint8 => CardListing)) public _listings;
    uint8[] public _rarity;

    event CardListed(
        uint8 indexed deck,
        uint8 indexed generation,
        uint32 startTime
    );

    event CardPurchased(
        uint8 indexed deck,
        uint8 generation,
        uint16 indexed tokenId,
        address indexed purchaser
    );

    constructor(uint8[] memory rarity) ERC721("Entropy", "ENRPY") {
        _rarity = rarity;
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(ERC721)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
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
        require(
            _exists(tokenId),
            "ERC721Metadata: URI query for nonexistent token"
        );
        return
            string(
                abi.encodePacked(
                    _baseTokenURI,
                    "/",
                    tokenId.toString(),
                    ".json"
                )
            );
    }

    function _listCard(
        uint8 deckNum,
        uint8 genNum,
        uint32 startTime,
        address prevPurchaser
    ) internal {
        if (deckNum > MAX_DECKS || deckNum == 0) revert InvalidDeck();
        if (genNum > MAX_GENERATIONS || genNum == 0) revert InvalidGeneration();
        CardListing memory listing = _listings[deckNum][genNum];
        if (listing.tokenId == 0) {
            // Card has not been sold yet
            listing.startTime = startTime;
            listing.prevPurchaser = prevPurchaser;
            _listings[deckNum][genNum] = listing;
            emit CardListed(deckNum, genNum, startTime);
        }
    }

    /// @notice - Create auctions for all decks given a specific generation. Attempts to
    //  list a card that has already been sold will be ignored.
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

    /// @notice - List a specific card for sale by deck number and generation number
    function listCard(
        uint8 deckNum,
        uint8 genNum,
        uint32 startTime
    ) external onlyOwner {
        if (_listings[deckNum][genNum].startTime != 0)
            revert CardSaleHasEnded();
        for (uint8 i = 1; i <= MAX_DECKS; i++) {
            _listCard(i, genNum, startTime, address(0));
        }
    }

    /// @notice - List multiple cards by providing an array of deck numbers and generation numbers.
    //  Attempts to list cards that have already been sold will be ignored.
    function listManyCards(
        uint8[] calldata deckNums,
        uint8[] calldata genNums,
        uint32 startTime
    ) external onlyOwner {
        for (uint8 i = 0; i < deckNums.length; i++) {
            for (uint8 j = 0; i < genNums.length; i++) {
                _listCard(deckNums[i], genNums[j], startTime, address(0));
            }
        }
    }

    /// @notice - Purchase a card that has an active listing. The purchaser of the previous card in the
    /// deck (if any) will be able to purchase before startTime. Purchasing a card
    /// flags the current listing as ended by setting tokenId, mints the token to the purchaser, and lists
    /// the next card in the deck.
    function purchaseCard(uint8 deckNum, uint8 genNum)
        external
        payable
        nonReentrant
    {
        if (deckNum > MAX_DECKS || deckNum == 0) revert InvalidDeck();
        if (genNum > MAX_GENERATIONS || genNum == 0) revert InvalidGeneration();
        CardListing memory listing = _listings[deckNum][genNum];
        bool isChainPurchase = false;
        if (listing.startTime == 0) revert CardNotListed();
        if (listing.tokenId != 0) revert CardSaleHasEnded();
        if (block.timestamp < listing.startTime) {
            if (
                listing.prevPurchaser == address(0) ||
                msg.sender != listing.prevPurchaser
            ) revert Unauthorized();
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
        _listings[deckNum][genNum].tokenId = tokenId;
        _safeMint(msg.sender, tokenId);

        uint32 startTime = uint32(block.timestamp) + _chainPurchaseWindow;
        _listCard(deckNum, genNum + 1, startTime, msg.sender);

        emit CardPurchased(deckNum, genNum, tokenId, msg.sender);
    }

    /// @notice - Rarity dependent price for normal purchases.
    function _price(
        uint8 deckNum,
        uint8 genNum,
        uint32 startTime
    ) public view returns (uint256) {
        uint256 rarity = getRarity(deckNum, genNum);
        uint256 startPrice = (((rarity - 1) * (1 ether)) / 9) + 0.5 ether;
        uint32 timeElapsed = uint32(block.timestamp) - startTime;
        uint256 discountRate = startPrice / _listingDuration;
        uint256 discount = discountRate * timeElapsed;
        uint256 minPrice = startPrice / 10;
        uint256 price = startPrice > discount
            ? startPrice - discount
            : minPrice;
        return price;
    }

    /// @notice - Rarity dependent price for chain purchases.
    function _chainPrice(uint8 deckNum, uint8 genNum)
        private
        view
        returns (uint256)
    {
        uint256 rarity = getRarity(deckNum, genNum);
        uint256 startPrice = (((rarity - 1) * (1 ether)) / 9) + 0.5 ether;
        uint256 discount = (startPrice * _chainPurchaseDiscount) / 100;
        return startPrice - discount;
    }

    /// @dev - Helper to fetch rarity. Maps one dimensional array into two dimensional
    /// array keyed by deck number, generation number.
    function getRarity(uint8 deckNum, uint8 genNum)
        internal
        view
        returns (uint8)
    {
        if (deckNum == 0 || deckNum > MAX_DECKS) revert InvalidDeck();
        if (genNum == 0 || genNum > MAX_GENERATIONS) revert InvalidDeck();
        uint8 deckIndex = (deckNum * 50) - 1;
        uint8 genIndex = genNum - 1;
        return _rarity[deckIndex + genIndex];
    }

    /// @notice - Fetch tokenId for deck number, generation number pair (if exists).
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
}
