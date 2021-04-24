// SPDX-License-Identifier: MIT
pragma solidity ^0.4.15;

import "./GameItem.sol";

// Market: P2P 游戏道具 NFT 交易市场
// 核心设计: 订单簿模式，挂单 → 购买；支持单笔和批量交易
// 安全设计:
//   1. checks-effects-interactions 模式（先改状态再外部调用）
//   2. whenNotPaused 暂停保护
//   3. 购买时验证卖家仍持有 token（防止 stale listing）
//   4. 使用 call.value 替代 transfer 避免合约钱包 2300 gas DoS
//   5. 多付 ETH 自动退款
contract Market {
    address public owner;
    address public feeRecipient;
    uint256 public feePercent;
    bool public paused;

    // 挂单时长限制：最短 1 小时，最长 365 天
    uint256 public constant MIN_LISTING_DURATION = 1 hours;
    uint256 public constant MAX_LISTING_DURATION = 365 days;

    // itemContract: 支持的 NFT 合约地址，构造时传入
    GameItem public itemContract;

    // Listing: 挂单数据结构
    // seller: 卖家地址，谁挂单谁就是 seller
    // active: 标记是否有效（false 表示已成交/已取消/已过期）
    struct Listing {
        address seller;
        uint256 tokenId;
        uint256 price;
        uint256 startTime;
        uint256 endTime;
        bool active;
    }

    // listings: listingId → Listing 详情
    // listingId = keccak256(seller, tokenId, price, startTime, endTime) 防止碰撞
    mapping (bytes32 => Listing) public listings;
    // tokenToListing: tokenId → listingId 的反向索引（用于快速查询）
    mapping (uint256 => bytes32) public tokenToListing;
    // purchaseCount: listingId → 购买次数（统计用）
    mapping (bytes32 => uint256) public purchaseCount;

    event Listed(address indexed seller, bytes32 indexed listingId, uint256 tokenId, uint256 price, uint256 startTime, uint256 endTime);
    event Unlisted(address indexed seller, bytes32 indexed listingId, uint256 tokenId);
    event Purchased(address indexed buyer, address indexed seller, bytes32 indexed listingId, uint256 tokenId, uint256 price, uint256 totalPaid);
    event FeeUpdated(uint256 oldFee, uint256 newFee);
    event FeeRecipientUpdated(address oldRecipient, address newRecipient);
    event OwnershipTransferred(address indexed oldOwner, address indexed newOwner);
    event Paused();
    event Unpaused();
    event EtherWithdrawn(address indexed to, uint256 amount);

    modifier onlyOwner() {
        require(msg.sender == owner);
        _;
    }

    modifier whenNotPaused() {
        require(!paused);
        _;
    }

    // Market: 构造时绑定 GameItem 合约地址、手续费接收方和费率
    // feePercent 以 basis point 为单位：250 = 2.5%，上限 1000 = 10%
    function Market(address itemContractAddress, address feeRecipient_, uint256 feePercent_) public {
        require(itemContractAddress != address(0));
        require(feeRecipient_ != address(0));
        require(feePercent_ <= 1000);

        itemContract = GameItem(itemContractAddress);
        feeRecipient = feeRecipient_;
        feePercent = feePercent_;
        owner = msg.sender;
    }

    // listItem: 卖家挂单出售 NFT
    // 前置条件:
    //   1. price > 0
    //   2. duration 在 [MIN_LISTING_DURATION, MAX_LISTING_DURATION] 范围
    //   3. 调用者确实是 token 持有者
    //   4. 调用者已授权本合约（approve 或 setApprovalForAll）
    //   5. token 当前未挂单
    // listingId 由 keccak256 生成，避免 listingId 冲突
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

    // unlistItem: 卖家取消挂单，或 owner 强制下架
    // active 设为 false，删除反向索引
    function unlistItem(bytes32 listingId) public whenNotPaused {
        Listing storage listing = listings[listingId];

        require(listing.active);
        require(listing.seller == msg.sender || msg.sender == owner);

        uint256 tokenId = listing.tokenId;
        listing.active = false;
        delete tokenToListing[tokenId];

        Unlisted(listing.seller, listingId, tokenId);
    }

    // purchaseItem: 买家购买单件道具
    // 安全流程 (checks-effects-interactions):
    //   1. 校验 listing 有效、在时间内、价值充足、卖家仍持有 token
    //   2. 计算费用（sellerAmount + fee = price）
    //   3. 先改状态（mark inactive），再发外部调用
    //      防止重入攻击：状态已变，重入后 listing.active = false 会 revert
    //   4. 外部调用：transferFrom 转 NFT，call.value 转 ETH 给卖家和平台
    //   5. 多付部分（excess）退回给买家
    // 安全性说明:
    //   - 使用 call.value 而非 transfer：转发所有 gas 避免合约钱包无法收款
    //   - call.value 后有 require(success)：确保 eth 转成功，失败则 revert 回滚全部
    //   - excess 使用 transfer（仅 2300 gas）即可，退款给 EOA 足够
    function purchaseItem(bytes32 listingId) public payable whenNotPaused {
        Listing storage listing = listings[listingId];

        require(listing.active);
        require(now >= listing.startTime);
        require(now <= listing.endTime);

        uint256 price = listing.price;
        uint256 tokenId = listing.tokenId;
        address seller = listing.seller;

        require(msg.value >= price);
        // 安全: 校验卖家仍持有 token，防止 stale listing 浪费买家 gas
        require(itemContract.ownerOf(tokenId) == seller);

        uint256 fee = (price * feePercent) / 10000;
        uint256 sellerAmount = price - fee;

        // checks-effects-interactions: 先改状态
        listing.active = false;
        delete tokenToListing[tokenId];
        purchaseCount[listingId]++;

        // 外部调用: 转移 NFT（需卖家已授权本合约）
        itemContract.transferFrom(seller, msg.sender, tokenId);

        // 外部调用: ETH 转账给卖家
        // call.value 转发所有 gas，兼容合约钱包收款
        bool success;
        if (sellerAmount > 0) {
            success = seller.call.value(sellerAmount)();
            require(success);
        }

        // 外部调用: ETH 转账给平台
        if (fee > 0) {
            success = feeRecipient.call.value(fee)();
            require(success);
        }

        // 多付退款：使用 transfer 因为退款给 EOA 只需 2300 gas
        uint256 excess = msg.value - price;
        if (excess > 0) {
            msg.sender.transfer(excess);
        }

        Purchased(msg.sender, seller, listingId, tokenId, price, msg.value);
    }

    // purchaseItems: 批量购买
    // 实现两阶段处理:
    //   第1阶段: 遍历所有 listingId 校验合法性并计算总价
    //   第2阶段: 逐个执行转账（先改状态再外部调用）
    // 两阶段设计目的: 避免部分执行后因某个 item 失败导致不一致
    // 批量上限 100，防止单次交易 gas 超限
    function purchaseItems(bytes32[] listingIds) public payable whenNotPaused {
        require(listingIds.length > 0);
        require(listingIds.length <= 100);

        uint256 totalPrice = 0;

        // 第一阶段: 校验 + 算账
        for (uint256 i = 0; i < listingIds.length; i++) {
            Listing storage listing = listings[listingIds[i]];
            require(listing.active);
            require(now >= listing.startTime);
            require(now <= listing.endTime);
            totalPrice += listing.price;
        }

        require(msg.value >= totalPrice);

        // 第二阶段: 逐个执行
        for (i = 0; i < listingIds.length; i++) {
            Listing storage curListing = listings[listingIds[i]];

            uint256 price = curListing.price;
            uint256 tokenId = curListing.tokenId;
            address seller = curListing.seller;

            require(itemContract.ownerOf(tokenId) == seller);

            uint256 fee = (price * feePercent) / 10000;
            uint256 sellerAmount = price - fee;

            // checks-effects-interactions
            curListing.active = false;
            delete tokenToListing[tokenId];
            purchaseCount[listingIds[i]]++;

            itemContract.transferFrom(seller, msg.sender, tokenId);

            bool success;
            if (sellerAmount > 0) {
                success = seller.call.value(sellerAmount)();
                require(success);
            }

            if (fee > 0) {
                success = feeRecipient.call.value(fee)();
                require(success);
            }

            Purchased(msg.sender, seller, listingIds[i], tokenId, price, price);
        }

        // 多付退款
        uint256 excess = msg.value - totalPrice;
        if (excess > 0) {
            msg.sender.transfer(excess);
        }
    }

    // extendListing: 卖家延长挂单有效时间
    function extendListing(bytes32 listingId, uint256 additionalDuration) public whenNotPaused {
        require(additionalDuration > 0);
        require(additionalDuration <= MAX_LISTING_DURATION);

        Listing storage listing = listings[listingId];

        require(listing.active);
        require(listing.seller == msg.sender);

        uint256 currentEnd = listing.endTime;
        require(now <= currentEnd);

        listing.endTime = currentEnd + additionalDuration;

        Listed(listing.seller, listingId, listing.tokenId, listing.price, listing.startTime, listing.endTime);
    }

    // updateListingPrice: 卖家修改挂单价格
    function updateListingPrice(bytes32 listingId, uint256 newPrice) public whenNotPaused {
        require(newPrice > 0);

        Listing storage listing = listings[listingId];

        require(listing.active);
        require(listing.seller == msg.sender);

        // 先发 event 记录旧价格，再更新（event 在 value 被改前发出）
        Listed(listing.seller, listingId, listing.tokenId, newPrice, listing.startTime, listing.endTime);

        listing.price = newPrice;
    }

    function isListed(uint256 tokenId) public constant returns (bool) {
        bytes32 listingId = tokenToListing[tokenId];
        if (listingId == bytes32(0)) return false;
        return listings[listingId].active && now <= listings[listingId].endTime;
    }

    function getListing(bytes32 listingId) public constant returns (
        address seller,
        uint256 tokenId,
        uint256 price,
        uint256 startTime,
        uint256 endTime,
        bool active
    ) {
        Listing memory listing = listings[listingId];
        return (listing.seller, listing.tokenId, listing.price, listing.startTime, listing.endTime, listing.active);
    }

    function getListingId(uint256 tokenId) public constant returns (bytes32) {
        return tokenToListing[tokenId];
    }

    function updateFeePercent(uint256 newFeePercent) public onlyOwner {
        require(newFeePercent <= 1000);
        uint256 oldFee = feePercent;
        feePercent = newFeePercent;
        FeeUpdated(oldFee, newFeePercent);
    }

    function updateFeeRecipient(address newRecipient) public onlyOwner {
        require(newRecipient != address(0));
        address oldRecipient = feeRecipient;
        feeRecipient = newRecipient;
        FeeRecipientUpdated(oldRecipient, newRecipient);
    }

    function transferOwnership(address newOwner) public onlyOwner {
        require(newOwner != address(0));
        address oldOwner = owner;
        owner = newOwner;
        OwnershipTransferred(oldOwner, newOwner);
    }

    // cleanupExpiredListing: owner 清理过期挂单
    // 需要 now > endTime，可恢复被过期挂单占用的 token 索引
    function cleanupExpiredListing(bytes32 listingId) public onlyOwner {
        Listing storage listing = listings[listingId];
        require(listing.active);
        require(now > listing.endTime);

        uint256 tokenId = listing.tokenId;
        listing.active = false;
        delete tokenToListing[tokenId];

        Unlisted(listing.seller, listingId, tokenId);
    }

    // withdrawAccidentalNFT: 提取误转入本合约的 NFT
    // 本合约不应持有 NFT（交易直接从 seller 到 buyer），但用户可能误转
    function withdrawAccidentalNFT(address nftAddress, uint256 tokenId, address recipient) public onlyOwner {
        require(recipient != address(0));
        require(GameItem(nftAddress).ownerOf(tokenId) == address(this));
        GameItem(nftAddress).transferFrom(address(this), recipient, tokenId);
    }

    // withdrawEther: owner 提取合约中积累的 ETH
    // 来源: 用户误转入（fallback）或极端情况下的余额
    function withdrawEther() public onlyOwner {
        uint256 balance = address(this).balance;
        require(balance > 0);
        owner.transfer(balance);
        EtherWithdrawn(owner, balance);
    }

    function pause() public onlyOwner {
        require(!paused);
        paused = true;
        Paused();
    }

    function unpause() public onlyOwner {
        require(paused);
        paused = false;
        Unpaused();
    }

    // fallback: 接收 ETH，要求必须携带正数值
    // 不直接参与交易逻辑，仅接收错误转入的 ETH
    function () external payable {
        require(msg.value > 0);
    }
}