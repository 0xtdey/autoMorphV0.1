// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {ReentrancyGuard} from 'lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol';
import {IERC20} from 'lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol';
import {KeeperCompatibleInterface} from
    'lib/chainlink/contracts/src/v0.8/automation/interfaces/KeeperCompatibleInterface.sol';
import {AggregatorV3Interface} from 'lib/chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol';
import {amWETH} from './token/amWETH.sol';
import {ILendingPool} from './interface/ILendingPool.sol';
import {TreasuryVault} from 'src/TreasuryVault.sol';

interface IWETH is IERC20 {
    function deposit() external payable;
    function withdraw(uint256) external;
}

// interface ILendingPool {
//     function deposit(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
//     function withdraw(address asset, uint256 amount, address to) external returns (uint256);
// }
//@note make a contract and integrate with AAVE lending pool - done
//@note write tests
//@note update functions with inclusion of protocol fees of 0.03% in deposits with the principle token i.e. weth

contract Vault is ReentrancyGuard, KeeperCompatibleInterface {
    // Contracts
    IWETH public weth;
    amWETH public amweth;
    ILendingPool public aaveLendingPool;
    IERC20 public aWETH;
    AggregatorV3Interface public ethPriceFeed;
    TreasuryVault public treasuryVault;

    // Constants
    uint256 public constant COLLATERAL_RATIO = 150; // 150%
    uint256 public constant PRICE_FEED_PRECISION = 1e8; // Chainlink price feed decimals
    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant PROTOCOL_FEE_BPS = 3; //0.03% = 0.03/100 * 10_000 = 3

    uint256 public totalFeesCollected;

    // User debt tracking
    struct UserDebt {
        uint256 collateralAmount; // weth deposited
        uint256 borrowedAmount; // USD-denominated debt (scaled by 1e18)
        uint256 lastUpdated;
    }

    mapping(address => UserDebt) public userDebts;

    // Array to track users for automated updates
    address[] public users;
    mapping(address => bool) public isUser;

    // Chainlink Keepers (Automation) variables
    uint256 public globalLastUpdate;
    uint256 public updateInterval; // Interval (in seconds) for periodic updates (e.g., six months)

    // Events
    event Deposited(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event DebtUpdated(address indexed user, uint256 debtRepaid);

    //Errors
    error InvalidAmount();
    error DebtNotFullyRepaid();

    constructor(
        address _weth,
        address _amWETH,
        address _aaveLendingPool,
        address _aWETH,
        address _ethPriceFeed,
        uint256 _updateInterval // Pass in the desired interval in seconds (e.g., ~15,552,000 for six months)
    ) {
        weth = IWETH(_weth);
        amweth = amWETH(_amWETH);
        aaveLendingPool = ILendingPool(_aaveLendingPool);
        aWETH = IERC20(_aWETH);
        ethPriceFeed = AggregatorV3Interface(_ethPriceFeed);
        updateInterval = _updateInterval;
        globalLastUpdate = block.timestamp;
    }

    // --------------------------------------------
    // Core Functions
    // --------------------------------------------

    /// @notice Deposit weth as collateral and mint sWETH.
    function deposit(uint256 amount) external payable nonReentrant {
        require(amount > 0, InvalidAmount());
        require(amount == msg.value, InvalidAmount());

        // If new user, add to our users array.
        if (!isUser[msg.sender]) {
            users.push(msg.sender);
            isUser[msg.sender] = true;
        }

        //calculate fees
        uint256 protocolFees = (amount * 3) / BPS_DENOMINATOR;
        //subtract fees from deposit amount
        uint256 depositAmount = amount - protocolFees;
        //@note make a view function to display the fees and remove the calculation from this function and update the total fees collected
        //transfer total amount to this contract
        weth.transferFrom(msg.sender, address(this), amount);
        //transfer the fees to treasury vault
        weth.transfer(address(treasuryVault), protocolFees);
        //deposit to yearn
        treasuryVault.depositToYearn(protocolFees);
        //update total fees
        totalFeesCollected += protocolFees;

        // Mint sWETH (1:1 ratio).
        amweth.mint(msg.sender, depositAmount);

        // Deposit weth into Aave to earn yield.
        weth.approve(address(aaveLendingPool), depositAmount);
        aaveLendingPool.supply(address(weth), depositAmount, address(this), 0);

        // Initialize/update user debt (isDeposit = true).
        _updateDebt(msg.sender, depositAmount, true);

        emit Deposited(msg.sender, depositAmount);
    }

    /// @notice Withdraw weth by burning sWETH (after debt is repaid).
    function withdraw(uint256 amount) external nonReentrant {
        require(amount > 0, InvalidAmount());

        // Burn sWETH.
        amweth.burn(msg.sender, amount);

        // Update debt and check repayment status (isDeposit = false).
        _updateDebt(msg.sender, amount, false);

        // Withdraw weth from Aave.
        aaveLendingPool.withdraw(address(weth), amount, msg.sender);

        emit Withdrawn(msg.sender, amount);
    }

    // --------------------------------------------
    // Debt Management
    // --------------------------------------------

    /// @dev Update user debt based on accrued yield during deposit/withdraw operations.
    function _updateDebt(address user, uint256 collateralChange, bool isDeposit) internal {
        UserDebt storage debt = userDebts[user];
        uint256 elapsedTime = block.timestamp - debt.lastUpdated;
        uint256 ethPrice = _getEthPrice();

        if (elapsedTime > 0 && debt.borrowedAmount > 0) {
            // Calculate yield generated in aWETH.
            uint256 aWETHBalance = aWETH.balanceOf(address(this));
            uint256 yieldAmount = aWETHBalance > debt.collateralAmount ? aWETHBalance - debt.collateralAmount : 0;
            // Convert yield to USD using Chainlink price feed.
            uint256 yieldUSD = (yieldAmount * ethPrice) / 1e18;

            // Ensure we do not subtract more than the existing debt.
            if (yieldUSD > debt.borrowedAmount) {
                yieldUSD = debt.borrowedAmount;
            }
            debt.borrowedAmount -= yieldUSD;
            emit DebtUpdated(user, yieldUSD);
        }

        // Update collateral and recalculate debt for deposit/withdraw.
        if (isDeposit) {
            debt.collateralAmount += collateralChange;
            // Recalculate maximum borrow (collateral value divided by 1.5).
            uint256 maxBorrow = (debt.collateralAmount * ethPrice) / (COLLATERAL_RATIO * 1e2);
            debt.borrowedAmount = maxBorrow;
        } else {
            debt.collateralAmount -= collateralChange;
            require(debt.borrowedAmount == 0, DebtNotFullyRepaid());
        }
        debt.lastUpdated = block.timestamp;
    }

    /// @dev Update a user's debt by subtracting accrued yield without changing collateral.
    function _updateYield(address user) internal {
        UserDebt storage debt = userDebts[user];
        uint256 elapsedTime = block.timestamp - debt.lastUpdated;
        uint256 ethPrice = _getEthPrice();

        if (elapsedTime > 0 && debt.borrowedAmount > 0) {
            uint256 aWETHBalance = aWETH.balanceOf(address(this));
            uint256 yieldAmount = aWETHBalance > debt.collateralAmount ? aWETHBalance - debt.collateralAmount : 0;
            uint256 yieldUSD = (yieldAmount * ethPrice) / 1e18;
            if (yieldUSD > debt.borrowedAmount) {
                yieldUSD = debt.borrowedAmount;
            }
            debt.borrowedAmount -= yieldUSD;
            emit DebtUpdated(user, yieldUSD);
        }
        debt.lastUpdated = block.timestamp;
    }

    /// @dev Fetch ETH/USD price from Chainlink.
    function _getEthPrice() internal view returns (uint256) {
        (, int256 price,,,) = ethPriceFeed.latestRoundData();
        return uint256(price) * (1e18 / PRICE_FEED_PRECISION); // Scale price to 1e18
    }

    // --------------------------------------------
    // Chainlink Keepers Functions for Periodic Updates
    // --------------------------------------------

    /// @notice checkUpkeep is called off-chain by Chainlink Keepers to determine if performUpkeep should run.
    function checkUpkeep(bytes calldata /* checkData */ )
        external
        view
        override
        returns (bool upkeepNeeded, bytes memory performData)
    {
        upkeepNeeded = (block.timestamp - globalLastUpdate) >= updateInterval;
        performData = '';
    }

    /// @notice performUpkeep is called by Chainlink Keepers when checkUpkeep returns true.
    function performUpkeep(bytes calldata /* performData */ ) external override {
        if ((block.timestamp - globalLastUpdate) >= updateInterval) {
            // Loop over each registered user and update their yield.
            for (uint256 i = 0; i < users.length; i++) {
                _updateYield(users[i]);
            }
            globalLastUpdate = block.timestamp;
        }
    }
}
