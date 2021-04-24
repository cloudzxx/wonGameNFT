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