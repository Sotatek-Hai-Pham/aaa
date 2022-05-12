pragma solidity ^0.8.4;

contract SimpleStorage {
  uint256 public num = 0;

  function setValue(uint256 _num) external {
    num = _num;
  }

  function getValue() external view returns(uint256) {
    return num;
  }

}