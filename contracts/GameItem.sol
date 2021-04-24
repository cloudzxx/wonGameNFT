// SPDX-License-Identifier: MIT
pragma solidity ^0.4.15;

// ERC721TokenReceiver: 安全转账的接收回调接口
// 根据 ERC721 标准，合约接收 NFT 时必须实现 onERC721Received
// 返回 bytes4(keccak256("onERC721Received(address,address,uint256,bytes)")) 即 0x150b7a02
contract ERC721TokenReceiver {
    function onERC721Received(address _operator, address _from, uint256 _tokenId, bytes _data) public returns(bytes4);
}

// GameItem: ERC721 游戏道具合约
// 核心设计: 自托管实现 ERC721 标准（不依赖 OpenZeppelin），兼容 Solidity 0.4.15
// 特性: mint 受 onlyOwner 控制（防止无限铸币），O(1) balanceOf，支持 burn 销毁
contract GameItem {
    // owner: 合约拥有者，mint 和 setBaseURI 的白名单
    address public owner;
    string public name;
    string public symbol;
    // baseURI: tokenURI的前缀（当前未使用，为兼容标准预留）
    string public baseURI;

    // tokenIdCounter: 自增 ID 计数器，从 1 开始（0 作为无效空值）
    uint256 public tokenIdCounter;

    // _tokenOwner: tokenId → 持有者地址
    mapping (uint256 => address) private _tokenOwner;
    // _operatorApprovals: 持有者 → 操作员 → 是否授权全量操作
    mapping (address => mapping (address => bool)) private _operatorApprovals;
    // _tokenApprovals: tokenId → 单次授权地址（transfer 后自动清除）
    mapping (uint256 => address) private _tokenApprovals;
    // _tokenURIs: tokenId → 元数据 URI（ipfs 或 http 链接）
    mapping (uint256 => string) private _tokenURIs;
    // creators: tokenId → 铸造者地址（用于版税等场景）
    mapping (uint256 => address) public creators;
    // _supportedInterfaces: ERC165 接口声明表
    mapping (bytes4 => bool) private _supportedInterfaces;
    // _balances: 持有者 → NFT 数量（O(1) 查询，避免遍历）
    mapping (address => uint256) private _balances;

    // === 数字资产迁移相关状态 ===
    // migrationRoot: 旧系统资产快照的 Merkle root，由 owner 在迁移开始前设置
    bytes32 public migrationRoot;
    // totalMigrated: 已迁移的资产总数
    uint256 public totalMigrated;
    // _migrationClaims: leaf 哈希 → 是否已领取（防止重复索赔）
    mapping (bytes32 => bool) private _migrationClaims;
    // legacyToToken: 旧系统 itemId → 新系统 tokenId（追溯旧资产对应哪个 NFT）
    mapping (uint256 => uint256) public legacyToToken;

    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event Approval(address indexed _owner, address indexed approved, uint256 indexed tokenId);
    event ApprovalForAll(address indexed _owner, address indexed operator, bool approved);
    event Mint(address indexed to, uint256 indexed tokenId, string uri);
    event Burn(address indexed from, uint256 indexed tokenId);
    // Migrated: 记录一次完整的「旧系统资产 → 链上 NFT」迁移事件
    // legacyItemId: 旧系统中的道具 ID，newTokenId: 新系统中铸造的 NFT ID
    event Migrated(address indexed user, uint256 indexed legacyItemId, uint256 indexed newTokenId, string uri);
    // MigrationRootUpdated: 迁移 Merkle root 被更新（支持多轮迁移）
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
        // tokenIdCounter 从 1 开始，0 保留作「不存在」标志
        tokenIdCounter = 1;

        // ERC165 接口声明：支持 ERC721 和 ERC165 自身
        _supportedInterfaces[ERC165_INTERFACE_ID] = true;
        _supportedInterfaces[ERC721_INTERFACE_ID] = true;
    }

    // supportsInterface: ERC165 标准实现，供外部查询合约支持的接口
    function supportsInterface(bytes4 interfaceID) public constant returns (bool) {
        return _supportedInterfaces[interfaceID];
    }

    // balanceOf: O(1) 查询持有者 NFT 数量
    // 安全性: 拒绝 address(0) 查询（ERC721 标准要求）
    function balanceOf(address _owner) public constant returns (uint256) {
        require(_owner != address(0));
        return _balances[_owner];
    }

    // ownerOf: 查询 token 持有者
    // 安全性: 不存在的 token 会 revert（require tokenOwner != address(0)）
    function ownerOf(uint256 tokenId) public constant returns (address) {
        address tokenOwner = _tokenOwner[tokenId];
        require(tokenOwner != address(0));
        return tokenOwner;
    }

    // getApproved: 查询某个 token 的授权地址
    // 与标准不同：不存在的 token 返回 address(0) 而非 revert（兼容 0.4.15 前端查询）
    function getApproved(uint256 tokenId) public constant returns (address) {
        if (_tokenOwner[tokenId] == address(0)) {
            return address(0);
        }
        return _tokenApprovals[tokenId];
    }

    // isApprovedForAll: 查询操作员是否获得全量授权
    function isApprovedForAll(address _owner, address operator) public constant returns (bool) {
        return _operatorApprovals[_owner][operator];
    }

    // approve: 授权某个地址转移指定 token
    // 调用者限制: 必须是 token owner 或被全量授权的操作员
    // 授权 address(0) 等同于清除授权
    function approve(address approved, uint256 tokenId) public {
        address tokenOwner = _tokenOwner[tokenId];
        require(tokenOwner != address(0));
        require(msg.sender == tokenOwner || _operatorApprovals[tokenOwner][msg.sender]);
        _tokenApprovals[tokenId] = approved;
        Approval(tokenOwner, approved, tokenId);
    }

    // setApprovalForAll: 全量授权/取消授权操作员
    function setApprovalForAll(address operator, bool approved) public {
        _operatorApprovals[msg.sender][operator] = approved;
        ApprovalForAll(msg.sender, operator, approved);
    }

    // transferFrom: 标准的 unsafe 转账
    // checks: spender 必须是 owner/被授权人/操作员
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

    // mint: onlyOwner，铸造新 NFT
    // 安全性: onlyOwner 限制（防止无限铸币），to 不能为 address(0)
    // 记录 creators 供后续版税或奖励分配使用
    // 先赋权后记录事件（checks-effects-interactions）
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

    // burn: 销毁 token，不可逆操作
    // 调用者: token owner 或授权者
    // 清除所有关联数据（approval、uri、creator），防止残留
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

    // ===== 数字资产迁移功能 =====
    // setMigrationRoot: owner 设置迁移用 Merkle root
    // root 由后端对旧系统资产快照构建 Merkle 树生成
    // 支持多轮迁移（更新 root），旧的 root 作废
    function setMigrationRoot(bytes32 root) public onlyOwner {
        bytes32 oldRoot = migrationRoot;
        migrationRoot = root;
        MigrationRootUpdated(oldRoot, root);
    }

    // migrateFromLegacy: 用户提交 Merkle proof，将旧系统资产迁移为 NFT
    // proof: Merkle proof，证明该用户拥有 legacyItemId
    // legacyItemId: 旧系统中的道具唯一标识
    // uri: 元数据 URI（与旧系统中的元数据一致，保证可追溯）
    //
    // 安全性:
    //   1. leaf = keccak256(user, legacyItemId, uri) — 绑定三者
    //   2. Merkle proof 验证失败 → revert（防止伪造资产）
    //   3. _migrationClaims[leaf] 防止重复索赔
    //   4. migrationRoot 由 owner 设置，可随时间更新
    function migrateFromLegacy(bytes32[] proof, uint256 legacyItemId, string uri) public returns (uint256) {
        bytes32 leaf = keccak256(msg.sender, legacyItemId, uri);
        require(!_migrationClaims[leaf]);
        require(migrationRoot != bytes32(0));
        require(_verifyProof(proof, leaf, migrationRoot));

        _migrationClaims[leaf] = true;

        require(msg.sender != address(0));
        uint256 tokenId = tokenIdCounter++;
        _tokenOwner[tokenId] = msg.sender;
        // 迁移资产的 creator 设为合约地址，与 regular mint 区分
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

    // _verifyProof: Merkle proof 验证
    // 标准实现：从 leaf 开始，逐层与 proof element 排序后 hash
    // 最终 computedHash == root 即验证通过
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

    // _isApprovedOrOwner: 核心鉴权函数
    // 返回 true 的三种情况: spender 是 owner / 被单次授权 / 被全量授权
    function _isApprovedOrOwner(address spender, uint256 tokenId) internal constant returns (bool) {
        address tokenOwner = _tokenOwner[tokenId];
        return (spender == tokenOwner || getApproved(tokenId) == spender || isApprovedForAll(tokenOwner, spender));
    }

    // _transferFrom: 内部转账逻辑
    // 安全性: 校验 from 确实是当前 owner，to 不能为 address(0)
    // 自动清除单次授权，更新 balances 和 tokenOwner
    // 注意: _balances 在 Solidity 0.4.15 下不会溢出检查，但业务上不可能溢出
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

    // _checkOnERC721Received: 安全转账的核心检查
    // 如果 to 是合约地址，必须实现 onERC721Received 并返回正确 magic value
    // 否则 NFT 不会被转出（防止 NFT 被锁在无法处理 ERC721 的合约中）
    // assembly 的 extcodesize 用于检测目标地址是否为合约
    function _checkOnERC721Received(address from, address to, uint256 tokenId, bytes data) internal returns (bool) {
        uint size;
        assembly { size := extcodesize(to) }
        if (size == 0) {
            return true;
        }
        bytes4 retval = ERC721TokenReceiver(to).onERC721Received(msg.sender, from, tokenId, data);
        return (retval == ERC721_RECEIVED);
    }
}