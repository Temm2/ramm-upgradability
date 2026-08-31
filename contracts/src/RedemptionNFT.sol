// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";

/// @title RedemptionNFT
/// @notice ERC-1155 proof-of-redemption. Each tokenId is a unique serial number
///         minted when a user burns PVT to claim their physical product.
///
/// ERC-1155 over ERC-721: ~30% cheaper batch transfers; all product types share
/// one contract. Each serial is unique (balance = 1 per address per tokenId).
///
/// Token ID = globally-incrementing serial number.
///
/// Lifecycle:
///   1. IMPXMarket.redeemPVT burns PVT and calls mint() here
///   2. Status: "PENDING" — awaiting brand fulfillment
///   3. RAMM calls fulfill(tokenId, code) after brand ships
///   4. Status: "FULFILLED" — buyer can see their promo code on-chain
contract RedemptionNFT is ERC1155, Ownable {
    using Strings for uint256;

    struct RedemptionData {
        address product;       // PVT token contract address
        address redeemer;      // buyer who redeemed
        uint256 quantity;      // PVT tokens burned
        uint256 timestamp;     // block.timestamp of redemption
        string  productName;   // human-readable product name
        string  status;        // "PENDING" or "FULFILLED"
        string  code;          // redemption/promo code (set on fulfillment)
        // EU Digital Product Passport fields (ESPR-aligned, optional at issuance)
        string  checkoutUrl;   // brand checkout page where code can be redeemed
        string  dppUri;        // off-chain IPFS URI with full DPP JSON (sustainability, certs, media)
    }

    uint256 private _nextTokenId;

    /// @notice Markets authorised to mint. One RedemptionNFT contract is shared
    ///         across every product's IMPXMarket, so this must support many
    ///         authorized callers, not just one — each new campaign's market
    ///         gets authorized here automatically at deploy time (see VALET).
    mapping(address => bool) public authorizedMarkets;

    mapping(uint256 => RedemptionData) public redemptions;

    event Minted(uint256 indexed tokenId, address indexed redeemer, address indexed product, uint256 quantity);
    event Fulfilled(uint256 indexed tokenId, string code, uint256 timestamp);
    event MarketAuthorized(address indexed market, bool authorized);

    error OnlyMarket();
    error TokenNotFound();

    modifier onlyMarket() {
        if (!authorizedMarkets[msg.sender]) revert OnlyMarket();
        _;
    }

    constructor(address initialOwner) ERC1155("") Ownable(initialOwner) {}

    /// @notice Authorize (or revoke) an IMPXMarket to mint redemption receipts.
    ///         Called once per market, automatically, right after that market
    ///         is deployed for a new campaign.
    function setMarketAuthorized(address _market, bool _authorized) external onlyOwner {
        authorizedMarkets[_market] = _authorized;
        emit MarketAuthorized(_market, _authorized);
    }

    /// @notice Called by IMPXMarket.redeemPVT to issue the redemption receipt.
    /// @param to          Redeemer's address
    /// @param product     PVT token address (product identifier)
    /// @param productName Human-readable product name
    /// @param quantity    Number of PVT tokens burned
    /// @return tokenId    The serial number / token ID
    function mint(
        address to,
        address product,
        string calldata productName,
        uint256 quantity
    ) external onlyMarket returns (uint256 tokenId) {
        tokenId = ++_nextTokenId;
        _mint(to, tokenId, 1, "");
        redemptions[tokenId] = RedemptionData({
            product:     product,
            redeemer:    to,
            quantity:    quantity,
            timestamp:   block.timestamp,
            productName: productName,
            status:      "PENDING",
            code:        "",
            checkoutUrl: "",
            dppUri:      ""
        });
        emit Minted(tokenId, to, product, quantity);
    }

    /// @notice Set the brand checkout URL and DPP IPFS URI for a minted token.
    ///         Called by the owner (RAMM admin) after deployment metadata is ready.
    function setDppData(uint256 tokenId, string calldata checkoutUrl, string calldata dppUri) external onlyOwner {
        if (redemptions[tokenId].redeemer == address(0)) revert TokenNotFound();
        redemptions[tokenId].checkoutUrl = checkoutUrl;
        redemptions[tokenId].dppUri = dppUri;
    }

    /// @notice Brand/RAMM admin sets the fulfillment code once shipped.
    function fulfill(uint256 tokenId, string calldata code) external onlyOwner {
        if (redemptions[tokenId].redeemer == address(0)) revert TokenNotFound();
        redemptions[tokenId].status = "FULFILLED";
        redemptions[tokenId].code = code;
        emit Fulfilled(tokenId, code, block.timestamp);
    }

    /// @notice On-chain JSON metadata. Serial number = tokenId.
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

    /// @notice Total serials minted.
    function totalMinted() external view returns (uint256) {
        return _nextTokenId;
    }
}
