// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

import "../interfaces/IStrategy.sol";
import "../interfaces/IChainLink.sol";

import "@pancakeswap/pancake-swap-lib/contracts/token/BEP20/SafeBEP20.sol";
import "@pancakeswap/pancake-swap-lib/contracts/token/BEP20/BEP20.sol";
import "@pancakeswap/pancake-swap-lib/contracts/token/BEP20/IBEP20.sol";

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract Vault is BEP20("daoETH", "DAO ANTI IL ETH"), ReentrancyGuard {
    using SafeBEP20 for IBEP20;
    using SafeMath for uint256;

    /* ============= CONSTANTS ============= */
    IBEP20 private constant ETH =
        IBEP20(0x2170Ed0880ac9A755fd29B2688956BD959F933F8); // Binance Pegged ETH
    uint256 private constant DENOMINATOR = 10000;
    uint256 public constant LOCKTIME = 2 days;
    uint256 private constant MAX_AMT = type(uint256).max;
    IChainLink private constant ETH_ORACLE =
        IChainLink(0x9ef1B8c0E4F7dc8bF5719Ea496883DC6401d5b2e);

    /* ========== STATE VARIABLES ========== */

    /** @dev Fee Calculation
        - 0.5%-1% network fee on funds deposited to the DAOventures strategies for operational and development cost.
          - Deposit below $50,000 USD = 1%
          - Deposit between $50,000.01 USD to $100,000 USD = 0.75%
          - Deposit over $100,000 USD = 0.5%
        - 20% fee for profit sharing with the DAOventures protocol sustainability and the DVG DAO community pool.
          - 8% goes to Community profit sharing via DVG buyback on Uniswap or other DEXs and shared with users via DVG staking
          - 8% goes to the Daoventures treasury to for operational costs
          - 4% goes to the strategy makers
     */
    uint256[] public networkFeesTiers = [50000 * 1e18, 100000 * 1e18];
    uint256[] public networkFeesPerc = [100, 75, 50];
    uint256 public networkFeesTierCustom = 1000000 * 1e18;
    uint256 public networkFeesPercCustom = 25;
    uint256 public profitSharingFeePerc = 2000;
    uint256 public minimumKeepPerc = 200; // Amount of eth to keep in Vault 8% for reimburse function
    uint256 private _fees; // 18 decimals

    IStrategy public strategy;

    // Address to collect fees
    address public treasuryWallet;
    address public communityWallet;
    address public admin;
    address public strategist;

    address public pendingStrategy;
    bool public canSetPendingStrategy;
    uint256 public unlockTime;

    mapping(address => uint256) public _balanceOfDeposit; // Record deposit amount (USD in 18 decimals)

    /* ============= MODIFIERS ============= */

    /// @dev Only Admin
    modifier onlyAdmin {
        require(msg.sender == address(admin), "Vault:: Only admin");
        _;
    }

    /// @dev Only Externally Owned Accounts
    modifier onlyEOA {
        require(msg.sender == tx.origin, "Vault:: Only EOA");
        _;
    }

    /// @dev Only Owner or Strategist
    modifier onlyOwnerOrStrategist {
        require(
            msg.sender == strategist || msg.sender == owner(),
            "Vault:: Only Owner or Strategist"
        );
        _;
    }

    /* ============== EVENTS ============== */

    event Deposit(address depositor, uint256 amount, uint256 sharedMinted);
    event Withdraw(address withdrawer, uint256 amount, uint256 sharedBurned);
    event TransferredOutFees(uint256 amount);
    event Invested(uint256 amount);
    event SetNetworkFeesTiers(
        uint256[] oldNetworkFeeTier2,
        uint256[] newNetworkFeeTier2
    );
    event SetNetworkFeePerc(
        uint256[] oldNetworkFeePerc,
        uint256[] newNetworkFeePerc
    );
    event SetCustomNetworkFeeTier(
        uint256 indexed oldCustomNetworkFeeTier,
        uint256 indexed newCustomNetworkFeeTier
    );
    event SetCustomNetworkFeePerc(
        uint256 oldCustomNetworkFeePerc,
        uint256 newCustomNetworkFeePerc
    );
    event SetProfitSharingFeePerc(
        uint256 indexed oldProfileSharingFeePerc,
        uint256 indexed newProfileSharingFeePerc
    );
    event SetTreasuryWallet(address indexed _treasuryWallet);
    event SetCommunityWallet(address indexed _communityWallet);
    event SetAdminWallet(address indexed _admin);
    event SetStrategistWallet(address indexed _strategistWallet);
    event SetPendingStrategy(address indexed _pendingStrategy);
    event SetMinimumKeepPerc(uint256 _minimumKeepPerc);
    event UnlockMigrateFunds(uint256 unlockTime);
    event MigrateFunds(
        address indexed fromStrategy,
        address indexed toStrategy,
        uint256 amount
    );

    /* ============ CONSTRUCTOR ============ */

    constructor(
        address _strategy,
        address _treasuryWallet,
        address _communityWallet,
        address _strategist,
        address _admin
    ) public {
        strategy = IStrategy(_strategy);
        treasuryWallet = _treasuryWallet;
        communityWallet = _communityWallet;
        strategist = _strategist;
        admin = _admin;

        ETH.safeApprove(_strategy, MAX_AMT);

        canSetPendingStrategy = true;
    }

    /* =========== VIEW FUNCTIONS =========== */

    /// @notice Get Total Value Locked in this vault in USD
    /// @return _tvl Total Value Locked
    function getTVL() external view returns (uint256 _tvl) {
        uint256 _ethPrice = uint256(ETH_ORACLE.latestAnswer());
        uint256 _totalPool = getTotalPool();
        _tvl = _totalPool.mul(_ethPrice).div(1e18);
    }

    /// @notice Get strategy + vault pool in ETH
    /// @return _totalPool All pool in ETH (18 decimals)
    function getTotalPool() public view returns (uint256 _totalPool) {
        uint256 _vaultPool = getVaultPool();
        uint256 _strategyPool = strategy.getStrategyPool();
        _totalPool = _vaultPool.add(_strategyPool);
    }

    /// @notice Get vault pool in ETH
    /// @return _vaultPool All pool in ETH (18 decimals)
    function getVaultPool() public view returns (uint256 _vaultPool) {
        _vaultPool = ETH.balanceOf(address(this));
        _vaultPool = _vaultPool.sub(_fees);
    }

    /// @notice Get Minimum Keep
    /// @return _minimumKeep All pool in ETH (18 decimals)
    function getMinimumKeep() external view returns (uint256 _minimumKeep) {
        _minimumKeep = getTotalPool().mul(minimumKeepPerc).div(DENOMINATOR);
    }

    /* ========= MUTATIVE FUNCTIONS ========= */

    /// @notice Deposit ETH and mint for Depositer some Shares (daoETH)
    /// @param _amount Amount to deposit
    function deposit(uint256 _amount) external nonReentrant onlyEOA {
        require(_amount > 0, "Vault::deposit: _amount <= 0");

        uint256 _pool = getTotalPool();
        uint256 _totalSupply = totalSupply(); // Total Supply After Deposit
        uint256 _amtDeposit = _amount; // Deposit Amount before fees

        ETH.safeTransferFrom(msg.sender, address(this), _amount);

        uint256 _fee = _calcNetworkFee(_amount);

        _fees = _fees.add(_fee);
        _amount = _amount.sub(_fee);

        _balanceOfDeposit[msg.sender] = _balanceOfDeposit[msg.sender].add(
            _amount
        );

        uint256 _shares = _totalSupply == 0
            ? _amount
            : _amount.mul(_totalSupply).div(_pool);

        _mint(msg.sender, _shares);
        emit Deposit(msg.sender, _amtDeposit, _shares);
    }

    /// @notice Withdraw ETH with shares
    /// @param _shares Amount of shares to withdraw (from LP token, 18 decimals)
    function withdraw(uint256 _shares) external nonReentrant onlyEOA {
        require(_shares > 0, "Vault::withdraw: _shares <= 0");
        uint256 _totalShares = balanceOf(msg.sender);
        uint256 _fee = 0;
        uint256 _amountWithdrawn = 0;
        uint256 _withdrawAmountFromStrategy;
        require(
            _shares <= _totalShares,
            "Vault::withdraw: Insufficient Shares"
        );

        // Calculate ETH to return to user
        uint256 _withdrawAmount = _calcShareToETH(_shares);

        uint256 _balanceOfETH = ETH.balanceOf(address(this));
        uint256 _vaultBalanceBefore = getVaultPool();

        // Check if Vault Has ETH to return to user, else, withdraw from vault directly
        // Only withdraw what is needed.
        if (_withdrawAmount > _balanceOfETH) {
            _withdrawAmountFromStrategy = _withdrawAmount.sub(getVaultPool());
            strategy.withdraw(_withdrawAmountFromStrategy);
        }

        uint256 _vaultBalanceAfter = getVaultPool();

        // Actual Amount Withdrawn from strategy after fees
        if (_vaultBalanceAfter > _vaultBalanceBefore) {
            _amountWithdrawn = _vaultBalanceAfter.sub(_vaultBalanceBefore);
        }

        // Check if user has profited
        if (_withdrawAmount > _balanceOfDeposit[msg.sender]) {
            // Calculate profit sharing fee
            _fee = _calcProfitSharingFee(_shares);
            _balanceOfDeposit[msg.sender] = 0;
        } else {
            _balanceOfDeposit[msg.sender] = _balanceOfDeposit[msg.sender].sub(
                _withdrawAmount
            );
        }

        _withdrawAmount = _withdrawAmount.sub(_fee);
        _fees = _fees.add(_fee);

        ETH.safeTransfer(msg.sender, _withdrawAmount);
        _burn(msg.sender, _shares);

        emit Withdraw(msg.sender, _withdrawAmount, _shares);
    }

    /* ========= PRIVATE FUNCTIONS ========= */

    function _calcNetworkFee(uint256 _amount)
        private
        view
        returns (uint256 _fee)
    {
        uint256 _depositValue = _getValueInUSD(_amount);

        if (_depositValue < networkFeesTiers[0]) {
            // Less than $50000
            _fee = _amount.mul(networkFeesPerc[0]).div(DENOMINATOR);
        } else if (_depositValue <= networkFeesTiers[1]) {
            // greater than or equal to $50000, less than $100000
            _fee = _amount.mul(networkFeesPerc[1]).div(DENOMINATOR);
        } else if (_depositValue < networkFeesTierCustom) {
            // greater than or equal to $100000, less than ${networkFeesTierCustom}
            _fee = _amount.mul(networkFeesPerc[2]).div(DENOMINATOR);
        } else {
            // greater than or equal to ${networkFeesTierCustom}
            _fee = _amount.mul(networkFeesPercCustom).div(DENOMINATOR);
        }
    }

    /// @notice Get Total Value Locked in this vault in USD
    function _getValueInUSD(uint256 _amount)
        private
        view
        returns (uint256 _amountUSD)
    {
        uint256 _ethPrice = uint256(ETH_ORACLE.latestAnswer());
        _amountUSD = _amount.mul(_ethPrice).div(1e18);
    }

    /// @notice Calculates share to ETH exchange rate
    /// @dev _rate = _totalPool / totalSupply()
    function _calcShareToETH(uint256 _shares)
        private
        view
        returns (uint256 _ethAmount)
    {
        uint256 _totalPool = getTotalPool(); // In eth
        uint256 _totalSupply = totalSupply(); // in daoETH
        _ethAmount = _shares.mul(_totalPool).div(_totalSupply);
    }

    /// @notice Calculate profit sharing fee
    /// @dev Determine if user has made a profit in ETH since deposit and apply fees if true
    function _calcProfitSharingFee(uint256 _shares)
        private
        view
        returns (uint256 _fee)
    {
        uint256 _totalShares = balanceOf(msg.sender);
        uint256 _depositAmount = _balanceOfDeposit[msg.sender];
        uint256 _currentValue = _calcShareToETH(balanceOf(msg.sender));
        _fee = 0;

        if (_currentValue > _depositAmount) {
            uint256 _totalProfit = _currentValue.sub(_depositAmount);
            uint256 _profitPerc = _totalProfit.div(_depositAmount);
            uint256 _profit = _shares.div(_totalShares).mul(_profitPerc);
            _fee = _profit.mul(profitSharingFeePerc).div(DENOMINATOR);
        }
    }

    /// @notice Function to transfer fees that collect from yield to wallets
    /// @param _amount Fees to transfer in ETH Token
    function _splitNetworkFees(uint256 _amount) private {
        uint256 _creditToAdmin = (_amount).mul(2).div(5);
        uint256 _creditToCommunityWallet = (_amount).mul(2).div(5);
        uint256 _creditToStrategist = (_amount).mul(1).div(5);

        ETH.safeTransfer(admin, _creditToAdmin); // 40%
        ETH.safeTransfer(communityWallet, _creditToCommunityWallet); // 40%
        ETH.safeTransfer(strategist, _creditToStrategist); // 20%

        emit TransferredOutFees(_amount);
        _fees = 0;
    }

    /* ========== ADMIN FUNCTIONS ========== */

    /// @notice Function to invest funds into strategy
    function invest() external onlyAdmin {
        // Invest all swapped WETH to strategy
        uint256 _balanceOfETH = getVaultPool();
        require(
            _balanceOfETH > 0,
            "Vault::invest: insufficient vault ETH balance"
        );

        // Transfer out network fees
        if (_fees != 0 && ETH.balanceOf(address(this)) > _fees) {
            _splitNetworkFees(_fees);
        }

        uint256 _vaultPool = getVaultPool();

        // Calculation for keep portion of ETH
        uint256 _toKeepETH = _vaultPool.mul(minimumKeepPerc).div(DENOMINATOR);

        require(_vaultPool > _toKeepETH, "Vault::invest: insufficient ETH");
        uint256 _investAmount = getVaultPool().sub(_toKeepETH);

        // Invest all swapped WETH to strategy
        if (_investAmount > 0) {
            strategy.invest(_investAmount);
            emit Invested(_investAmount);
        }
    }

    /// @notice Function to reimburse keep Tokens from strategy
    /// @notice This function remove liquidity from all strategy farm and will cost massive gas fee. Only call when needed.
    function reimburseTokenFromStrategy() external onlyAdmin {
        strategy.reimburse();
    }

    /// @notice Function to withdraw all farms and swap to WETH in strategy
    function emergencyWithdraw() external onlyAdmin {
        strategy.emergencyWithdraw();
    }

    /// @notice Function to reinvest all WETH back to farms in strategy
    function reinvest() external onlyAdmin {
        strategy.reinvest();
    }

    /// @notice Function to yield farms reward in strategy
    function yield() external onlyAdmin {
        strategy.compound();
    }

    /// @notice Function to set new network fee for deposit amount tier 2
    /// @param _newNetworkFeesTiers Array that contains minimum and maximum amount of tier 2 (18 decimals)
    /** @dev
     * Network fees have three tier, but it is sufficient to have minimun and maximun amount of tier 2
     * Tier 1: deposit amount < minimun amount of tier 2
     * Tier 2: minimun amount of tier 2 <= deposit amount <= maximun amount of tier 2
     * Tier 3: amount > maximun amount of tier 2
     */
    function setNetworkFeesTiers(uint256[] calldata _newNetworkFeesTiers)
        external
        onlyOwner
    {
        require(
            _newNetworkFeesTiers[0] != 0,
            "Vault::setNetworkFeesTiers: Minimum Tier amount cannot be 0"
        );
        require(
            _newNetworkFeesTiers[1] > _newNetworkFeesTiers[0],
            "Vault::setNetworkFeesTiers: Maximum Tier amount must greater than minimun amount"
        );

        uint256[] memory _oldNetworkFeeTiers = networkFeesTiers;
        networkFeesTiers = _newNetworkFeesTiers;
        emit SetNetworkFeesTiers(_oldNetworkFeeTiers, _newNetworkFeesTiers);
    }

    /// @notice Function to set new custom network fee tier
    /// @param _networkFeesTierCustom Amount of new custom network fee tier (18 decimals)
    function setCustomNetworkFeeTier(uint256 _networkFeesTierCustom)
        external
        onlyOwner
    {
        require(
            _networkFeesTierCustom > networkFeesTiers[1],
            "Vault::setCustomNetworkFeeTier: Custom network fee tier must greater than tier 2"
        );

        uint256 oldNetworkFeesTierCustom = networkFeesTierCustom;
        networkFeesTierCustom = _networkFeesTierCustom;
        emit SetCustomNetworkFeeTier(
            oldNetworkFeesTierCustom,
            _networkFeesTierCustom
        );
    }

    /// @notice Function to set new network fee percentage
    /// @param _networkFeesPerc Array that contains new network fee percentage for tier 1, tier 2 and tier 3
    function setNetworkFeePerc(uint256[] calldata _networkFeesPerc)
        external
        onlyOwner
    {
        require(
            _networkFeesPerc[0] < 3000 &&
                _networkFeesPerc[1] < 3000 &&
                _networkFeesPerc[2] < 3000,
            "Vault::setNetworkFeePerc: Network fee percentage cannot be more than 30%"
        );
        /**
         * _networkFeePerc content a array of 3 element, representing network fee of tier 1, tier 2 and tier 3
         * For example networkFeesPerc is [100, 75, 50]
         * which mean network fee for Tier 1 = 1%, Tier 2 = 0.75% and Tier 3 = 0.5%
         */
        uint256[] memory oldNetworkFeesPerc = networkFeesPerc;
        networkFeesPerc = _networkFeesPerc;
        emit SetNetworkFeePerc(oldNetworkFeesPerc, _networkFeesPerc);
    }

    /// @notice Function to set new custom network fee percentage
    /// @param _percentage Percentage of new custom network fee
    function setCustomNetworkFeePerc(uint256 _percentage) public onlyOwner {
        require(
            _percentage < networkFeesPerc[2],
            "Vault::setCustomNetworkFeePerc: Custom network fee percentage cannot be more than tier 2"
        );

        uint256 oldCustomNetworkFeePerc = networkFeesPercCustom;
        networkFeesPercCustom = _percentage;
        emit SetCustomNetworkFeePerc(oldCustomNetworkFeePerc, _percentage);
    }

    /// @notice Function to set new profit sharing fee percentage
    /// @param _percentage Percentage of new profit sharing fee
    function setProfitSharingFeePerc(uint256 _percentage) external onlyOwner {
        require(
            _percentage < 3000,
            "Vault::setProfitSharingFeePerc: Profile sharing fee percentage cannot be more than 30%"
        );

        uint256 oldProfitSharingFeePerc = profitSharingFeePerc;
        profitSharingFeePerc = _percentage;
        emit SetProfitSharingFeePerc(oldProfitSharingFeePerc, _percentage);
    }

    /// @notice Set the minimum amount of ETH to keep in vault in percentage
    /// @param _minimumKeepPerc New minimum amount of ETH to keep in vault in percentage
    function setMinimumKeepPerc(uint256 _minimumKeepPerc) external onlyAdmin {
        require(
            _minimumKeepPerc <= DENOMINATOR,
            "Vault::setMinimumKeepPerc: Invalid Input"
        );
        require(
            _minimumKeepPerc >= 0,
            "Vault::setMinimumKeepPerc: Invalid Input"
        );
        minimumKeepPerc = _minimumKeepPerc;
        emit SetMinimumKeepPerc(_minimumKeepPerc);
    }

    /// @notice Function to set new treasury wallet address
    /// @param _treasuryWallet Address of new treasury wallet
    function setTreasuryWallet(address _treasuryWallet) external onlyOwner {
        treasuryWallet = _treasuryWallet;
        emit SetTreasuryWallet(_treasuryWallet);
    }

    /// @notice Function to set new community wallet address
    /// @param _communityWallet Address of new community wallet
    function setCommunityWallet(address _communityWallet) external onlyOwner {
        communityWallet = _communityWallet;
        emit SetCommunityWallet(_communityWallet);
    }

    /// @notice Function to set new admin address
    /// @param _admin Address of new admin
    function setAdmin(address _admin) external onlyOwner {
        admin = _admin;
        strategy.setAdmin(_admin);
        emit SetAdminWallet(_admin);
    }

    /// @notice Function to set new strategist address
    /// @param _strategist Address of new strategist
    function setStrategist(address _strategist) external onlyOwnerOrStrategist {
        strategist = _strategist;
        strategy.setStrategist(_strategist);
        emit SetStrategistWallet(_strategist);
    }

    /// @notice Function to set pending strategy address
    /// @param _pendingStrategy Address of pending strategy
    function setPendingStrategy(address _pendingStrategy) external onlyOwner {
        require(
            canSetPendingStrategy,
            "Vault::setPendingStrategy: Cannot set pending strategy now"
        );
        pendingStrategy = _pendingStrategy;
        emit SetPendingStrategy(_pendingStrategy);
    }

    /// @notice Function to unlock migrate funds function
    function unlockMigrateFunds() external onlyOwner {
        unlockTime = block.timestamp.add(LOCKTIME);
        canSetPendingStrategy = false;
        emit UnlockMigrateFunds(unlockTime);
    }

    /// @notice Function to migrate all funds from old strategy contract to new strategy contract
    function migrateFunds() external onlyOwner {
        require(
            unlockTime <= block.timestamp &&
                unlockTime.add(1 days) >= block.timestamp,
            "Vault::migrateFunds: Function locked"
        );
        require(
            ETH.balanceOf(address(strategy)) > 0,
            "Vault::migrateFunds: Strategy 0 balance to migrate"
        );
        require(
            pendingStrategy != address(0),
            "Vault::migrateFunds: No pendingStrategy"
        );

        uint256 _amount = ETH.balanceOf(address(strategy));
        ETH.safeTransferFrom(address(strategy), pendingStrategy, _amount);

        // Set new strategy
        address oldStrategy = address(strategy);
        strategy = IStrategy(pendingStrategy);
        pendingStrategy = address(0);
        canSetPendingStrategy = true;

        // Approve new strategy
        ETH.safeApprove(address(strategy), type(uint256).max);
        ETH.safeApprove(oldStrategy, 0);

        unlockTime = 0; // Lock back this function
        emit MigrateFunds(oldStrategy, address(strategy), _amount);
    }
}
