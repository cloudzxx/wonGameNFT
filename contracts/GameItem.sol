// SPDX-License-Identifier: MIT
pragma solidity ^0.4.15;

contract ERC721TokenReceiver {
    function onERC721Received(address _operator, address _from, uint256 _tokenId, bytes _data) public returns(bytes4);
}

contract GameItem {
    address public owner;
    string public name;
    string public symbol;
    string public baseURI;

    uint256 public tokenIdCounter;

    mapping (uint256 => address) private _tokenOwner;
    mapping (address => mapping (address => bool)) private _operatorApprovals;
    mapping (uint256 => address) private _tokenApprovals;
    mapping (uint256 => string) private _tokenURIs;
    mapping (uint256 => address) public creators;
    mapping (bytes4 => bool) private _supportedInterfaces;
    mapping (address => uint256) private _balances;
    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event Approval(address indexed _owner, address indexed approved, uint256 indexed tokenId);
    event ApprovalForAll(address indexed _owner, address indexed operator, bool approved);
    event Mint(address indexed to, uint256 indexed tokenId, string uri);
    event Burn(address indexed from, uint256 indexed tokenId);
    bytes4 constant ERC165_INTERFACE_ID = bytes4(0x01ffc9a7);
    bytes4 constant ERC721_INTERFACE_ID = bytes4(0x80ac58cd);
    bytes4 constant ERC721_RECEIVED = bytes4(0x150b7a02);
    function GameItem() public {
        owner = msg.sender;
        name = "GameItem";
        symbol = "GI";
        baseURI = "";
        tokenIdCounter = 1;

        _supportedInterfaces[ERC165_INTERFACE_ID] = true;
        _supportedInterfaces[ERC721_INTERFACE_ID] = true;
    }

    function supportsInterface(bytes4 interfaceID) public constant returns (bool) {
        return _supportedInterfaces[interfaceID];
    }