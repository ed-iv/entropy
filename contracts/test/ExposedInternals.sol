// SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import "../Entropy.sol";

contract ExposedInternals is Entropy {
  
  function _getRarity(uint8 deckNum, uint8 genNum) external view returns (uint8) {
    return getRarity(deckNum, genNum);
  }

  
  function getPrice(uint8 deckNum, uint8 genNum, uint32 startTime) public view returns (uint) {   
      return _price(deckNum, genNum, startTime);
  }

    /// @notice - Rarity dependent price for chain purchases.
    function getChainPrice(uint8 deckNum, uint8 genNum) public view returns (uint) {
      return _chainPrice(deckNum, genNum);
    }

}