// SPDX-License-Identifier: MIT
pragma solidity ^0.4.15;

contract ERC721TokenReceiver {
    function onERC721Received(address _operator, address _from, uint256 _tokenId, bytes _data) public returns(bytes4);
}