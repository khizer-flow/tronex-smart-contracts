/**
 *Submitted for verification at testnet.bscscan.com on 2026-03-14
*/

// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

// --- ERC20 INTERFACE ---
interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract TronexUniverse {
    
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

    uint256 constant DIRECT_SPONSOR_PCT = 3333; 
    uint256 constant MATRIX_SPILLOVER_PCT = 1667; 
    uint256 constant GEN_REWARD_PCT = 3333; 
    uint256 constant SALARY_FUND_PCT = 833; 
    uint256 constant ZERO_RISK_PCT = 834;   

    uint256 public zeroRiskFundBalance;
    uint256 public royaltyFundBalance;
    
    uint256 public totalRegisteredUsers; 
    uint256 public totalPayingUsers;     
    
    uint256 public constant ZERO_RISK_CAP = 10 ether; 
    uint256 public constant ZERO_RISK_DAILY_LIMIT = 3 ether; 

    // SECURITY FIX: Circuit Breaker for Cascading Recycles
    uint256 private constant MAX_RECYCLE_DEPTH = 5;
    uint256 private currentRecycleDepth;

    // --- 3. EVENTS ---
    event Registration(address indexed user, uint256 indexed referrerId, uint256 userId);
    event PackagePurchased(uint256 indexed userId, uint256 indexed level, uint256 amount);
    event Payout(uint256 indexed userId, uint256 amount, string reason);
    event PayoutFailed(uint256 indexed userId, uint256 amount, string reason);
    event MatrixRecycle(uint256 indexed userId, uint256 indexed level, uint256 recycleCount);
    event FundCredit(string fundName, uint256 amount);
    event ZeroRiskClaim(uint256 indexed userId, uint256 amount);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

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

    // --- 4. MAIN FUNCTIONS ---

    function basicRegistration(uint256 _referrerId) external {
        require(addressToId[msg.sender] == 0, "Already registered");
        
        if (_referrerId < ADMIN_ID || users[_referrerId].id == 0) {
            _referrerId = ADMIN_ID;
        }

        lastUserId++;
        uint256 newUserId = lastUserId;

        User storage user = users[newUserId];
        user.id = newUserId;
        user.wallet = msg.sender;
        user.referrerId = _referrerId;
        user.activeLevelsCount = 0; 
        
        addressToId[msg.sender] = newUserId;
        
        users[_referrerId].totalTeamSize++;
        totalRegisteredUsers++;

        emit Registration(msg.sender, _referrerId, newUserId);
    }

    function registration(uint256 _referrerId) external {
        require(addressToId[msg.sender] == 0, "Already registered");
        require(users[_referrerId].id != 0, "Invalid Referrer");
        
        uint256 amount = packagePrice[1];
        require(usdtToken.transferFrom(msg.sender, address(this), amount), "USDT transfer failed");

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

    function buyNewLevel(uint256 _level) external {
        uint256 userId = addressToId[msg.sender];
        require(userId != 0, "Not registered");
        require(_level >= 1 && _level <= 10, "Invalid Level");
        require(users[userId].activeLevelsCount == _level - 1, "Buy previous level first");

        uint256 amount = packagePrice[_level];
        require(usdtToken.transferFrom(msg.sender, address(this), amount), "USDT transfer failed");

        users[userId].activeLevelsCount = _level;

        if (_level == 1) {
            uint256 referrerId = users[userId].referrerId;
            users[referrerId].activeTeamSize++;
            totalPayingUsers++;
        }

        buyPackageLogic(userId, _level, amount);
    }

    // --- 5. CORE LOGIC ---
    function buyPackageLogic(uint256 _userId, uint256 _level, uint256 _amount) internal {
        User storage user = users[_userId];
        uint256 referrerId = user.referrerId;

        // V4.3 STRICT RULE: Find the first upline who actually owns this level
        uint256 activeSponsorId = findActiveReferrer(referrerId, _level);

        // 1. Direct Sponsor (Rolls up to the active sponsor if original is inactive)
        uint256 sponsorAmt = (_amount * DIRECT_SPONSOR_PCT) / 10000;
        sendMoney(activeSponsorId, sponsorAmt, "Direct Sponsor");

        // Reset Circuit Breaker before entering matrix logic
        currentRecycleDepth = 0; 
        
        // 2. 2x2 Matrix Placement
        handleMatrix(_userId, referrerId, _level, _amount);

        // 3. 10 Generation Reward (V4.3 STRICT RULE APPLIED)
        uint256 genAmtTotal = (_amount * GEN_REWARD_PCT) / 10000;
        uint256 perGenAmt = genAmtTotal / 10;
        uint256 totalDistributed = 0;
        
        uint256 uplineId = referrerId;
        for(uint256 i=1; i<=10; i++) {
            if(uplineId == 0) break;
            
            // Only pay the generation reward if the upline actually owns this level
            if (users[uplineId].activeLevelsCount >= _level) {
                sendMoney(uplineId, perGenAmt, "Generation Reward");
                totalDistributed += perGenAmt;
            }
            // Move up to the next referrer, regardless of whether this one got paid
            uplineId = users[uplineId].referrerId;
        }

        // Any generation rewards that were skipped drop directly into the Royalty Fund!
        uint256 leftover = genAmtTotal - totalDistributed;
        if(leftover > 0) {
            royaltyFundBalance += leftover;
            emit FundCredit("Unclaimed Generation Rewards", leftover);
        }

        // 4. Royalty Fund
        uint256 salaryAmt = (_amount * SALARY_FUND_PCT) / 10000;
        royaltyFundBalance += salaryAmt;
        emit FundCredit("Royalty Fund", salaryAmt);

        // 5. Zero Risk Fund
        uint256 riskAmt = (_amount * ZERO_RISK_PCT) / 10000;
        zeroRiskFundBalance += riskAmt;
        emit FundCredit("Zero Risk Fund", riskAmt);
        
        emit PackagePurchased(_userId, _level, _amount);
    }

    function handleMatrix(uint256 _userId, uint256 _referrerId, uint256 _level, uint256 _amount) internal {
        uint256 activeSponsor = findActiveReferrer(_referrerId, _level);
        updateMatrix(_userId, activeSponsor, _level, _amount);
    }

    function findActiveReferrer(uint256 _userId, uint256 _level) internal view returns (uint256) {
        uint256 current = _userId;
        while (current != 0 && current != ADMIN_ID) {
            if (users[current].activeLevelsCount >= _level) {
                return current;
            }
            current = users[current].referrerId;
        }
        return ADMIN_ID;
    }

    function updateMatrix(uint256 _userId, uint256 _sponsorId, uint256 _level, uint256 _amount) internal {
        Matrix storage sponsorMatrix = users[_sponsorId].matrices[_level];
        uint256 matrixAmt = (_amount * MATRIX_SPILLOVER_PCT) / 10000;

        if (sponsorMatrix.firstLevelReferrals.length < 2) {
            sponsorMatrix.firstLevelReferrals.push(_userId);
            users[_userId].matrices[_level].currentReferrer = _sponsorId;

            uint256 refOfSponsor = sponsorMatrix.currentReferrer;
            if (refOfSponsor != 0) {
                Matrix storage higherMatrix = users[refOfSponsor].matrices[_level];
                higherMatrix.secondLevelReferrals.push(_userId);
                
                if (higherMatrix.secondLevelReferrals.length == 4) {
                    handleRecycle(refOfSponsor, _level, matrixAmt);
                } else {
                    sendMoney(refOfSponsor, matrixAmt, "Matrix Income");
                }
            } else {
                sendMoney(_sponsorId, matrixAmt, "Matrix Income");
            }
        } else {
            uint256 leftNode = sponsorMatrix.firstLevelReferrals[0];
            uint256 rightNode = sponsorMatrix.firstLevelReferrals[1];

            uint256 targetNode;
            
            // Explicit Bounds Checking
            if (users[leftNode].matrices[_level].firstLevelReferrals.length < 2) {
                targetNode = leftNode;
            } else if (users[rightNode].matrices[_level].firstLevelReferrals.length < 2) {
                targetNode = rightNode;
            } else {
                // Safety catch: If both are somehow full, dump to royalty and abort cascade to prevent crash
                royaltyFundBalance += matrixAmt;
                emit FundCredit("Matrix Overflow Safecatch", matrixAmt);
                return;
            }

            users[targetNode].matrices[_level].firstLevelReferrals.push(_userId);
            users[_userId].matrices[_level].currentReferrer = targetNode;

            sponsorMatrix.secondLevelReferrals.push(_userId);

            if (sponsorMatrix.secondLevelReferrals.length == 4) {
                handleRecycle(_sponsorId, _level, matrixAmt);
            } else {
                sendMoney(_sponsorId, matrixAmt, "Matrix Income");
            }
        }
    }

    function handleRecycle(uint256 _userId, uint256 _level, uint256 _matrixAmt) internal {
        Matrix storage m = users[_userId].matrices[_level];
        
        m.recycleCount++;
        emit MatrixRecycle(_userId, _level, m.recycleCount);

        // Clean up stale pointers so the frontend UI doesn't draw ghost matrices
        for(uint256 i=0; i < m.firstLevelReferrals.length; i++) {
            users[m.firstLevelReferrals[i]].matrices[_level].currentReferrer = 0;
        }
        for(uint256 i=0; i < m.secondLevelReferrals.length; i++) {
            users[m.secondLevelReferrals[i]].matrices[_level].currentReferrer = 0;
        }

        delete m.firstLevelReferrals;
        delete m.secondLevelReferrals;
        
        if (_userId == ADMIN_ID) {
            royaltyFundBalance += _matrixAmt;
            emit FundCredit("Admin Recycle Income", _matrixAmt);
            return;
        }

        // Gas Limit Circuit Breaker
        currentRecycleDepth++;
        if (currentRecycleDepth >= MAX_RECYCLE_DEPTH) {
            royaltyFundBalance += _matrixAmt;
            emit FundCredit("Max Recycle Depth Safecatch", _matrixAmt);
            return;
        }

        uint256 activeSponsor = findActiveReferrer(users[_userId].referrerId, _level);
        updateMatrix(_userId, activeSponsor, _level, _matrixAmt);
    }

    // --- 6. ZERO RISK CLAIM SYSTEM ---
    function claimZeroRisk() external {
        uint256 userId = addressToId[msg.sender];
        require(userId != 0, "Not registered");
        require(users[userId].activeLevelsCount >= 1, "Must buy Level 1 to claim");
        require(block.timestamp >= users[userId].lastZeroRiskClaim + 1 days, "Wait 24h");
        require(users[userId].earnedFromZeroRisk < ZERO_RISK_CAP, "Max limit reached");
        require(zeroRiskFundBalance > 0, "Pool empty");

        uint256 claimAmount = zeroRiskFundBalance / totalPayingUsers;
        require(claimAmount > 0, "Claim amount too small");

        if(claimAmount > ZERO_RISK_DAILY_LIMIT) claimAmount = ZERO_RISK_DAILY_LIMIT; 

        if(users[userId].earnedFromZeroRisk + claimAmount > ZERO_RISK_CAP) {
            claimAmount = ZERO_RISK_CAP - users[userId].earnedFromZeroRisk;
        }

        users[userId].lastZeroRiskClaim = block.timestamp;
        users[userId].earnedFromZeroRisk += claimAmount;
        zeroRiskFundBalance -= claimAmount;

        bool success = usdtToken.transfer(msg.sender, claimAmount);
        require(success, "USDT Transfer failed");

        emit ZeroRiskClaim(userId, claimAmount);
    }
    
    // --- 7. HELPER: Send Money ---
    function sendMoney(uint256 _userId, uint256 _amount, string memory _reason) internal {
        if(_userId == 0) _userId = ADMIN_ID; 
        address receiver = users[_userId].wallet;
        
        if(receiver == address(0) || receiver == address(this)) {
            royaltyFundBalance += _amount;
            emit PayoutFailed(_userId, _amount, string(abi.encodePacked(_reason, " (Invalid Address)")));
            return;
        }

        users[_userId].totalEarnings += _amount;
        
        bool success = usdtToken.transfer(receiver, _amount);
        
        if(success) {
            emit Payout(_userId, _amount, _reason);
        } else {
            royaltyFundBalance += _amount;
            emit PayoutFailed(_userId, _amount, _reason);
        }
    }

    // --- 8. ADMIN FUNCTIONS ---
    function adminWithdrawRoyalty(uint256 _amount) external {
        require(msg.sender == owner, "Admin only");
        require(_amount <= royaltyFundBalance, "Insufficient funds");
        royaltyFundBalance -= _amount;
        
        bool success = usdtToken.transfer(owner, _amount);
        require(success, "Withdraw failed");
    }

    function adminExtractStuckFunds() external {
        require(msg.sender == owner, "Admin only");
        
        uint256 accountedFunds = royaltyFundBalance + zeroRiskFundBalance;
        uint256 actualBalance = usdtToken.balanceOf(address(this));
        
        if(actualBalance > accountedFunds) {
            uint256 stuckAmount = actualBalance - accountedFunds;
            royaltyFundBalance += stuckAmount;
            emit FundCredit("Recovered Stuck Funds", stuckAmount);
        }
    }

    function transferOwnership(address newOwner) external {
        require(msg.sender == owner, "Admin only");
        require(newOwner != address(0), "Invalid address");
        require(addressToId[newOwner] == 0 || addressToId[newOwner] == ADMIN_ID, "Address already registered");
        
        address oldOwner = owner;
        owner = newOwner;
        
        users[ADMIN_ID].wallet = newOwner;
        delete addressToId[oldOwner];
        addressToId[newOwner] = ADMIN_ID;
        
        emit OwnershipTransferred(oldOwner, newOwner);
    }

    // --- 9. FRONTEND VIEW FUNCTIONS ---
    function getUserInfo(uint256 _userId) external view returns (
        address wallet,
        uint256 referrerId,
        uint256 totalEarnings,
        uint256 totalTeamSize,
        uint256 activeTeamSize, 
        uint256 activeLevelsCount,
        uint256 earnedFromZeroRisk
    ) {
        User storage user = users[_userId];
        return (
            user.wallet,
            user.referrerId,
            user.totalEarnings,
            user.totalTeamSize,
            user.activeTeamSize,
            user.activeLevelsCount,
            user.earnedFromZeroRisk
        );
    }

    function getMatrixInfo(uint256 _userId, uint256 _level) external view returns (
        uint256 currentReferrer,
        uint256[] memory firstLevel,
        uint256[] memory secondLevel,
        uint256 recycleCount
    ) {
        Matrix storage matrix = users[_userId].matrices[_level];
        return (
            matrix.currentReferrer, 
            matrix.firstLevelReferrals, 
            matrix.secondLevelReferrals, 
            matrix.recycleCount
        );
    }

    // --- 10. TESTING DOLLAR SYSTEM ---
    event TestingDollarUsed(uint256 indexed userId, uint256 level);

    function adminActivateSlot(uint256 _userId, uint256 _level) external {
        require(msg.sender == owner, "Admin Only");
        require(users[_userId].id != 0, "User not found");
        require(_level >= 1 && _level <= 10, "Invalid Level");
        
        if (users[_userId].activeLevelsCount == 0 && _level >= 1) {
            uint256 referrerId = users[_userId].referrerId;
            users[referrerId].activeTeamSize++;
            totalPayingUsers++;
        }

        users[_userId].activeLevelsCount = _level;

        uint256 fakeAmount = packagePrice[_level];
        
        uint256 fakeCommission = (fakeAmount * DIRECT_SPONSOR_PCT) / 10000;
        uint256 activeSponsorId = findActiveReferrer(users[_userId].referrerId, _level);
        
        emit Payout(activeSponsorId, fakeCommission, "Direct Sponsor (Test)");
        emit TestingDollarUsed(_userId, _level);
    }
}