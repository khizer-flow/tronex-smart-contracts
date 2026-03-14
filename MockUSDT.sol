// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/token/ERC20/ERC20.sol";

contract MockUSDT is ERC20 {
    constructor() ERC20("Testnet Tether", "USDT") {
        // This instantly prints 1 Million fake USDT and sends it to your wallet!
        _mint(msg.sender, 1000000 * 10 ** decimals()); 
    }
}