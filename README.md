# WonGameNFT

基于 Solidity 0.4.15 的游戏道具 NFT 交易平台，支持 ERC721 标准道具和链上交易市场。

## 合约概述

### GameItem.sol
ERC721 NFT 合约，用于游戏道具的铸造和转移。

**主要功能：**
- `mint(address to, string uri)` - 铸造新 NFT
- `transferFrom(address from, address to, uint256 tokenId)` - 转移 NFT
- `approve(address approved, uint256 tokenId)` - 授权单个 NFT
- `setApprovalForAll(address operator, bool approved)` - 全量授权
- `balanceOf(address owner)` - 查询 NFT 余额
- `ownerOf(uint256 tokenId)` - 查询 NFT 所有者

### Market.sol
游戏道具交易市场合约。

**主要功能：**
- `listItem(uint256 tokenId, uint256 price, uint256 duration)` - 挂单出售
- `unlistItem(bytes32 listingId)` - 下架/取消挂单
- `purchaseItem(bytes32 listingId)` - 购买单个道具
- `purchaseItems(bytes32[] listingIds)` - 批量购买
- `updateListingPrice(bytes32 listingId, uint256 newPrice)` - 修改价格
- `extendListing(bytes32 listingId, uint256 additionalDuration)` - 延长挂单时间

**市场参数：**
- 最低挂单时长：1 小时
- 最高挂单时长：365 天
- 平台费率：默认 2.5% (250 basis points)，最高 10%

## 安装

```bash
npm install
```

## 编译

```bash
npm run compile
```

## 测试

```bash
npm test
```

## 项目结构

```
├── contracts/
│   ├── GameItem.sol    # ERC721 NFT 合约
│   └── Market.sol      # 市场交易合约
├── test/
│   ├── GameItem.test.js # GameItem 合约测试
│   └── Market.test.js   # Market 合约测试
├── hardhat.config.js    # Hardhat 配置
├── package.json
└── README.md
```

## 使用流程

### 1. 部署合约

```javascript
const GameItem = await ethers.getContractFactory("GameItem");
const gameItem = await GameItem.deploy();

const Market = await ethers.getContractFactory("Market");
const market = await Market.deploy(
  gameItem.address,      // GameItem 合约地址
  feeRecipient.address,  // 手续费接收地址
  250                    // 手续费比例 (basis points)
);
```

### 2. 铸造游戏道具

```javascript
await gameItem.mint(playerAddress, "ipfs://example/item/1");
```

### 3. 挂单出售

```javascript
// 授权市场合约转移 NFT
await gameItem.setApprovalForAll(market.address, true);

// 挂单出售
const duration = 24 * 60 * 60; // 1天
const listingId = await market.listItem(tokenId, price, duration);
```

### 4. 购买道具

```javascript
await market.purchaseItem(listingId, { value: price });
```

## 安全注意事项

1. 挂单前需先授权市场合约转移 NFT
2. 建议使用 `setApprovalForAll` 授权而非单独授权
3. 批量购买有 100 个道具的上限
4. 市场合约仅支持 GameItem 类型 NFT

## 技术栈

- Solidity 0.4.15
- Hardhat
- ethers.js
- Waffle + Chai