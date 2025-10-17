// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract Token is ERC721,Ownable{
    uint256 public tokenCounter;
    mapping(uint256 => string)private _tokenURIs;

    constructor() ERC721("Guardian Token","GDT"){
        tokenCounter=0;
    }

    function mintNFT(address recipient , string memory tokenURI) public onlyOwner returns(uint256){
        uint256 newtokenID = tokenCounter;
        _safeMint(recipient,newtokenID);
        _setTokenURI(newtokenID,tokenURI);
        tokenCounter++;
        return newtokenID;

    }

    function _setTokenURI(uint256 tokenID , string memory tokenURI)internal {
        _tokenURIs[tokenID]=tokenURI;
    }

    function tokenURI(uint256 tokenID)public view override returns(string memory){
        return _tokenURIs[tokenID];
    }
}