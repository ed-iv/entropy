// SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import "../Entropy.sol";

contract ExposedInternals is Entropy {
  

  constructor (uint8[] memory rarity) Entropy(rarity) {}

  function _getRarity(uint8 deckNum, uint8 genNum) external view returns (uint8) {
    return getRarity(deckNum, genNum);
  }
}