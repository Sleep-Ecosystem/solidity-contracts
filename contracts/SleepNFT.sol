// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// OpenZeppelin implementations
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721EnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721URIStorageUpgradeable.sol";

// Auth contract
import "./Auth.sol";

contract SleepNFT is
    Initializable,
    Auth,
    ERC721Upgradeable,
    ERC721EnumerableUpgradeable,
    ERC721URIStorageUpgradeable,
    ReentrancyGuardUpgradeable
{
    uint256 public mintPrice;
    uint256 public maxSupply;
    uint256 public maxPerWallet;
    uint256 public teamMintQuantity;

    bool public hasTeamPreMinted;
    bool public isPublicMintEnabled;

    address payable public withdrawalRecipient;

    mapping(address => uint256) private mints;
    mapping(uint256 => uint8) public tokenType; // 0->Goat, 1->God, 2->King

    function initialize(address _owner) public initializer {
        __Auth_init(msg.sender);
        __ERC721_init("Sleep NFT", "SLEEP");
        __ERC721Enumerable_init();
        __ERC721URIStorage_init();
        __ReentrancyGuard_init();

        mintPrice = 0.15 ether;
        maxSupply = 10000;
        maxPerWallet = 50;
        teamMintQuantity = 50;

        withdrawalRecipient = payable(_owner);
    }

    receive() external payable {
        // React to receiving bnb
    }

    modifier teamPreMinting() {
        require(!hasTeamPreMinted, "Team can only pre mint once");
        _;
        hasTeamPreMinted = true;
    }

    function setIsPublicMintEnabled() external onlyOwner {
        isPublicMintEnabled = true;
    }

    function updateMintPrice(uint256 _mintPrice) external onlyOwner {
        mintPrice = _mintPrice;
    }

    function updateMaxSupply(uint256 _maxSupply) external onlyOwner {
        maxSupply = _maxSupply;
    }

    function updateMaxPerWallet(uint256 _maxPerWallet) external onlyOwner {
        maxPerWallet = _maxPerWallet;
    }

    function updateWithdrawalRecipient(address payable _withdrawalRecipient)
        external
        onlyOwner
    {
        withdrawalRecipient = payable(_withdrawalRecipient);
    }

    function _beforeTokenTransfer(
        address _from,
        address _to,
        uint256 _tokenId
    ) internal override(ERC721Upgradeable, ERC721EnumerableUpgradeable) {
        super._beforeTokenTransfer(_from, _to, _tokenId);
    }

    function _burn(uint256 _tokenId)
        internal
        override(ERC721Upgradeable, ERC721URIStorageUpgradeable)
    {
        super._burn(_tokenId);
    }

    function tokenURI(uint256 _tokenId)
        public
        view
        override(ERC721Upgradeable, ERC721URIStorageUpgradeable)
        returns (string memory)
    {
        return super.tokenURI(_tokenId);
    }

    function supportsInterface(bytes4 _interfaceId)
        public
        view
        override(ERC721Upgradeable, ERC721EnumerableUpgradeable)
        returns (bool)
    {
        return super.supportsInterface(_interfaceId);
    }

    function withdraw() external onlyOwner {
        (bool success, ) = withdrawalRecipient.call{
            value: address(this).balance
        }("");
        require(success, "Withdrawal failed");
    }

    function mint(
        string[] calldata _tokenURIs,
        uint8[] calldata _tokenTypes,
        uint256 _quantity
    ) external payable nonReentrant {
        require(isPublicMintEnabled, "Public mint is currently disabled");
        require(
            msg.value == _quantity * mintPrice,
            "Incorrect mint price provided"
        );
        require(
            totalSupply() + _quantity <= maxSupply,
            "Cannot fulfil mint quantity"
        );
        require(
            _tokenURIs.length == _quantity,
            "Invalid number of tokenURIs provided"
        );
        require(
            _tokenTypes.length == _quantity,
            "Invalid number of tokenTypes provided"
        );
        require(
            mints[msg.sender] + _quantity <= maxPerWallet,
            "Mint quantity will exceed max per wallet"
        );

        for (uint256 i; i < _quantity; i++) {
            uint256 newTokenID = totalSupply() + 1;
            mints[msg.sender] += 1;
            tokenType[newTokenID] = _tokenTypes[i];

            _safeMint(msg.sender, newTokenID);
            _setTokenURI(newTokenID, _tokenURIs[i]);
        }
    }

    function teamPreMint(
        string[] calldata _tokenURIs,
        uint8[] calldata _tokenTypes
    ) external onlyOwner teamPreMinting {
        require(
            !isPublicMintEnabled,
            "Team mint has to happen before public mint"
        );
        require(
            totalSupply() + teamMintQuantity <= maxSupply,
            "Cannot fulfil mint quantity"
        );
        require(
            _tokenURIs.length == teamMintQuantity,
            "Invalid number of tokenURIs provided"
        );
        require(
            _tokenTypes.length == teamMintQuantity,
            "Invalid number of tokenTypes provided"
        );

        for (uint256 i; i < teamMintQuantity; i++) {
            uint256 newTokenID = totalSupply() + 1;
            mints[msg.sender] += 1;
            tokenType[newTokenID] = _tokenTypes[i];

            _safeMint(msg.sender, newTokenID);
            _setTokenURI(newTokenID, _tokenURIs[i]);
        }
    }
}
