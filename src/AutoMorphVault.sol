// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "chainlink/contracts/src/v0.8/automation/interfaces/KeeperCompatibleInterface.sol";
import "chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import "./token/amWETH.sol";

interface IWETH is IERC20 {
    function deposit() external payable;
    function withdraw(uint256) external;
}

interface ILendingPool {
    function deposit(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
}

contract Vault is ReentrancyGuard, KeeperCompatibleInterface {
    // Contracts
    IWETH public immutable weth;
    //SWETH public immutable sWETH;
    amWETH public immutable amweth;
    ILendingPool public immutable aaveLendingPool;
    IERC20 public immutable aWETH;
    AggregatorV3Interface public immutable ethPriceFeed;

    // Constants
    uint256 public constant COLLATERAL_RATIO = 150; // 150%
    uint256 public constant PRICE_FEED_PRECISION = 1e8; // Chainlink price feed decimals

    // User debt tracking
    struct UserDebt {
        uint256 collateralAmount; // WETH deposited
        uint256 borrowedAmount;   // USD-denominated debt (scaled by 1e18)
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

    constructor(
        address _weth,
        address _amWETH,
        address _aaveLendingPool,
        address _aWETH,
        address _ethPriceFeed,
        uint256 _updateInterval  // Pass in the desired interval in seconds (e.g., ~15,552,000 for six months)
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

    /// @notice Deposit WETH as collateral and mint sWETH.
    function deposit(uint256 amount) external nonReentrant {
        require(amount > 0, "Invalid amount");

        // Transfer WETH from the user.
        weth.transferFrom(msg.sender, address(this), amount);

        // Mint sWETH (1:1 ratio).
        amweth.mint(msg.sender, amount);

        // Deposit WETH into Aave to earn yield.
        weth.approve(address(aaveLendingPool), amount);
        aaveLendingPool.deposit(address(weth), amount, address(this), 0);

        // If new user, add to our users array.
        if (!isUser[msg.sender]) {
            users.push(msg.sender);
            isUser[msg.sender] = true;
        }

        // Initialize/update user debt (isDeposit = true).
        _updateDebt(msg.sender, amount, true);

        emit Deposited(msg.sender, amount);
    }

    /// @notice Withdraw WETH by burning sWETH (after debt is repaid).
    function withdraw(uint256 amount) external nonReentrant {
        require(amount > 0, "Invalid amount");

        // Burn sWETH.
        amweth.burn(msg.sender, amount);

        // Update debt and check repayment status (isDeposit = false).
        _updateDebt(msg.sender, amount, false);

        // Withdraw WETH from Aave.
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
            require(debt.borrowedAmount == 0, "Debt not fully repaid");
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
    function checkUpkeep(
        bytes calldata /* checkData */
    ) external view override returns (bool upkeepNeeded, bytes memory performData) {
        upkeepNeeded = (block.timestamp - globalLastUpdate) >= updateInterval;
        performData = "";
    }

    /// @notice performUpkeep is called by Chainlink Keepers when checkUpkeep returns true.
    function performUpkeep(
        bytes calldata /* performData */
    ) external override {
        if ((block.timestamp - globalLastUpdate) >= updateInterval) {
            // Loop over each registered user and update their yield.
            for (uint256 i = 0; i < users.length; i++) {
                _updateYield(users[i]);
            }
            globalLastUpdate = block.timestamp;
        }
    }
}
