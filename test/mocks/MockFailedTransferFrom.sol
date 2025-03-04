// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20Burnable, ERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";

// 在 OpenZeppelin 合约包的未来版本中，必须使用合约所有者的地址声明 Ownable
// 作为参数。
// 例如：
// constructor（） ERC20（"去中心化稳定币"， "DSC"） ownable（0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266） {}
contract MockFailedTransferFrom is ERC20Burnable, Ownable {
    error DecentralizedStableCoin__AmountMustBeGreaterThanZero();
    error DecentralizedStableCoin__BurnAmountExceedsBalance();
    error DecentralizedStableCoin__CannotMintToZeroAddress();

    event Burned(address indexed from, uint256 amount);
    event Minted(address indexed to, uint256 amount);

    constructor() ERC20("DecentralizedStableCoin", "DSC") Ownable(msg.sender) {}

    function burn(uint256 _amount) public override onlyOwner {
        uint256 balance = balanceOf(msg.sender);

        if (_amount < 0) {
            revert DecentralizedStableCoin__AmountMustBeGreaterThanZero();
        }

        if (balance < _amount) {
            revert DecentralizedStableCoin__BurnAmountExceedsBalance();
        }

        super.burn(_amount);
        emit Burned(msg.sender, _amount);
    }

    function mint(address _to, uint256 _amount) public onlyOwner returns (bool) {
        if (_amount <= 0) {
            revert DecentralizedStableCoin__AmountMustBeGreaterThanZero();
        }

        if (_to == address(0)) {
            revert DecentralizedStableCoin__CannotMintToZeroAddress();
        }

        _mint(_to, _amount);

        emit Minted(_to, _amount);
        return true;
    }

    function transferFrom(address _from, address _to, uint256 _amount) public override returns (bool) {
        return false;
    }
}
