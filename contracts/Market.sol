// SPDX-License-Identifier: MIT
pragma solidity ^0.4.15;

import "./GameItem.sol";

contract Market {
    address public owner;
    address public feeRecipient;
    uint256 public feePercent;
    bool public paused;

    uint256 public constant MIN_LISTING_DURATION = 1 hours;
    uint256 public constant MAX_LISTING_DURATION = 365 days;

    GameItem public itemContract;

    struct Listing {
        address seller;
        uint256 tokenId;
        uint256 price;
        uint256 startTime;
        uint256 endTime;
        bool active;
    }

    mapping (bytes32 => Listing) public listings;
    modifier onlyOwner() {
        require(msg.sender == owner);
        _;
    }

    modifier whenNotPaused() {
        require(!paused);
        _;
    }

    function Market(address itemContractAddress, address feeRecipient_, uint256 feePercent_) public {
        require(itemContractAddress != address(0));
        require(feeRecipient_ != address(0));
        require(feePercent_ <= 1000);

        itemContract = GameItem(itemContractAddress);
        feeRecipient = feeRecipient_;
        feePercent = feePercent_;
        owner = msg.sender;
    }
    function listItem(uint256 tokenId, uint256 price, uint256 duration) public whenNotPaused returns (bytes32 listingId) {
        require(price > 0);
        require(duration >= MIN_LISTING_DURATION);
        require(duration <= MAX_LISTING_DURATION);
        require(itemContract.ownerOf(tokenId) == msg.sender);
        require(itemContract.getApproved(tokenId) == address(this) || itemContract.isApprovedForAll(msg.sender, address(this)));
        require(!isListed(tokenId));

        uint256 startTime = now;
        uint256 endTime = startTime + duration;

        listingId = keccak256(msg.sender, tokenId, price, startTime, endTime);

        listings[listingId] = Listing({
            seller: msg.sender,
            tokenId: tokenId,
            price: price,
            startTime: startTime,
            endTime: endTime,
            active: true
        });

        tokenToListing[tokenId] = listingId;

        Listed(msg.sender, listingId, tokenId, price, startTime, endTime);
    }

    function unlistItem(bytes32 listingId) public whenNotPaused {
        Listing storage listing = listings[listingId];

        require(listing.active);
        require(listing.seller == msg.sender || msg.sender == owner);

        uint256 tokenId = listing.tokenId;
        listing.active = false;
        delete tokenToListing[tokenId];

        Unlisted(listing.seller, listingId, tokenId);
    }