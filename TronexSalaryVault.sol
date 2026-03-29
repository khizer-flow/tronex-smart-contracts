/**
 *Submitted for verification at testnet.bscscan.com
*/

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

// --- ERC20 MINIMAL INTERFACE ---
interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

// ==========================================
// CONTRACT B: THE SALARY FUND VAULT
// ==========================================
contract TronexSalaryVault {
    
    // --- 1. STATE VARIABLES ---
    // 'immutable' saves gas and prevents the USDT address from EVER being maliciously altered after deployment.
    IERC20 public immutable usdtToken;
    address public owner;

    // Analytics tracking for your dashboard
    uint256 public totalWithdrawn;

    // --- 2. EVENTS ---
    event SalaryWithdrawn(address indexed admin, uint256 amount);
    event TokensRescued(address indexed token, address indexed to, uint256 amount);
    event BNBRescued(address indexed to, uint256 amount);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    // --- 3. MODIFIERS ---
    modifier onlyOwner() {
        require(msg.sender == owner, "SalaryVault: Caller is not the admin");
        _;
    }

    // --- 4. CONSTRUCTOR ---
    constructor(address _usdtAddress) {
        // EDGE CASE FIX: Prevents accidental deployment to the burn address
        require(_usdtAddress != address(0), "SalaryVault: USDT address cannot be zero");
        
        owner = msg.sender;
        usdtToken = IERC20(_usdtAddress);
        
        emit OwnershipTransferred(address(0), msg.sender);
    }

    // --- 5. CORE WITHDRAWAL LOGIC ---
    /**
     * @dev Allows the admin to withdraw accumulated salary/royalty USDT.
     * Applies the CEI (Checks-Effects-Interactions) pattern to prevent reentrancy.
     */
    function withdrawSalary(uint256 _amount) external onlyOwner {
        // CHECK: Ensure amount is valid
        require(_amount > 0, "SalaryVault: Cannot withdraw zero amount");
        
        // CHECK: Ensure vault actually holds the funds
        uint256 currentBalance = usdtToken.balanceOf(address(this));
        require(currentBalance >= _amount, "SalaryVault: Insufficient USDT balance");

        // EFFECT: Update state variables BEFORE the transfer
        totalWithdrawn += _amount;

        // INTERACTION: Transfer the USDT
        bool success = usdtToken.transfer(owner, _amount);
        require(success, "SalaryVault: USDT transfer failed");

        emit SalaryWithdrawn(owner, _amount);
    }

    // --- 6. FRONTEND HELPERS ---
    /**
     * @dev Returns the current live balance of the vault. 
     * Useful for the Admin UI to show exactly how much Salary is available.
     */
    function getAvailableSalary() external view returns (uint256) {
        return usdtToken.balanceOf(address(this));
    }

    // --- 7. FAILSAFES & EDGE CASE HANDLING ---
    
    /**
     * @dev Failsafe 1: If someone accidentally sends the WRONG BEP20 token to this vault, 
     * the admin can rescue it. (Standard Web3 best practice).
     */
    function rescueAnyBEP20Token(address _tokenAddress, uint256 _amount) external onlyOwner {
        require(_tokenAddress != address(0), "SalaryVault: Invalid token address");
        require(_amount > 0, "SalaryVault: Amount must be greater than 0");
        
        bool success = IERC20(_tokenAddress).transfer(owner, _amount);
        require(success, "SalaryVault: Token rescue failed");
        
        emit TokensRescued(_tokenAddress, owner, _amount);
    }

    /**
     * @dev Failsafe 2: If someone accidentally sends raw BNB to this contract,
     * the admin can sweep it out.
     */
    function rescueBNB() external onlyOwner {
        uint256 bnbBalance = address(this).balance;
        require(bnbBalance > 0, "SalaryVault: No BNB to rescue");
        
        (bool success, ) = payable(owner).call{value: bnbBalance}("");
        require(success, "SalaryVault: BNB rescue failed");
        
        emit BNBRescued(owner, bnbBalance);
    }

    /**
     * @dev Allows transferring ownership to a new hardware wallet or multisig in the future.
     */
    function transferOwnership(address _newOwner) external onlyOwner {
        require(_newOwner != address(0), "SalaryVault: New owner cannot be zero address");
        
        address oldOwner = owner;
        owner = _newOwner;
        
        emit OwnershipTransferred(oldOwner, _newOwner);
    }

    // Allows the contract to physically receive raw BNB for the rescue function
    receive() external payable {}
}
