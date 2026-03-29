// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts@4.9.0/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts@4.9.0/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts@4.9.0/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts@4.9.0/security/Pausable.sol";

interface IZeroRiskVault {
    function payZeroRiskClaim(address _user, uint256 _amount) external;
}

contract TronexMain is ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;
    
    // --- 1. DATA STRUCTURES ---
    struct User {
        uint256 id;
        address wallet;
        uint256 referrerId;
        uint256 totalEarnings;
        uint256 earnedFromZeroRisk; 
        uint256 lastZeroRiskClaim;  
        mapping(uint256 => Matrix) matrices; 
        uint256 totalTeamSize;   
        uint256 activeTeamSize;  
        uint256 activeLevelsCount;
    }
    
    struct Matrix {
        uint256 currentReferrer; 
        uint256[] firstLevelReferrals; 
        uint256[] secondLevelReferrals; 
        uint256 recycleCount; 
    }
    
    // --- 2. CONFIGURATION ---
    IERC20 public usdtToken; 
    address public salaryVault;
    address public zeroRiskVault;
    
    mapping(address => uint256) public addressToId; 
    mapping(uint256 => User) public users;
    
    uint256 public constant ADMIN_ID = 1000;
    uint256 public lastUserId = ADMIN_ID;
    address public owner;
    
    uint256[] public packagePrice = [
        0, 
        6 ether,    // Level 1 ($6)
        10 ether,   // Level 2 ($10)
        20 ether,   // Level 3 ($20)
        40 ether,   // Level 4 ($40)
        80 ether,   // Level 5 ($80)
        160 ether,  // Level 6 ($160)
        320 ether,  // Level 7 ($320)
        640 ether,  // Level 8 ($640)
        1280 ether, // Level 9 ($1280)
        2560 ether  // Level 10 ($2560)
    ];
    
    uint256[10] public genDenominators = [12, 20, 20, 30, 30, 60, 60, 60, 60, 60];
    
    // DESIGN NOTE: Cumulative lifetime counters (never decrease)
    uint256 public totalRegisteredUsers; 
    uint256 public totalPayingUsers;     
    
    uint256 public constant ZERO_RISK_CAP = 10 ether; 
    uint256 public constant ZERO_RISK_DAILY_LIMIT = 3 ether; 
    uint256 private constant MAX_RECYCLE_DEPTH = 5;
    uint256 private currentRecycleDepth;
    
    // --- 3. EVENTS ---
    event Registration(address indexed user, uint256 indexed referrerId, uint256 userId);
    event PackagePurchased(uint256 indexed userId, uint256 indexed level, uint256 amount);
    event Payout(uint256 indexed userId, uint256 amount, string reason);
    event PayoutFailed(uint256 indexed userId, uint256 amount, string reason);
    event MatrixRecycle(uint256 indexed userId, uint256 indexed level, uint256 recycleCount);
    event ZeroRiskClaim(uint256 indexed userId, uint256 amount);
    event UM_Unlocked(uint256 indexed userId, uint256 amount);
    event Matrix_Income_Paid(uint256 indexed userId, uint256 amount);
    event Salary_Funded(uint256 amount);
    event ZeroRisk_Funded(uint256 amount);
    event Level_Income_Paid(uint256 indexed userId, uint256 level, uint256 amount);
    
    constructor(address _usdtAddress) {
        owner = msg.sender;
        usdtToken = IERC20(_usdtAddress);
        
        users[ADMIN_ID].id = ADMIN_ID;
        users[ADMIN_ID].wallet = owner;
        users[ADMIN_ID].referrerId = 0;
        users[ADMIN_ID].activeLevelsCount = 10; 
        addressToId[owner] = ADMIN_ID;
        
        totalRegisteredUsers = 1;
        totalPayingUsers = 1;
    }
    
    modifier onlyOwner() {
        require(msg.sender == owner, "TronexMain: Admin only");
        _;
    }
    
    // --- 4. ADMIN CONTROLS ---
    function setVaults(address _salaryVault, address _zeroRiskVault) external onlyOwner {
        require(_salaryVault != address(0) && _zeroRiskVault != address(0), "TronexMain: Invalid addresses");
        salaryVault = _salaryVault;
        zeroRiskVault = _zeroRiskVault;
    }
    
    function adminRescueStuckUSDT(uint256 _amount) external onlyOwner {
        usdtToken.safeTransfer(owner, _amount);
    }
    
    function pausePlatform() external onlyOwner {
        _pause();
    }
    
    function unpausePlatform() external onlyOwner {
        _unpause();
    }
    
    // --- 5. REGISTRATION ---
    function basicRegistration(uint256 _referrerId) external whenNotPaused {
        require(addressToId[msg.sender] == 0, "TronexMain: Already registered");
        
        if (_referrerId < ADMIN_ID || users[_referrerId].id == 0) {
            _referrerId = ADMIN_ID;
        }
        
        lastUserId++;
        uint256 newUserId = lastUserId;
        
        users[newUserId].id = newUserId;
        users[newUserId].wallet = msg.sender;
        users[newUserId].referrerId = _referrerId;
        users[newUserId].activeLevelsCount = 0; 
        
        addressToId[msg.sender] = newUserId;
        users[_referrerId].totalTeamSize++;
        totalRegisteredUsers++;
        
        emit Registration(msg.sender, _referrerId, newUserId);
    }
    
    function registerLevel1(uint256 _referrerId) external whenNotPaused nonReentrant {
        require(salaryVault != address(0) && zeroRiskVault != address(0), "TronexMain: Vaults not linked");
        require(addressToId[msg.sender] == 0, "TronexMain: Already registered");
        require(users[_referrerId].id != 0, "TronexMain: Invalid Referrer");
        
        uint256 amount = packagePrice[1];
        usdtToken.safeTransferFrom(msg.sender, address(this), amount);
        
        lastUserId++;
        uint256 newUserId = lastUserId;
        
        users[newUserId].id = newUserId;
        users[newUserId].wallet = msg.sender;
        users[newUserId].referrerId = _referrerId;
        users[newUserId].activeLevelsCount = 1;
        addressToId[msg.sender] = newUserId;
        
        users[_referrerId].totalTeamSize++;
        users[_referrerId].activeTeamSize++;
        
        totalRegisteredUsers++;
        totalPayingUsers++;
        
        emit Registration(msg.sender, _referrerId, newUserId);
        buyPackageLogic(newUserId, 1, amount);
    }
    
    // --- 6. BUY FUNCTIONS ---
    function buyLevel1() external whenNotPaused nonReentrant { _processLevelBuy(1); }
    function buyLevel2() external whenNotPaused nonReentrant { _processLevelBuy(2); }
    function buyLevel3() external whenNotPaused nonReentrant { _processLevelBuy(3); }
    function buyLevel4() external whenNotPaused nonReentrant { _processLevelBuy(4); }
    function buyLevel5() external whenNotPaused nonReentrant { _processLevelBuy(5); }
    function buyLevel6() external whenNotPaused nonReentrant { _processLevelBuy(6); }
    function buyLevel7() external whenNotPaused nonReentrant { _processLevelBuy(7); }
    function buyLevel8() external whenNotPaused nonReentrant { _processLevelBuy(8); }
    function buyLevel9() external whenNotPaused nonReentrant { _processLevelBuy(9); }
    function buyLevel10() external whenNotPaused nonReentrant { _processLevelBuy(10); }
    
   function _processLevelBuy(uint256 _level) internal {
        require(salaryVault != address(0) && zeroRiskVault != address(0), "TronexMain: Vaults not linked");
        uint256 userId = addressToId[msg.sender];
        require(userId != 0, "TronexMain: Not registered");
        require(users[userId].activeLevelsCount == _level - 1, "TronexMain: Buy previous level first");
        
        uint256 amount = packagePrice[_level];
        usdtToken.safeTransferFrom(msg.sender, address(this), amount);
        
        users[userId].activeLevelsCount = _level;

        // Fix: Properly track when a free user upgrades to Level 1
        if (_level == 1) {
            totalPayingUsers++;
            users[users[userId].referrerId].activeTeamSize++;
        }

        buyPackageLogic(userId, _level, amount);
    }
    
    // --- 7. CORE ROUTING ---
    function buyPackageLogic(uint256 _userId, uint256 _level, uint256 _amount) internal {
        uint256 referrerId = users[_userId].referrerId;
        uint256 activeSponsorId = findActiveReferrer(referrerId, _level);
        
        sendMoney(activeSponsorId, _amount / 3, "Direct Sponsor");
        emit UM_Unlocked(activeSponsorId, _amount / 3);
        
        currentRecycleDepth = 0; 
        handleMatrix(_userId, referrerId, _level, _amount / 6);
        
        uint256 expectedTotalGen = _distributeGenerations(referrerId, _level, _amount);
        
        sendToSalaryVault(_amount / 12);
        emit Salary_Funded(_amount / 12);
        
        // ✅ FIXED: Using raw transfer() with try-catch (external call)
        try usdtToken.transfer(zeroRiskVault, _amount / 12) returns (bool zrSuccess) {
            if (zrSuccess) {
                emit ZeroRisk_Funded(_amount / 12);
            } else {
                sendToSalaryVault(_amount / 12);
                emit PayoutFailed(0, _amount / 12, "Zero Risk transfer soft-failed - sent to Salary");
            }
        } catch {
            sendToSalaryVault(_amount / 12);
            emit PayoutFailed(0, _amount / 12, "Zero Risk transfer hard-reverted - sent to Salary");
        }
        
        uint256 totalAllocated = (_amount / 3) + (_amount / 6) + (_amount / 12) + (_amount / 12) + expectedTotalGen;
        if (_amount > totalAllocated) {
            sendToSalaryVault(_amount - totalAllocated);
            emit Salary_Funded(_amount - totalAllocated);
        }
        
        emit PackagePurchased(_userId, _level, _amount);
    }
    
    function _distributeGenerations(uint256 _referrerId, uint256 _level, uint256 _amount) internal returns (uint256) {
        uint256 totalGenDistributed = 0;
        uint256 expectedTotalGen = 0;
        uint256 uplineId = _referrerId;
        
        for(uint256 i = 0; i < 10; i++) {
            uint256 genAmt = _amount / genDenominators[i];
            expectedTotalGen += genAmt;
            
            if(uplineId != 0) {
                if (users[uplineId].activeLevelsCount >= _level) {
                    sendMoney(uplineId, genAmt, "Generation Reward");
                    emit Level_Income_Paid(uplineId, i + 1, genAmt);
                    totalGenDistributed += genAmt;
                }
                uplineId = users[uplineId].referrerId;
            }
        }
        
        uint256 leftover = expectedTotalGen - totalGenDistributed;
        if(leftover > 0) {
            sendToSalaryVault(leftover);
            emit Salary_Funded(leftover);
        }
        
        return expectedTotalGen;
    }
    
    function handleMatrix(uint256 _userId, uint256 _referrerId, uint256 _level, uint256 _matrixAmt) internal {
        uint256 activeSponsor = findActiveReferrer(_referrerId, _level);
        updateMatrix(_userId, activeSponsor, _level, _matrixAmt);
    }
    
    function findActiveReferrer(uint256 _userId, uint256 _level) internal view returns (uint256) {
        uint256 current = _userId;
        uint256 depth = 0;
        
        while (current != 0 && current != ADMIN_ID && depth < 100) {
            if (users[current].activeLevelsCount >= _level) {
                return current;
            }
            current = users[current].referrerId;
            depth++;
        }
        return ADMIN_ID;
    }
    
    function updateMatrix(uint256 _userId, uint256 _sponsorId, uint256 _level, uint256 _matrixAmt) internal {
        Matrix storage sponsorMatrix = users[_sponsorId].matrices[_level];
        
        if (sponsorMatrix.firstLevelReferrals.length < 2) {
            sponsorMatrix.firstLevelReferrals.push(_userId);
            users[_userId].matrices[_level].currentReferrer = _sponsorId;
            
            uint256 refOfSponsor = sponsorMatrix.currentReferrer;
            if (refOfSponsor != 0) {
                Matrix storage higherMatrix = users[refOfSponsor].matrices[_level];
                higherMatrix.secondLevelReferrals.push(_userId);
                
                if (higherMatrix.secondLevelReferrals.length == 4) {
                    handleRecycle(refOfSponsor, _level, _matrixAmt);
                } else {
                    sendMoney(refOfSponsor, _matrixAmt, "Matrix Income");
                    emit Matrix_Income_Paid(refOfSponsor, _matrixAmt);
                }
            } else {
                sendMoney(_sponsorId, _matrixAmt, "Matrix Income");
                emit Matrix_Income_Paid(_sponsorId, _matrixAmt);
            }
        } else {
            uint256 leftNode = sponsorMatrix.firstLevelReferrals[0];
            uint256 rightNode = sponsorMatrix.firstLevelReferrals[1];
            uint256 targetNode;
            
            if (users[leftNode].matrices[_level].firstLevelReferrals.length < 2) {
                targetNode = leftNode;
            } else if (users[rightNode].matrices[_level].firstLevelReferrals.length < 2) {
                targetNode = rightNode;
            } else {
                sendToSalaryVault(_matrixAmt);
                emit Salary_Funded(_matrixAmt);
                return;
            }
            
            users[targetNode].matrices[_level].firstLevelReferrals.push(_userId);
            users[_userId].matrices[_level].currentReferrer = targetNode;
            sponsorMatrix.secondLevelReferrals.push(_userId);
            
            if (sponsorMatrix.secondLevelReferrals.length == 4) {
                handleRecycle(_sponsorId, _level, _matrixAmt);
            } else {
                sendMoney(_sponsorId, _matrixAmt, "Matrix Income");
                emit Matrix_Income_Paid(_sponsorId, _matrixAmt);
            }
        }
    }
    
    function handleRecycle(uint256 _userId, uint256 _level, uint256 _matrixAmt) internal {
        Matrix storage m = users[_userId].matrices[_level];
        
        m.recycleCount++;
        emit MatrixRecycle(_userId, _level, m.recycleCount);
        
        for(uint256 i=0; i < m.firstLevelReferrals.length; i++) {
            users[m.firstLevelReferrals[i]].matrices[_level].currentReferrer = 0;
        }
        for(uint256 i=0; i < m.secondLevelReferrals.length; i++) {
            users[m.secondLevelReferrals[i]].matrices[_level].currentReferrer = 0;
        }
        
        delete m.firstLevelReferrals;
        delete m.secondLevelReferrals;
        
        if (_userId == ADMIN_ID || currentRecycleDepth >= MAX_RECYCLE_DEPTH) {
            sendToSalaryVault(_matrixAmt);
            emit Salary_Funded(_matrixAmt);
            return;
        }
        
        currentRecycleDepth++;
        uint256 activeSponsor = findActiveReferrer(users[_userId].referrerId, _level);
        updateMatrix(_userId, activeSponsor, _level, _matrixAmt);
    }
    
    // --- 8. ZERO RISK CLAIM ---
    function claimZeroRisk() external whenNotPaused nonReentrant {
        uint256 userId = addressToId[msg.sender];
        require(userId != 0, "TronexMain: Not registered");
        require(users[userId].activeLevelsCount >= 1, "TronexMain: Must buy Level 1");
        require(block.timestamp >= users[userId].lastZeroRiskClaim + 1 days, "TronexMain: Wait 24h");
        require(users[userId].earnedFromZeroRisk < ZERO_RISK_CAP, "TronexMain: Max limit reached");
        
        uint256 currentPool = usdtToken.balanceOf(zeroRiskVault);
        require(currentPool > 0, "TronexMain: Pool empty");
        
        uint256 claimAmount = currentPool / totalPayingUsers;
        require(claimAmount > 0, "TronexMain: Claim too small");
        
        if(claimAmount > ZERO_RISK_DAILY_LIMIT) claimAmount = ZERO_RISK_DAILY_LIMIT; 
        if(users[userId].earnedFromZeroRisk + claimAmount > ZERO_RISK_CAP) {
            claimAmount = ZERO_RISK_CAP - users[userId].earnedFromZeroRisk;
        }
        
        users[userId].lastZeroRiskClaim = block.timestamp;
        users[userId].earnedFromZeroRisk += claimAmount;
        
        IZeroRiskVault(zeroRiskVault).payZeroRiskClaim(msg.sender, claimAmount);
        
        emit ZeroRiskClaim(userId, claimAmount);
    }
    
    // --- 9. HELPERS ---
    // ✅ FIXED: Using raw transfer() with try-catch
    function sendMoney(uint256 _userId, uint256 _amount, string memory _reason) internal {
        if(_userId == 0) _userId = ADMIN_ID; 
        address receiver = users[_userId].wallet;
        
        if(receiver == address(0) || receiver == address(this)) {
            sendToSalaryVault(_amount);
            emit PayoutFailed(_userId, _amount, string(abi.encodePacked(_reason, " (Invalid Address)")));
            return;
        }
        
        users[_userId].totalEarnings += _amount;
        
        try usdtToken.transfer(receiver, _amount) returns (bool success) {
            if (success) {
                emit Payout(_userId, _amount, _reason);
            } else {
                sendToSalaryVault(_amount);
                emit PayoutFailed(_userId, _amount, string(abi.encodePacked(_reason, " (Soft Fail)")));
            }
        } catch {
            sendToSalaryVault(_amount);
            emit PayoutFailed(_userId, _amount, string(abi.encodePacked(_reason, " (Hard Revert)")));
        }
    }
    
    // ✅ FIXED: Using raw transfer() with try-catch
    function sendToSalaryVault(uint256 _amount) internal {
        try usdtToken.transfer(salaryVault, _amount) returns (bool success) {
            if (!success) {
                emit PayoutFailed(0, _amount, "Salary Vault Transfer Soft-Failed - Use Rescue");
            }
        } catch {
            emit PayoutFailed(0, _amount, "Salary Vault Transfer Reverted - Use Rescue");
        }
    }
    
    // --- 10. VIEW FUNCTIONS ---
    function getUserInfo(uint256 _userId) external view returns (
        address wallet, uint256 referrerId, uint256 totalEarnings,
        uint256 totalTeamSize, uint256 activeTeamSize, uint256 activeLevelsCount, uint256 earnedFromZeroRisk
    ) {
        User storage user = users[_userId];
        return (user.wallet, user.referrerId, user.totalEarnings, user.totalTeamSize, user.activeTeamSize, user.activeLevelsCount, user.earnedFromZeroRisk);
    }
    
    function getMatrixInfo(uint256 _userId, uint256 _level) external view returns (
        uint256 currentReferrer, uint256[] memory firstLevel, uint256[] memory secondLevel, uint256 recycleCount
    ) {
        Matrix storage matrix = users[_userId].matrices[_level];
        return (matrix.currentReferrer, matrix.firstLevelReferrals, matrix.secondLevelReferrals, matrix.recycleCount);
    }
}
