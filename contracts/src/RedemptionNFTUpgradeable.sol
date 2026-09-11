// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {ERC1155Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC1155/ERC1155Upgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";

/// @title RedemptionNFTUpgradeable
/// @notice Upgradeable ERC-1155 order receipt contract behind UUPS proxy.
contract RedemptionNFTUpgradeable is ERC1155Upgradeable, OwnableUpgradeable, UUPSUpgradeable {
    using Strings for uint256;

    struct RedemptionData {
        address product;
        address redeemer;
        uint256 quantity;
        uint256 timestamp;
        string productName;
        string status;
        string code;
        string checkoutUrl;
        string dppUri;
    }

    uint256 private _nextTokenId;
    mapping(address => bool) public authorizedMarkets;
    mapping(uint256 => RedemptionData) public redemptions;

    /// @notice Storage gap for layout safety
    uint256[50] private __gap;

    event Minted(uint256 indexed tokenId, address indexed redeemer, address indexed product, uint256 quantity);
    event Fulfilled(uint256 indexed tokenId, string code, uint256 timestamp);
    event MarketAuthorized(address indexed market, bool authorized);

    error OnlyMarket();
    error TokenNotFound();

    modifier onlyMarket() {
        if (!authorizedMarkets[msg.sender]) revert OnlyMarket();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address initialOwner) external initializer {
        __ERC1155_init("");
        __Ownable_init(initialOwner);
    }

    function setMarketAuthorized(address _market, bool _authorized) external onlyOwner {
        authorizedMarkets[_market] = _authorized;
        emit MarketAuthorized(_market, _authorized);
    }

    function mint(
        address to,
        address product,
        string calldata productName,
        uint256 quantity
    ) external onlyMarket returns (uint256 tokenId) {
        tokenId = ++_nextTokenId;
        _mint(to, tokenId, 1, "");
        redemptions[tokenId] = RedemptionData({
            product: product,
            redeemer: to,
            quantity: quantity,
            timestamp: block.timestamp,
            productName: productName,
            status: "PENDING",
            code: "",
            checkoutUrl: "",
            dppUri: ""
        });
        emit Minted(tokenId, to, product, quantity);
    }

    function setDppData(uint256 tokenId, string calldata checkoutUrl, string calldata dppUri) external onlyOwner {
        if (redemptions[tokenId].redeemer == address(0)) revert TokenNotFound();
        redemptions[tokenId].checkoutUrl = checkoutUrl;
        redemptions[tokenId].dppUri = dppUri;
    }

    function fulfill(uint256 tokenId, string calldata code) external onlyOwner {
        if (redemptions[tokenId].redeemer == address(0)) revert TokenNotFound();
        redemptions[tokenId].status = "FULFILLED";
        redemptions[tokenId].code = code;
        emit Fulfilled(tokenId, code, block.timestamp);
    }

    function uri(uint256 tokenId) public view override returns (string memory) {
        RedemptionData memory d = redemptions[tokenId];
        if (d.redeemer == address(0)) revert TokenNotFound();

        string memory json = string.concat(
            '{"name":"RAMM Redemption #', tokenId.toString(),
            '","description":"Digital Product Passport for ', d.productName,
            '. Present this NFT to claim your physical product.",',
            '"standard":"EU-ESPR-DPP-v0.1",',
            '"attributes":[',
            '{"trait_type":"Serial Number","value":', tokenId.toString(), '},',
            '{"trait_type":"Product","value":"', d.productName, '"},',
            '{"trait_type":"Quantity","value":', d.quantity.toString(), '},',
            '{"trait_type":"Status","value":"', d.status, '"},',
            '{"trait_type":"Redeemed At","display_type":"date","value":', d.timestamp.toString(), '}',
            '],',
            '"checkout_url":"', d.checkoutUrl, '",',
            '"dpp_uri":"', d.dppUri, '"',
            '}'
        );
        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }

    function totalMinted() external view returns (uint256) {
        return _nextTokenId;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
