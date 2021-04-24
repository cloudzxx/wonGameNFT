require("@nomiclabs/hardhat-waffle");

module.exports = {
  solidity: {
    version: "0.4.15",
    settings: {
      optimizer: {
        enabled: true,
        runs: 200
      }
    }
  },
  paths: {
    sources: "./contracts",
    tests: "./test",
    cache: "./cache",
    artifacts: "./artifacts"
  }
};