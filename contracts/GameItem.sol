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

    bytes32 public migrationRoot;
    uint256 public totalMigrated;
    mapping (bytes32 => bool) private _migrationClaims;
    mapping (uint256 => uint256) public legacyToToken;

    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event Approval(address indexed _owner, address indexed approved, uint256 indexed tokenId);
    event ApprovalForAll(address indexed _owner, address indexed operator, bool approved);
    event Mint(address indexed to, uint256 indexed tokenId, string uri);
    event Burn(address indexed from, uint256 indexed tokenId);
    event Migrated(address indexed user, uint256 indexed legacyItemId, uint256 indexed newTokenId, string uri);
    event MigrationRootUpdated(bytes32 oldRoot, bytes32 newRoot);
    bytes4 constant ERC165_INTERFACE_ID = bytes4(0x01ffc9a7);
    bytes4 constant ERC721_INTERFACE_ID = bytes4(0x80ac58cd);
    bytes4 constant ERC721_RECEIVED = bytes4(0x150b7a02);
    modifier onlyOwner() {
        require(msg.sender == owner);
        _;
    }

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

    function balanceOf(address _owner) public constant returns (uint256) {
        require(_owner != address(0));
        return _balances[_owner];
    }

    function ownerOf(uint256 tokenId) public constant returns (address) {
        address tokenOwner = _tokenOwner[tokenId];
        require(tokenOwner != address(0));
        return tokenOwner;
    }

    function getApproved(uint256 tokenId) public constant returns (address) {
        if (_tokenOwner[tokenId] == address(0)) {
            return address(0);
        }
        return _tokenApprovals[tokenId];
    }

    function isApprovedForAll(address _owner, address operator) public constant returns (bool) {
        return _operatorApprovals[_owner][operator];
    }

    function approve(address approved, uint256 tokenId) public {
        address tokenOwner = _tokenOwner[tokenId];
        require(tokenOwner != address(0));
        require(msg.sender == tokenOwner || _operatorApprovals[tokenOwner][msg.sender]);
        _tokenApprovals[tokenId] = approved;
        Approval(tokenOwner, approved, tokenId);
    }

    function setApprovalForAll(address operator, bool approved) public {
        _operatorApprovals[msg.sender][operator] = approved;
        ApprovalForAll(msg.sender, operator, approved);
    }

    function transferFrom(address from, address to, uint256 tokenId) public {
        require(_isApprovedOrOwner(msg.sender, tokenId));
        _transferFrom(from, to, tokenId);
    }

    function safeTransferFrom(address from, address to, uint256 tokenId) public {
        _safeTransferFrom(from, to, tokenId, "");
    }

    function safeTransferFrom(address from, address to, uint256 tokenId, bytes data) public {
        _safeTransferFrom(from, to, tokenId, data);
    }

    function mint(address to, string uri) public onlyOwner returns (uint256) {
        require(to != address(0));
        uint256 tokenId = tokenIdCounter++;
        _tokenOwner[tokenId] = to;
        creators[tokenId] = msg.sender;
        _tokenURIs[tokenId] = uri;
        _balances[to]++;

        Mint(to, tokenId, uri);
        Transfer(address(0), to, tokenId);

        return tokenId;
    }

    function burn(uint256 tokenId) public {
        address tokenOwner = _tokenOwner[tokenId];
        require(tokenOwner != address(0));
        require(msg.sender == tokenOwner || _isApprovedOrOwner(msg.sender, tokenId));

        delete _tokenApprovals[tokenId];
        delete _tokenURIs[tokenId];
        delete creators[tokenId];
        _tokenOwner[tokenId] = address(0);
        _balances[tokenOwner]--;

        Burn(tokenOwner, tokenId);
        Transfer(tokenOwner, address(0), tokenId);
    }

    function tokenURI(uint256 tokenId) public constant returns (string) {
        require(_tokenOwner[tokenId] != address(0));
        return _tokenURIs[tokenId];
    }

    function setBaseURI(string uri) public {
        baseURI = uri;
    }
    function setMigrationRoot(bytes32 root) public onlyOwner {
        bytes32 oldRoot = migrationRoot;
        migrationRoot = root;
        MigrationRootUpdated(oldRoot, root);
    }

    function migrateFromLegacy(bytes32[] proof, uint256 legacyItemId, string uri) public returns (uint256) {
        bytes32 leaf = keccak256(msg.sender, legacyItemId, uri);
        require(!_migrationClaims[leaf]);
        require(migrationRoot != bytes32(0));
        require(_verifyProof(proof, leaf, migrationRoot));

        _migrationClaims[leaf] = true;

        require(msg.sender != address(0));
        uint256 tokenId = tokenIdCounter++;
        _tokenOwner[tokenId] = msg.sender;
        creators[tokenId] = address(this);
        _tokenURIs[tokenId] = uri;
        _balances[msg.sender]++;

        legacyToToken[legacyItemId] = tokenId;
        totalMigrated++;

        Mint(msg.sender, tokenId, uri);
        Transfer(address(0), msg.sender, tokenId);
        Migrated(msg.sender, legacyItemId, tokenId, uri);

        return tokenId;
    }

    function _verifyProof(bytes32[] proof, bytes32 leaf, bytes32 root) internal constant returns (bool) {
        bytes32 computedHash = leaf;
        for (uint256 i = 0; i < proof.length; i++) {
            bytes32 proofElement = proof[i];
            if (computedHash < proofElement) {
                computedHash = keccak256(computedHash, proofElement);
            } else {
                computedHash = keccak256(proofElement, computedHash);
            }
        }
        return computedHash == root;
    }
    function _isApprovedOrOwner(address spender, uint256 tokenId) internal constant returns (bool) {
        address tokenOwner = _tokenOwner[tokenId];
        return (spender == tokenOwner || getApproved(tokenId) == spender || isApprovedForAll(tokenOwner, spender));
    }

    function _transferFrom(address from, address to, uint256 tokenId) internal {
        require(_tokenOwner[tokenId] == from);
        require(to != address(0));

        delete _tokenApprovals[tokenId];

        _balances[from]--;
        _balances[to]++;
        _tokenOwner[tokenId] = to;

        Transfer(from, to, tokenId);
    }

    function _safeTransferFrom(address from, address to, uint256 tokenId, bytes data) internal {
        transferFrom(from, to, tokenId);
        require(_checkOnERC721Received(from, to, tokenId, data));
    }

    function _checkOnERC721Received(address from, address to, uint256 tokenId, bytes data) internal returns (bool) {
        uint size;
        assembly { size := extcodesize(to) }
        if (size == 0) {
            return true;
        }
        bytes4 retval = ERC721TokenReceiver(to).onERC721Received(msg.sender, from, tokenId, data);
        return (retval == ERC721_RECEIVED);
    }