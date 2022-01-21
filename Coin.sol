// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.0;
pragma abicoder v2;

import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/token/ERC20/ERC20.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/access/Ownable.sol";


contract Xtenfi is ERC20("Xtenfi", "Xtenfi"), Ownable {
    function mint(address _to, uint256 _amount) public onlyOwner {
        _mint(_to, _amount);
    }
}
