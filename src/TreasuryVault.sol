// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IERC20} from 'lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from 'lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol';

/**
 * @title TreasuryVault
 * @dev Stores fees from Automorph and deposits them into a Yearn V2 vault for yield.
 */
contract TreasuryVault {
    using SafeERC20 for IERC20;

    IERC20 public immutable underlyingToken; // e.g., WETH
    IVault public immutable yearnVault;      // e.g., yvWETH
    address public owner;

    event DepositedToYearn(uint256 underlyingAmount, uint256 yTokenAmount);
    event WithdrawnFromYearn(uint256 yTokenAmount, uint256 underlyingAmount);

    constructor(address _underlyingToken, address _yearnVault) {
        require(_underlyingToken != address(0), 'Invalid token address');
        require(_yearnVault != address(0), 'Invalid vault address');

        underlyingToken = IERC20(_underlyingToken);
        yearnVault = IVault(_yearnVault);
        owner = msg.sender;

        // Approve Yearn vault to spend underlying token
        underlyingToken.safeApprove(_yearnVault, type(uint256).max);
    }

    modifier onlyOwner() {
        require(msg.sender == owner, 'Not owner');//admin of protocol
        _;
    }

    function depositToYearn(uint256 amount) external returns (uint256 yTokenAmount) {
        require(amount > 0, 'Amount must be > 0');
        uint256 balance = underlyingToken.balanceOf(address(this));
        require(balance >= amount, 'Insufficient balance');

        // Deposit into Yearn vault
        yTokenAmount = yearnVault.deposit(amount, address(this));
        emit DepositedToYearn(amount, yTokenAmount);
    }

    function withdrawFromYearn(uint256 yTokenAmount) external onlyOwner returns (uint256 underlyingAmount) {
        require(yTokenAmount > 0, 'Amount must be > 0');
        uint256 yBalance = yearnVault.balanceOf(address(this));
        require(yBalance >= yTokenAmount, 'Insufficient yVault balance');

        // Withdraw from Yearn vault
        underlyingAmount = yearnVault.withdraw(yTokenAmount, address(this), 1); // 1 bps max loss
        emit WithdrawnFromYearn(yTokenAmount, underlyingAmount);
    }

    function getUnderlyingBalance() external view returns (uint256) {
        return underlyingToken.balanceOf(address(this));
    }

    function getYearnBalance() external view returns (uint256) {
        return yearnVault.balanceOf(address(this));
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), 'Invalid new owner');
        owner = newOwner;
    }
}

/**
 * @dev Interface for Yearn V2 Vaults (based on Vyper implementation).
 * Source: https://github.com/yearn/yearn-vaults/blob/main/contracts/Vault.vy
 */
interface IVault {
    function deposit(uint256 amount, address recipient) external returns (uint256);
    function withdraw(uint256 maxShares, address recipient, uint256 maxLoss) external returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function token() external view returns (address); // Underlying token
    function pricePerShare() external view returns (uint256); // Yield appreciation
}