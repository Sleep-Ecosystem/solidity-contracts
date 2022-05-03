// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// OpenZeppelin implementations
import "@openzeppelin/contracts-upgradeable/utils/CountersUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/IERC721Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/IERC721ReceiverUpgradeable.sol";

// Auth contract
import "./Auth.sol";

contract NFTMarket is
    Initializable,
    Auth,
    IERC721ReceiverUpgradeable,
    ReentrancyGuardUpgradeable
{
    using CountersUpgradeable for CountersUpgradeable.Counter;

    IERC20Upgradeable public sleepToken;
    IERC721Upgradeable public sleepNFT;

    CountersUpgradeable.Counter private itemIDs;
    CountersUpgradeable.Counter private delistedItems;

    uint256 public listingFee;
    uint256 public totalLockedFee;

    struct MarketItem {
        bool isSold;
        address buyer;
        uint256 price;
        address seller;
        uint256 itemID;
        uint256 tokenID;
        uint256 timeBought;
        uint256 timeListed;
    }
    mapping(uint256 => MarketItem) private marketItems;

    mapping(address => uint256[]) private userBoughtItems;
    mapping(address => uint256[]) private userListedItems;

    event ItemAdded(
        uint256 price,
        uint256 itemId,
        uint256 tokenID,
        address indexed seller
    );
    event ItemBought(
        uint256 price,
        uint256 itemId,
        uint256 tokenID,
        address indexed buyer,
        address indexed seller
    );
    event ItemRemoved(uint256 itemId, uint256 tokenID, address indexed seller);

    function initialize(
        IERC20Upgradeable _sleepToken,
        IERC721Upgradeable _sleepNFT
    ) public initializer {
        __Auth_init(msg.sender);
        __ReentrancyGuard_init();

        listingFee = 0;

        sleepToken = _sleepToken;
        sleepNFT = _sleepNFT;
    }

    function updateListingFee(uint256 _listingFee) external onlyOwner {
        listingFee = _listingFee;
    }

    function getMarketItem(uint256 _itemId)
        external
        view
        returns (MarketItem memory)
    {
        return marketItems[_itemId];
    }

    function withdrawFee(uint256 _amountPercentage) external onlyOwner {
        uint256 amountToWithdraw = (totalLockedFee * _amountPercentage) / 100;
        totalLockedFee -= amountToWithdraw;
        require(
            sleepToken.transfer(msg.sender, amountToWithdraw),
            "transfer failed"
        );
    }

    function addItemToMarket(uint256 _tokenID, uint256 _price)
        external
        nonReentrant
    {
        require(_price > 0, "NFT listing price must be greater than 0");

        require(
            sleepToken.transferFrom(msg.sender, address(this), listingFee),
            "transfer from failed"
        );
        totalLockedFee += listingFee;
        sleepNFT.safeTransferFrom(msg.sender, address(this), _tokenID);

        itemIDs.increment();
        uint256 newItemID = itemIDs.current();

        MarketItem memory newMarketItem;
        newMarketItem.price = _price;
        newMarketItem.seller = msg.sender;
        newMarketItem.itemID = newItemID;
        newMarketItem.tokenID = _tokenID;
        newMarketItem.timeListed = block.timestamp;

        marketItems[newItemID] = newMarketItem;
        userListedItems[msg.sender].push(newItemID);

        emit ItemAdded(_price, newItemID, _tokenID, msg.sender);
    }

    function buyFromMarket(uint256 _itemID) external nonReentrant {
        require(
            marketItems[_itemID].itemID == _itemID,
            "Item does not exist in the marketplace"
        );
        require(
            !marketItems[_itemID].isSold,
            "Item has already been purchased"
        );
        require(
            marketItems[_itemID].buyer == address(0),
            "Item has already been purchased"
        );

        uint256 price = marketItems[_itemID].price;
        uint256 tokenID = marketItems[_itemID].tokenID;
        address seller = marketItems[_itemID].seller;

        require(
            sleepToken.transferFrom(msg.sender, seller, price),
            "transfer from failed"
        );

        marketItems[_itemID].buyer = msg.sender;
        marketItems[_itemID].isSold = true;
        marketItems[_itemID].timeBought = block.timestamp;
        userBoughtItems[msg.sender].push(_itemID);

        delistedItems.increment();

        sleepNFT.safeTransferFrom(address(this), msg.sender, tokenID);

        emit ItemBought(price, _itemID, tokenID, msg.sender, seller);
    }

    function removeFromMarketplace(uint256 _itemID) external nonReentrant {
        require(
            marketItems[_itemID].itemID == _itemID,
            "Item does not exist in the marketplace"
        );
        require(
            !marketItems[_itemID].isSold,
            "Item has already been purchased"
        );
        require(
            marketItems[_itemID].buyer == address(0),
            "Item has already been purchased"
        );
        require(
            marketItems[_itemID].seller == msg.sender,
            "Only the seller can remove an item from the marketplace"
        );

        uint256 tokenID = marketItems[_itemID].tokenID;

        marketItems[_itemID].buyer = msg.sender;
        marketItems[_itemID].isSold = true;
        marketItems[_itemID].timeBought = block.timestamp;

        delistedItems.increment();

        sleepNFT.transferFrom(address(this), msg.sender, tokenID);

        emit ItemRemoved(_itemID, tokenID, msg.sender);
    }

    function getTotalMarketItems() public view returns (uint256) {
        return itemIDs.current();
    }

    function getTotalUnsoldItems() public view returns (uint256) {
        uint256 numItems = itemIDs.current();
        uint256 numUnsoldItems = numItems - delistedItems.current();
        return numUnsoldItems;
    }

    function getUserBoughtItems(address _user)
        external
        view
        returns (uint256[] memory)
    {
        return userBoughtItems[_user];
    }

    function getUserListedItems(address _user)
        external
        view
        returns (uint256[] memory)
    {
        return userListedItems[_user];
    }

    function getUnsoldMarketItems(uint256 _from, uint256 _to)
        external
        view
        returns (MarketItem[] memory unsoldItems)
    {
        uint256 index;
        uint256 numUnsoldItems = getTotalUnsoldItems();

        require(
            _to <= getTotalMarketItems(),
            "to must be lower than the total number of market items"
        );
        require(
            _from <= _to,
            "from must be lower than to and above or equal to 0"
        );

        unsoldItems = new MarketItem[](numUnsoldItems);
        for (uint256 i = _from; i < _to; i++) {
            if (
                marketItems[i + 1].buyer == address(0) &&
                !marketItems[i + 1].isSold
            ) {
                uint256 itemID = marketItems[i + 1].itemID;
                MarketItem memory marketItem = marketItems[itemID];
                unsoldItems[index] = marketItem;
                index += 1;
            }
        }

        return unsoldItems;
    }

    function onERC721Received(
        address,
        address,
        uint256,
        bytes memory
    ) public virtual override returns (bytes4) {
        return this.onERC721Received.selector;
    }
}
