const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("GameItem", function () {
  let gameItem;
  let owner;
  let addr1;
  let addr2;

  beforeEach(async () => {
    [owner, addr1, addr2] = await ethers.getSigners();
    const GameItem = await ethers.getContractFactory("GameItem");
    gameItem = await GameItem.deploy();
  });

  it("should deploy with correct name and symbol", async () => {
    expect(await gameItem.name()).to.equal("GameItem");
    expect(await gameItem.symbol()).to.equal("GI");
  });

  it("should support ERC721 interface", async () => {
    const ERC721_INTERFACE_ID = "0x80ac58cd";
    expect(await gameItem.supportsInterface(ERC721_INTERFACE_ID)).to.equal(true);
  });

  it("should mint new NFT and assign to recipient", async () => {
    const uri = "ipfs://example/token/1";
    await gameItem.mint(addr1.address, uri);

    expect(await gameItem.ownerOf(1)).to.equal(addr1.address);
    expect(await gameItem.tokenURI(1)).to.equal(uri);
  });

  it("should track creator of each token", async () => {
    const uri = "ipfs://example/token/1";
    await gameItem.mint(addr1.address, uri);

    expect(await gameItem.creators(1)).to.equal(owner.address);
  });

  it("should correctly calculate balance", async () => {
    await gameItem.mint(owner.address, "uri1");
    await gameItem.mint(owner.address, "uri2");
    await gameItem.mint(addr1.address, "uri3");

    expect(await gameItem.balanceOf(owner.address)).to.equal(2);
    expect(await gameItem.balanceOf(addr1.address)).to.equal(1);
  });

  it("should transfer NFT between owners", async () => {
    const uri = "ipfs://example/token/1";
    await gameItem.mint(addr1.address, uri);

    await gameItem.connect(addr1).transferFrom(addr1.address, addr2.address, 1);

    expect(await gameItem.ownerOf(1)).to.equal(addr2.address);
  });

  it("should approve address for single NFT", async () => {
    const uri = "ipfs://example/token/1";
    await gameItem.mint(owner.address, uri);

    await gameItem.approve(addr1.address, 1);

    expect(await gameItem.getApproved(1)).to.equal(addr1.address);
  });

  it("should set operator approval for all NFTs", async () => {
    await gameItem.setApprovalForAll(addr1.address, true);

    expect(await gameItem.isApprovedForAll(owner.address, addr1.address)).to.equal(true);
  });

  it("should fail when checking owner of non-existent token", async () => {
    await expect(gameItem.ownerOf(999)).to.be.reverted;
  });

  it("should fail when balanceOf address is zero", async () => {
    await expect(
      gameItem.balanceOf("0x0000000000000000000000000000000000000000")
    ).to.be.reverted;
  });

  it("should clear approval on transfer", async () => {
    const uri = "ipfs://example/token/1";
    await gameItem.mint(owner.address, uri);

    await gameItem.approve(addr1.address, 1);
    await gameItem.transferFrom(owner.address, addr2.address, 1);

    expect(await gameItem.getApproved(1)).to.equal(
      "0x0000000000000000000000000000000000000000"
    );
  });

  it("should emit Mint event on mint", async () => {
    const uri = "ipfs://example/token/1";
    const tx = await gameItem.mint(addr1.address, uri);
    const receipt = await tx.wait();

    const event = receipt.events.find((e) => e.event === "Mint");
    expect(event).to.not.be.undefined;
    expect(event.args.to).to.equal(addr1.address);
  });

  describe("Migration", function () {
    // Merkle tree helper: compute leaf = keccak256(user, legacyItemId, uri)
    function makeLeaf(user, id, uri) {
      return ethers.utils.solidityKeccak256(
        ["address", "uint256", "string"],
        [user, id, uri]
      );
    }

    // Merkle tree helper: build tree and return root
    function getMerkleRoot(leaves) {
      if (leaves.length === 0) return ethers.constants.HashZero;
      let layer = leaves;
      while (layer.length > 1) {
        const nextLayer = [];
        for (let i = 0; i < layer.length; i += 2) {
          if (i + 1 < layer.length) {
            const a = layer[i];
            const b = layer[i + 1];
            nextLayer.push(
              ethers.utils.solidityKeccak256(
                ["bytes32", "bytes32"],
                [a < b ? a : b, a < b ? b : a]
              )
            );
          } else {
            nextLayer.push(layer[i]);
          }
        }
        layer = nextLayer;
      }
      return layer[0];
    }

    // Merkle tree helper: generate proof for leaf at targetIndex
    function getMerkleProof(leaves, targetIndex) {
      const proof = [];
      let layer = leaves;
      let idx = targetIndex;
      while (layer.length > 1) {
        const nextLayer = [];
        for (let i = 0; i < layer.length; i += 2) {
          if (i + 1 < layer.length) {
            const a = layer[i];
            const b = layer[i + 1];
            const parent = ethers.utils.solidityKeccak256(
              ["bytes32", "bytes32"],
              [a < b ? a : b, a < b ? b : a]
            );
            nextLayer.push(parent);
            if (i === idx) {
              proof.push(b);
            } else if (i + 1 === idx) {
              proof.push(a);
            }
          } else {
            nextLayer.push(layer[i]);
          }
        }
        idx = Math.floor(idx / 2);
        layer = nextLayer;
      }
      return proof;
    }

    it("should reject migration when root not set", async () => {
      await expect(
        gameItem.connect(addr1).migrateFromLegacy([], 1, "uri")
      ).to.be.reverted;
    });

    it("should migrate legacy asset to NFT", async () => {
      const legacyItemId = 42;
      const uri = "ipfs://legacy/item/42";
      const leaf = makeLeaf(addr1.address, legacyItemId, uri);
      const root = getMerkleRoot([leaf]);
      const proof = getMerkleProof([leaf], 0);

      await gameItem.setMigrationRoot(root);

      const tx = await gameItem.connect(addr1).migrateFromLegacy(proof, legacyItemId, uri);
      const receipt = await tx.wait();

      const tokenId = 1;
      expect(await gameItem.ownerOf(tokenId)).to.equal(addr1.address);
      expect(await gameItem.tokenURI(tokenId)).to.equal(uri);
      expect(await gameItem.legacyToToken(legacyItemId)).to.equal(tokenId);
      expect(await gameItem.totalMigrated()).to.equal(1);

      const migratedEvent = receipt.events.find((e) => e.event === "Migrated");
      expect(migratedEvent).to.not.be.undefined;
      expect(migratedEvent.args.user).to.equal(addr1.address);
      expect(migratedEvent.args.legacyItemId).to.equal(legacyItemId);
      expect(migratedEvent.args.newTokenId).to.equal(tokenId);
    });

    it("should reject double migration of same asset", async () => {
      const legacyItemId = 42;
      const uri = "ipfs://legacy/item/42";
      const leaf = makeLeaf(addr1.address, legacyItemId, uri);
      const root = getMerkleRoot([leaf]);
      const proof = getMerkleProof([leaf], 0);

      await gameItem.setMigrationRoot(root);
      await gameItem.connect(addr1).migrateFromLegacy(proof, legacyItemId, uri);

      await expect(
        gameItem.connect(addr1).migrateFromLegacy(proof, legacyItemId, uri)
      ).to.be.reverted;
    });

    it("should reject migration with invalid proof", async () => {
      const realItem = makeLeaf(addr1.address, 1, "real");
      const fakeItem = makeLeaf(addr2.address, 2, "fake");
      const root = getMerkleRoot([realItem, fakeItem]);
      const fakeProof = getMerkleProof([realItem, fakeItem], 0);

      await gameItem.setMigrationRoot(root);

      await expect(
        gameItem.connect(addr2).migrateFromLegacy(fakeProof, 2, "fake")
      ).to.be.reverted;
    });

    it("should support multiple concurrent migrations", async () => {
      const leaves = [
        makeLeaf(addr1.address, 1, "uri1"),
        makeLeaf(addr1.address, 2, "uri2"),
        makeLeaf(addr2.address, 3, "uri3"),
      ];
      const root = getMerkleRoot(leaves);
      await gameItem.setMigrationRoot(root);

      const proof1 = getMerkleProof(leaves, 0);
      await gameItem.connect(addr1).migrateFromLegacy(proof1, 1, "uri1");

      const proof2 = getMerkleProof(leaves, 1);
      await gameItem.connect(addr1).migrateFromLegacy(proof2, 2, "uri2");

      const proof3 = getMerkleProof(leaves, 2);
      await gameItem.connect(addr2).migrateFromLegacy(proof3, 3, "uri3");

      expect(await gameItem.balanceOf(addr1.address)).to.equal(2);
      expect(await gameItem.balanceOf(addr2.address)).to.equal(1);
      expect(await gameItem.totalMigrated()).to.equal(3);
    });
  });
});