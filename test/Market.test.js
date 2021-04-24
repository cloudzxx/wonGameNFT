const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("Market", function () {
  let gameItem;
  let market;
  let owner;
  let addr1;
  let addr2;
  let feeRecipient;

  const ONE_HOUR = 60 * 60;
  const ONE_DAY = 24 * ONE_HOUR;

  beforeEach(async () => {
    [owner, addr1, addr2, feeRecipient] = await ethers.getSigners();

    const GameItem = await ethers.getContractFactory("GameItem");
    gameItem = await GameItem.deploy();

    const Market = await ethers.getContractFactory("Market");
    market = await Market.deploy(
      gameItem.address,
      feeRecipient.address,
      250
    );

    await gameItem.mint(addr1.address, "uri1");
  });

  describe("Listing", function () {
    it("should list an item for sale", async () => {
      const tokenId = 1;
      const price = ethers.utils.parseEther("1");
      const duration = ONE_DAY;

      await gameItem.connect(addr1).setApprovalForAll(market.address, true);
      const tx = await market.connect(addr1).listItem(tokenId, price, duration);
      const receipt = await tx.wait();

      const event = receipt.events.find((e) => e.event === "Listed");
      expect(event).to.not.be.undefined;
      expect(await market.isListed(tokenId)).to.equal(true);
    });

    it("should fail when listing already listed token", async () => {
      const tokenId = 1;
      const price = ethers.utils.parseEther("1");
      const duration = ONE_DAY;

      await gameItem.connect(addr1).setApprovalForAll(market.address, true);
      await market.connect(addr1).listItem(tokenId, price, duration);

      await expect(
        market.connect(addr1).listItem(tokenId, price, duration)
      ).to.be.reverted;
    });

    it("should fail when listing without ownership", async () => {
      const tokenId = 1;
      const price = ethers.utils.parseEther("1");
      const duration = ONE_DAY;

      await expect(
        market.connect(addr2).listItem(tokenId, price, duration)
      ).to.be.reverted;
    });

    it("should fail when price is zero", async () => {
      const tokenId = 1;
      const price = 0;
      const duration = ONE_DAY;

      await gameItem.connect(addr1).setApprovalForAll(market.address, true);
      await expect(
        market.connect(addr1).listItem(tokenId, price, duration)
      ).to.be.reverted;
    });

    it("should fail when duration is too short", async () => {
      const tokenId = 1;
      const price = ethers.utils.parseEther("1");
      const duration = 60;

      await gameItem.connect(addr1).setApprovalForAll(market.address, true);
      await expect(
        market.connect(addr1).listItem(tokenId, price, duration)
      ).to.be.reverted;
    });

    it("should fail when duration is too long", async () => {
      const tokenId = 1;
      const price = ethers.utils.parseEther("1");
      const duration = 365 * ONE_DAY + 1;

      await gameItem.connect(addr1).setApprovalForAll(market.address, true);
      await expect(
        market.connect(addr1).listItem(tokenId, price, duration)
      ).to.be.reverted;
    });
  });

  describe("Unlisting", function () {
    it("should allow seller to unlist item", async () => {
      const tokenId = 1;
      const price = ethers.utils.parseEther("1");
      const duration = ONE_DAY;

      await gameItem.connect(addr1).setApprovalForAll(market.address, true);
      const listTx = await market.connect(addr1).listItem(tokenId, price, duration);
      const listReceipt = await listTx.wait();
      const listingId = listReceipt.events.find((e) => e.event === "Listed").args.listingId;

      await market.connect(addr1).unlistItem(listingId);

      expect(await market.isListed(tokenId)).to.equal(false);
    });

    it("should allow owner to unlist any item", async () => {
      const tokenId = 1;
      const price = ethers.utils.parseEther("1");
      const duration = ONE_DAY;

      await gameItem.connect(addr1).setApprovalForAll(market.address, true);
      const listTx = await market.connect(addr1).listItem(tokenId, price, duration);
      const listReceipt = await listTx.wait();
      const listingId = listReceipt.events.find((e) => e.event === "Listed").args.listingId;

      await market.unlistItem(listingId);

      expect(await market.isListed(tokenId)).to.equal(false);
    });

    it("should fail when non-seller tries to unlist", async () => {
      const tokenId = 1;
      const price = ethers.utils.parseEther("1");
      const duration = ONE_DAY;

      await gameItem.connect(addr1).setApprovalForAll(market.address, true);
      const listTx = await market.connect(addr1).listItem(tokenId, price, duration);
      const listReceipt = await listTx.wait();
      const listingId = listReceipt.events.find((e) => e.event === "Listed").args.listingId;

      await expect(
        market.connect(addr2).unlistItem(listingId)
      ).to.be.reverted;
    });
  });

  describe("Purchasing", function () {
    it("should purchase listed item", async () => {
      const tokenId = 1;
      const price = ethers.utils.parseEther("1");
      const duration = ONE_DAY;

      await gameItem.connect(addr1).setApprovalForAll(market.address, true);
      const listTx = await market.connect(addr1).listItem(tokenId, price, duration);
      const listReceipt = await listTx.wait();
      const listingId = listReceipt.events.find((e) => e.event === "Listed").args.listingId;

      await market.connect(addr2).purchaseItem(listingId, { value: price });

      expect(await gameItem.ownerOf(tokenId)).to.equal(addr2.address);
      expect(await market.isListed(tokenId)).to.equal(false);
    });

    it("should transfer payment to seller minus fee", async () => {
      const tokenId = 1;
      const price = ethers.utils.parseEther("1");
      const duration = ONE_DAY;

      await gameItem.connect(addr1).setApprovalForAll(market.address, true);
      const listTx = await market.connect(addr1).listItem(tokenId, price, duration);
      const listReceipt = await listTx.wait();
      const listingId = listReceipt.events.find((e) => e.event === "Listed").args.listingId;

      const sellerBalanceBefore = await ethers.provider.getBalance(addr1.address);

      await market.connect(addr2).purchaseItem(listingId, { value: price });

      const sellerBalanceAfter = await ethers.provider.getBalance(addr1.address);
      const expectedAmount = price.mul(975).div(1000);

      expect(sellerBalanceAfter.sub(sellerBalanceBefore)).to.equal(expectedAmount);
    });

    it("should fail when listing does not exist", async () => {
      const fakeListingId = "0x0000000000000000000000000000000000000000000000000000000000000001";
      const price = ethers.utils.parseEther("1");

      await expect(
        market.connect(addr2).purchaseItem(fakeListingId, { value: price })
      ).to.be.reverted;
    });

    it("should fail when payment is insufficient", async () => {
      const tokenId = 1;
      const price = ethers.utils.parseEther("1");
      const duration = ONE_DAY;

      await gameItem.connect(addr1).setApprovalForAll(market.address, true);
      const listTx = await market.connect(addr1).listItem(tokenId, price, duration);
      const listReceipt = await listTx.wait();
      const listingId = listReceipt.events.find((e) => e.event === "Listed").args.listingId;

      await expect(
        market.connect(addr2).purchaseItem(listingId, { value: ethers.utils.parseEther("0.5") })
      ).to.be.reverted;
    });
  });

  describe("Batch Purchasing", function () {
    beforeEach(async () => {
      await gameItem.mint(addr1.address, "uri2");
      await gameItem.mint(addr1.address, "uri3");
    });

    it("should purchase multiple items", async () => {
      await gameItem.connect(addr1).setApprovalForAll(market.address, true);

      const listTx1 = await market.connect(addr1).listItem(1, ethers.utils.parseEther("1"), ONE_DAY);
      const listTx2 = await market.connect(addr1).listItem(2, ethers.utils.parseEther("2"), ONE_DAY);
      const listTx3 = await market.connect(addr1).listItem(3, ethers.utils.parseEther("3"), ONE_DAY);

      const receipt1 = await listTx1.wait();
      const receipt2 = await listTx2.wait();
      const receipt3 = await listTx3.wait();

      const listingId1 = receipt1.events.find((e) => e.event === "Listed").args.listingId;
      const listingId2 = receipt2.events.find((e) => e.event === "Listed").args.listingId;
      const listingId3 = receipt3.events.find((e) => e.event === "Listed").args.listingId;

      const totalPrice = ethers.utils.parseEther("6");
      await market.connect(addr2).purchaseItems([listingId1, listingId2, listingId3], { value: totalPrice });

      expect(await gameItem.ownerOf(1)).to.equal(addr2.address);
      expect(await gameItem.ownerOf(2)).to.equal(addr2.address);
      expect(await gameItem.ownerOf(3)).to.equal(addr2.address);
    });

    it("should fail when batch size exceeds limit", async () => {
      const fakeListingIds = [];
      for (let i = 0; i < 101; i++) {
        fakeListingIds.push(ethers.utils.hexZeroPad(ethers.utils.hexlify(i), 32));
      }

      await expect(
        market.connect(addr2).purchaseItems(fakeListingIds, { value: ethers.utils.parseEther("101") })
      ).to.be.reverted;
    });
  });

  describe("Listing Management", function () {
    it("should allow updating listing price", async () => {
      const tokenId = 1;
      const originalPrice = ethers.utils.parseEther("1");
      const newPrice = ethers.utils.parseEther("2");
      const duration = ONE_DAY;

      await gameItem.connect(addr1).setApprovalForAll(market.address, true);
      const listTx = await market.connect(addr1).listItem(tokenId, originalPrice, duration);
      const listReceipt = await listTx.wait();
      const listingId = listReceipt.events.find((e) => e.event === "Listed").args.listingId;

      await market.connect(addr1).updateListingPrice(listingId, newPrice);

      const listing = await market.getListing(listingId);
      expect(listing.price).to.equal(newPrice);
    });

    it("should allow extending listing duration", async () => {
      const tokenId = 1;
      const price = ethers.utils.parseEther("1");
      const duration = ONE_DAY;
      const additionalDuration = ONE_HOUR;

      await gameItem.connect(addr1).setApprovalForAll(market.address, true);
      const listTx = await market.connect(addr1).listItem(tokenId, price, duration);
      const listReceipt = await listTx.wait();
      const listingId = listReceipt.events.find((e) => e.event === "Listed").args.listingId;

      await market.connect(addr1).extendListing(listingId, additionalDuration);

      const listing = await market.getListing(listingId);
      expect(listing.endTime).to.equal(
        listReceipt.events.find((e) => e.event === "Listed").args.endTime.add(additionalDuration)
      );
    });

    it("should fail when non-seller tries to extend listing", async () => {
      const tokenId = 1;
      const price = ethers.utils.parseEther("1");
      const duration = ONE_DAY;

      await gameItem.connect(addr1).setApprovalForAll(market.address, true);
      const listTx = await market.connect(addr1).listItem(tokenId, price, duration);
      const listReceipt = await listTx.wait();
      const listingId = listReceipt.events.find((e) => e.event === "Listed").args.listingId;

      await expect(
        market.connect(addr2).extendListing(listingId, ONE_HOUR)
      ).to.be.reverted;
    });
  });

  describe("Admin Functions", function () {
    it("should allow owner to update fee percent", async () => {
      const newFeePercent = 500;

      await market.updateFeePercent(newFeePercent);

      expect(await market.feePercent()).to.equal(newFeePercent);
    });

    it("should allow owner to update fee recipient", async () => {
      await market.updateFeeRecipient(addr2.address);

      expect(await market.feeRecipient()).to.equal(addr2.address);
    });

    it("should allow owner to transfer ownership", async () => {
      await market.transferOwnership(addr1.address);

      expect(await market.owner()).to.equal(addr1.address);
    });

    it("should fail when non-owner tries to update fee", async () => {
      await expect(
        market.connect(addr1).updateFeePercent(500)
      ).to.be.reverted;
    });

    it("should allow owner to cleanup expired listing", async () => {
      const tokenId = 1;
      const price = ethers.utils.parseEther("1");
      const duration = ONE_HOUR;

      await gameItem.connect(addr1).setApprovalForAll(market.address, true);
      const listTx = await market.connect(addr1).listItem(tokenId, price, duration);
      const listReceipt = await listTx.wait();
      const listingId = listReceipt.events.find((e) => e.event === "Listed").args.listingId;

      await ethers.provider.send("evm_increaseTime", [ONE_HOUR + 1]);
      await ethers.provider.send("evm_mine");

      await market.cleanupExpiredListing(listingId);

      expect(await market.isListed(tokenId)).to.equal(false);
    });
  });

  describe("View Functions", function () {
    it("should return correct listing info", async () => {
      const tokenId = 1;
      const price = ethers.utils.parseEther("1");
      const duration = ONE_DAY;

      await gameItem.connect(addr1).setApprovalForAll(market.address, true);
      const listTx = await market.connect(addr1).listItem(tokenId, price, duration);
      const listReceipt = await listTx.wait();
      const listingId = listReceipt.events.find((e) => e.event === "Listed").args.listingId;

      const listing = await market.getListing(listingId);

      expect(listing.seller).to.equal(addr1.address);
      expect(listing.tokenId).to.equal(tokenId);
      expect(listing.price).to.equal(price);
      expect(listing.active).to.equal(true);
    });

    it("should return correct listing ID for token", async () => {
      const tokenId = 1;
      const price = ethers.utils.parseEther("1");
      const duration = ONE_DAY;

      await gameItem.connect(addr1).setApprovalForAll(market.address, true);
      const listTx = await market.connect(addr1).listItem(tokenId, price, duration);
      const listReceipt = await listTx.wait();
      const expectedListingId = listReceipt.events.find((e) => e.event === "Listed").args.listingId;

      const actualListingId = await market.getListingId(tokenId);

      expect(actualListingId).to.equal(expectedListingId);
    });
  });
});