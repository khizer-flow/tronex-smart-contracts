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
// CONTRACT C: THE ZERO RISK FUND VAULT
// ==========================================
contract TronexZeroRiskVault {
    
    // --- 1. STATE VARIABLES ---
    IERC20 public immutable usdtToken;
    address public owner;
    
    // The exact address of Contract A. Only this address can order payouts.
    address public mainContract; 

    // Analytics tracking for the Admin Dashboard
    uint256 public totalZeroRiskPaidOut;

    // --- 2. EVENTS ---
    event ZeroRiskPaid(address indexed user, uint256 amount);
    event MainContractUpdated(address indexed oldContract, address indexed newContract);
    event TokensRescued(address indexed token, address indexed to, uint256 amount);
    event BNBRescued(address indexed to, uint256 amount);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    // --- 3. MODIFIERS ---
    modifier onlyOwner() {
        require(msg.sender == owner, "ZeroRiskVault: Caller is not the admin");
        _;
    }

    modifier onlyMainContract() {
        require(msg.sender == mainContract, "ZeroRiskVault: Caller is not the Main Contract");
        _;
    }

    // --- 4. CONSTRUCTOR ---
    constructor(address _usdtAddress) {
        require(_usdtAddress != address(0), "ZeroRiskVault: USDT address cannot be zero");
        
        owner = msg.sender;
        usdtToken = IERC20(_usdtAddress);
        
        emit OwnershipTransferred(address(0), msg.sender);
    }

    // --- 5. SYSTEM ARCHITECTURE SETUP ---
    /**
     * @dev Links this Vault to Contract A. 
     * Can be updated by the Admin if you ever upgrade Contract A to a V6 in the future.
     */
    function setMainContract(address _mainContract) external onlyOwner {
        require(_mainContract != address(0), "ZeroRiskVault: Main contract cannot be zero address");
        
        address oldContract = mainContract;
        mainContract = _mainContract;
        
        emit MainContractUpdated(oldContract, _mainContract);
    }

    // --- 6. CORE PAYOUT LOGIC ---
    /**
     * @dev Payout function strictly controlled by Contract A.
     * Contract A calculates the math, cooldowns, and limits. This vault just executes.
     */
    function payZeroRiskClaim(address _user, uint256 _amount) external onlyMainContract {
        // EDGE CASE FIX: Ensure valid user address and amount
        require(_user != address(0), "ZeroRiskVault: Cannot pay the zero address");
        require(_amount > 0, "ZeroRiskVault: Payout amount must be greater than zero");

        // CHECK: Ensure the vault hasn't been drained
        uint256 currentBalance = usdtToken.balanceOf(address(this));
        require(currentBalance >= _amount, "ZeroRiskVault: Insufficient USDT to cover claim");

        // EFFECT: Update metrics before transfer
        totalZeroRiskPaidOut += _amount;

        // INTERACTION: Push the USDT to the user
        bool success = usdtToken.transfer(_user, _amount);
        require(success, "ZeroRiskVault: USDT transfer failed");

        emit ZeroRiskPaid(_user, _amount);
    }

    // --- 7. FRONTEND HELPERS ---
    /**
     * @dev Returns the current live balance of the vault for UI displays.
     */
    function getAvailableZeroRiskFund() external view returns (uint256) {
        return usdtToken.balanceOf(address(this));
    }

    // --- 8. FAILSAFES & EDGE CASE HANDLING ---
    
    /**
     * @dev Failsafe 1: Rescue accidentally sent BEP20 tokens.
     */
    function rescueAnyBEP20Token(address _tokenAddress, uint256 _amount) external onlyOwner {
        require(_tokenAddress != address(0), "ZeroRiskVault: Invalid token address");
        require(_amount > 0, "ZeroRiskVault: Amount must be greater than 0");
        
        bool success = IERC20(_tokenAddress).transfer(owner, _amount);
        require(success, "ZeroRiskVault: Token rescue failed");
        
        emit TokensRescued(_tokenAddress, owner, _amount);
    }

    /**
     * @dev Failsafe 2: Rescue accidentally sent raw BNB.
     */
    function rescueBNB() external onlyOwner {
        uint256 bnbBalance = address(this).balance;
        require(bnbBalance > 0, "ZeroRiskVault: No BNB to rescue");
        
        (bool success, ) = payable(owner).call{value: bnbBalance}("");
        require(success, "ZeroRiskVault: BNB rescue failed");
        
        emit BNBRescued(owner, bnbBalance);
    }

    /**
     * @dev Allows transferring ownership of the vault.
     */
    function transferOwnership(address _newOwner) external onlyOwner {
        require(_newOwner != address(0), "ZeroRiskVault: New owner cannot be zero address");
        
        address oldOwner = owner;
        owner = _newOwner;
        
        emit OwnershipTransferred(oldOwner, _newOwner);
    }

    // Allows the contract to receive raw BNB for the rescue function
    receive() external payable {}
}
