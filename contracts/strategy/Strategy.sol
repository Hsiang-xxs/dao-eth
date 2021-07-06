// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

// TODO: REMOVE
import "hardhat/console.sol";

import "../interfaces/IStrategy.sol";
import "../interfaces/IVault.sol";

import "../interfaces/IPancakeRouter02.sol";
import "../interfaces/IWaultSwapRouter02.sol";
import "../interfaces/ISwap.sol";

import "../interfaces/IWaultPair.sol";
import "../interfaces/INervePair.sol";

import "../interfaces/IWexMaster.sol";
import "../interfaces/IMasterMind.sol";

import "@pancakeswap/pancake-swap-lib/contracts/token/BEP20/IBEP20.sol";
import "@pancakeswap/pancake-swap-lib/contracts/token/BEP20/SafeBEP20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

contract Strategy is IStrategy, Ownable, Pausable {
    using SafeBEP20 for IBEP20;
    using SafeBEP20 for IWaultPair;
    using SafeBEP20 for INervePair;
    using SafeMath for uint256;

    /* ============= CONSTANTS ============= */
    IBEP20 private WBNB = IBEP20(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);
    IBEP20 private ETH = IBEP20(0x2170Ed0880ac9A755fd29B2688956BD959F933F8); // Binance Pegged ETH
    IBEP20 private BETH = IBEP20(0x250632378E573c6Be1AC2f97Fcdf00515d0Aa91B);
    IBEP20 private constant ANYETH =
        IBEP20(0x6F817a0cE8F7640Add3bC0c1C2298635043c2423);
    IBEP20 private constant WEX =
        IBEP20(0xa9c41A46a6B3531d28d5c32F6633dd2fF05dFB90);
    IBEP20 private constant NRV =
        IBEP20(0x42F6f551ae042cBe50C739158b4f0CAC0Edb9096);

    IWaultPair private constant ETH_BETH_LP =
        IWaultPair(0x11040f3c467993556B19813d4A18b684598Ba4BD); // WaultSwap WETH-BETH LP
    INervePair private constant ETH_ANYETH_LP =
        INervePair(0x0d283BF16A9bdE49cfC48d8dc050AF28b71bdD90); // Nerve WETH-anyETH LP

    IPancakeRouter02 private constant PANCAKE_ROUTER =
        IPancakeRouter02(0x05fF2B0DB69458A0750badebc4f9e13aDd608C7F); // PCS Router V2
    IWaultSwapRouter02 private constant WAULT_ROUTER =
        IWaultSwapRouter02(0xD48745E39BbED146eEC15b79cBF964884F9877c2); // WaultSwap Router
    ISwap private constant NERVE_SWAP =
        ISwap(0x146CD24dCc9f4EB224DFd010c5Bf2b0D25aFA9C0); // Nerve ETH-anyETH LP maker

    IWexMaster private constant WAULT_FARM =
        IWexMaster(0x22fB2663C7ca71Adc2cc99481C77Aaf21E152e2D); // Wault WETH-BETH Farm, pid = 42
    IMasterMind private constant NERVE_FARM =
        IMasterMind(0x2EBe8CDbCB5fB8564bC45999DAb8DA264E31f24E); // Nerve WETH-anyETH Farm, pid = 5

    uint256 private constant WAULT_PID = 42;
    uint256 private constant NERVE_PID = 5;

    uint8 private constant ETH_NERVE_TOKEN_ID = 0;
    uint8 private constant ANYETH_NERVE_TOKEN_ID = 1;

    uint256 private constant DENOMINATOR = 10000;

    uint256 private constant MAX_AMT = type(uint256).max;

    uint256 private constant ONE = 1e18;

    /* ========== STATE VARIABLES ========== */

    // LP token price in ETH
    uint256 public _price_ETH_BETH_LP; // Might not need
    uint256 public _price_ETH_ANYETH_LP;

    // Pool in ETH
    uint256 public _pool_ETH_BETH_LP;
    uint256 public _pool_ETH_ANYETH_LP;

    address public admin;
    address public communityWallet;
    address public strategist;
    IVault public vault;

    // Farm Allocation Weights
    uint256 public waultFarmPerc = 5000; // 50% allocation to Wault
    uint256 public nerveFarmPerc = 5000; // 50% allocation to Nerve

    // Fees
    uint256 public yieldFeePerc = 1000; // 10% Yield fees

    // Information
    uint256 public totalWaultYield = 0;
    uint256 public totalNerveYield = 0;

    /* ============= MODIFIERS ============= */

    modifier onlyAdmin {
        require(msg.sender == address(admin), "Strategy:: Only Admin");
        _;
    }

    modifier onlyVault {
        require(msg.sender == address(vault), "Strategy:: Only Vault");
        _;
    }

    /* ============== EVENTS ============== */
    event Invested(uint256 ethInvested);

    event LiquidityRemoved(
        address lpToken,
        uint256 liquidityRemoved,
        uint256 amountA,
        uint256 amountB,
        address router
    );

    event LiquidityAdded(
        address tokenA,
        address tokenB,
        uint256 amountA,
        uint256 amountB,
        uint256 liquidity,
        address router
    );

    event SetVault(address vaultAddress);
    event SetAdmin(address adminAddress);
    event SetStrategist(address strategistAddress);
    event Harvested(uint256 claimedWEX, uint256 claimedNRV);
    event Withdrawn(uint256 amount, uint256 withdrawalFee);

    /* ============ CONSTRUCTOR ============ */

    constructor(
        address _communityWallet,
        address _strategist,
        address _admin
    ) public {
        require(
            _communityWallet != address(0),
            "Strategy::constructor: communityWallet does not exist"
        );
        communityWallet = _communityWallet;
        strategist = _strategist;
        admin = _admin;

        ETH.safeApprove(address(PANCAKE_ROUTER), MAX_AMT);
        ETH.safeApprove(address(WAULT_ROUTER), MAX_AMT);
        ETH.safeApprove(address(NERVE_SWAP), MAX_AMT);
        BETH.safeApprove(address(PANCAKE_ROUTER), MAX_AMT);
        BETH.safeApprove(address(WAULT_ROUTER), MAX_AMT);
        ANYETH.safeApprove(address(PANCAKE_ROUTER), MAX_AMT);
        ANYETH.safeApprove(address(NERVE_SWAP), MAX_AMT);
        ETH_BETH_LP.safeApprove(address(WAULT_FARM), MAX_AMT);
        ETH_BETH_LP.safeApprove(address(WAULT_ROUTER), MAX_AMT);
        ETH_ANYETH_LP.safeApprove(address(NERVE_FARM), MAX_AMT);
        ETH_ANYETH_LP.safeApprove(address(NERVE_SWAP), MAX_AMT);
        WEX.safeApprove(address(PANCAKE_ROUTER), MAX_AMT);
        NRV.safeApprove(address(PANCAKE_ROUTER), MAX_AMT);
    }

    receive() external payable {
        // ...
    }

    fallback() external {
        // ...
    }

    /* =========== VIEW FUNCTIONS =========== */

    /// @notice Get TVL of Strategy in ETH
    function getStrategyPool()
        public
        view
        override
        returns (uint256 _valueInEth)
    {
        uint256 _valueInEth_ETH_BETH_LP = _pool_ETH_BETH_LP
        .mul(_calcPriceETH_BETH_LP())
        .div(1e18);

        uint256 _valueInEth_ETH_ANYETH_LP = _pool_ETH_ANYETH_LP
        .mul(_calcPriceETH_ANYETH_LP())
        .div(1e18);

        _valueInEth = _valueInEth_ETH_BETH_LP.add(_valueInEth_ETH_ANYETH_LP);
    }

    /* ========= MUTATIVE FUNCTIONS ========= */

    /// @notice Invest tokens into Wault and Nerve Farms
    /// @param _amount Amount of ETH to invest
    function invest(uint256 _amount) public override onlyVault whenNotPaused {
        require(_amount > 0, "Strategy::invest: Invest Amount <= 0");

        ETH.safeTransferFrom(address(vault), address(this), _amount);

        // Divide by 2 to maintain the 1:1 ETH:BETH for LP
        uint256 _amountToBETH = _amount.mul(waultFarmPerc).div(2).div(
            DENOMINATOR
        );

        uint256 _amountToANYETH = _amount.mul(nerveFarmPerc).div(2).div(
            DENOMINATOR
        );

        uint256 _amountRemaining = _amount.sub(_amountToBETH).sub(
            _amountToANYETH
        );

        uint256 _amountBETH = _swapETHforBETH(_amountToBETH);
        uint256 _amountANYETH = _swapETHforANYETH(_amountToANYETH);

        uint256 _amount_ETH_BETH_LP = _addLiquidityWault(
            _amountRemaining.div(2),
            _amountBETH
        );

        _amountRemaining = _amountRemaining.sub(_amountRemaining.div(2));
        uint256 _amount_ETH_ANYETH_LP = _addLiquidityNerve(
            _amountRemaining,
            _amountANYETH
        );

        _investWault(_amount_ETH_BETH_LP);
        _investNerve(_amount_ETH_ANYETH_LP);

        // Update Pool

        uint256 _pool_ETH_BETH_LP_before = _pool_ETH_BETH_LP;
        (uint256 _pool_ETH_BETH_LP_after, , ) = WAULT_FARM.userInfo(
            WAULT_PID,
            address(this)
        );
        uint256 _pool_ETH_ANYETH_LP_before = _pool_ETH_ANYETH_LP;
        (uint256 _pool_ETH_ANYETH_LP_after, ) = NERVE_FARM.userInfo(
            NERVE_PID,
            address(this)
        );
        _pool_ETH_BETH_LP = _pool_ETH_BETH_LP.add(
            _pool_ETH_BETH_LP_after.sub(_pool_ETH_BETH_LP_before)
        );
        _pool_ETH_ANYETH_LP = _pool_ETH_ANYETH_LP.add(
            _pool_ETH_ANYETH_LP_after.sub(_pool_ETH_ANYETH_LP_before)
        );

        emit Invested(_amount);
    }

    /// @notice Withdraw tokens from farms and swap into ETH
    /// @dev Liquidate enough LP tokens to meet the amount, 50% from Wault and 50% from Nerve
    function withdraw(uint256 _amount) public override onlyVault whenNotPaused {
        require(_amount > 0, "Strategy::withdraw: Withdraw Amount <= 0)");

        uint256 _strategyPool = getStrategyPool();

        uint256 _amount_ETH_BETH_LP = _amount.mul(_pool_ETH_BETH_LP).div(
            _strategyPool
        );

        uint256 _amount_ETH_ANYETH_LP = _amount.mul(_pool_ETH_ANYETH_LP).div(
            _strategyPool
        );

        // Withdrawing automatically harvests yields
        _withdrawWault(_amount_ETH_BETH_LP);
        _withdrawNerve(_amount_ETH_ANYETH_LP);

        (
            uint256 _amountETHFromWault,
            uint256 _amountBETH
        ) = _removeLiquidityWault(_amount_ETH_BETH_LP);
        (
            uint256 _amountETHFromNerve,
            uint256 _amountANYETH
        ) = _removeLiquidityNerve(_amount_ETH_ANYETH_LP);

        _pool_ETH_BETH_LP = _pool_ETH_BETH_LP.sub(_amount_ETH_BETH_LP);
        _pool_ETH_ANYETH_LP = _pool_ETH_ANYETH_LP.sub(_amount_ETH_ANYETH_LP);

        uint256 _totalRewards = _liquidateRewards(); // in ETH
        uint256 _fees = _totalRewards.mul(yieldFeePerc).div(DENOMINATOR);
        _splitYieldFees(_fees);
        // Swap BETH and anyETH back to ETH
        uint256 _amountETHFromBETH = _swapBETHforETH(_amountBETH);
        uint256 _amountETHFromANYETH = _swapANYETHforETH(_amountANYETH);
        uint256 _amountETH = _amountETHFromWault.add(_amountETHFromNerve).add(
            _totalRewards
        );
        _amountETH = _amountETH.sub(_fees).add(_amountETHFromBETH).add(
            _amountETHFromANYETH
        );

        // Send deserved ETH back to Vault
        ETH.safeTransfer(address(vault), _amountETH);
    }

    /// @notice Harvest yields from farms and reinvest them
    function compound() external override onlyVault whenNotPaused {
        _harvest();
        uint256 _amount = _liquidateRewards();
        invest(_amount);
    }

    /* ========= PRIVATE FUNCTIONS ========= */

    /// @notice Invest ETH-BETH LP tokens into WexMaster
    function _investWault(uint256 _amount) private {
        require(
            _amount > 0,
            "Strategy::_investWault: Invalid Amount (_amount <= 0)"
        );
        WAULT_FARM.deposit(WAULT_PID, _amount, false);
    }

    /// @notice Invest ETH-anyETH LP tokens into MasterMind
    function _investNerve(uint256 _amount) private {
        require(
            _amount > 0,
            "Strategy::_investNerve: Invalid Amount (_amount <= 0)"
        );
        NERVE_FARM.deposit(NERVE_PID, _amount);
    }

    /// @notice Withdraw ETH-BETH LP Tokens from WexMaster
    function _withdrawWault(uint256 _amount) private {
        WAULT_FARM.withdraw(WAULT_PID, _amount, true);
    }

    /// @notice Withdraw ETH-anyETH LP Tokens from MasterMind
    function _withdrawNerve(uint256 _amount) private {
        NERVE_FARM.withdraw(NERVE_PID, _amount);
    }

    /// @notice Harvest yields from farms
    function _harvest() private {
        uint256 _claimedWEX = _harvestWault();
        uint256 _claimedNRV = _harvestNerve();

        totalWaultYield = totalWaultYield.add(_claimedWEX);
        totalNerveYield = totalNerveYield.add(_claimedNRV);

        emit Harvested(_claimedWEX, _claimedNRV);
    }

    /// @notice Harvest Wault Rewards
    function _harvestWault() private returns (uint256 _rewardsClaimed) {
        uint256 _pendingRewards = WAULT_FARM.pendingWex(
            WAULT_PID,
            address(this)
        );
        _rewardsClaimed = 0;

        // Check if pending WEX is above 0
        if (_pendingRewards > 0) {
            WAULT_FARM.claim(WAULT_PID);
            _rewardsClaimed = _pendingRewards;
        }
    }

    /// @notice Harvest Nerve Rewards
    function _harvestNerve() private returns (uint256 _rewardsClaimed) {
        uint256 _pendingRewards = NERVE_FARM.pendingNerve(
            NERVE_PID,
            address(this)
        );
        _rewardsClaimed = 0;

        // Check if pending NRV is above 0
        // TODO: Write logic to claim NRV rewards, Nerve Finance locks up 2/3 rewards and does not have claim function
        if (_pendingRewards > 0) {
            NERVE_FARM.withdraw(NERVE_PID, 0);
            _rewardsClaimed = _pendingRewards;
        }
    }

    /// @notice Swaps ETH for BETH on Pancake Router
    function _swapETHforBETH(uint256 _amount)
        private
        returns (uint256 _amountBETH)
    {
        uint256[] memory _amounts = _swapExactTokensForTokens(
            address(ETH),
            address(BETH),
            _amount
        );
        _amountBETH = _amounts[1];
    }

    /// @notice Swaps ETH for anyETH on Pancake Router
    function _swapETHforANYETH(uint256 _amount)
        private
        returns (uint256 _amountANYETH)
    {
        // Only nerveswap has liquidity
        uint256 _amountsOut = NERVE_SWAP.calculateSwap(
            ETH_NERVE_TOKEN_ID,
            ANYETH_NERVE_TOKEN_ID,
            _amount
        );

        if (_amountsOut > 0) {
            _amountANYETH = NERVE_SWAP.swap(
                ETH_NERVE_TOKEN_ID,
                ANYETH_NERVE_TOKEN_ID,
                _amount,
                0,
                block.timestamp
            );
        } else {
            // Not enough amount to swap
            _amountANYETH = 0;
        }
    }

    /// @notice Swaps BETH for ETH on Pancake Router
    function _swapBETHforETH(uint256 _amount)
        private
        returns (uint256 _amountETH)
    {
        uint256[] memory _amounts = _swapExactTokensForTokens(
            address(BETH),
            address(ETH),
            _amount
        );
        _amountETH = _amounts[1];
    }

    /// @notice Swaps ANYETH for ETH on Pancake Router
    function _swapANYETHforETH(uint256 _amount)
        private
        returns (uint256 _amountETH)
    {
        // Only nerveswap has liquidity
        uint256 _amountsOut = NERVE_SWAP.calculateSwap(
            ANYETH_NERVE_TOKEN_ID,
            ETH_NERVE_TOKEN_ID,
            _amount
        );

        if (_amountsOut > 0) {
            _amountETH = NERVE_SWAP.swap(
                ANYETH_NERVE_TOKEN_ID,
                ETH_NERVE_TOKEN_ID,
                _amount,
                0,
                block.timestamp
            );
        } else {
            // Not enough amount to swap
            _amountETH = 0;
        }
    }

    /// @notice Get Wault ETH-BETH LP tokens
    function _addLiquidityWault(uint256 _amountETH, uint256 _amountBETH)
        private
        returns (uint256)
    {
        (uint256 _amountA, uint256 _amountB, uint256 _liquidity) = WAULT_ROUTER
        .addLiquidity(
            address(ETH),
            address(BETH),
            _amountETH,
            _amountBETH,
            0,
            0,
            address(this),
            block.timestamp
        );

        emit LiquidityAdded(
            address(ETH),
            address(BETH),
            _amountA,
            _amountB,
            _liquidity,
            address(WAULT_ROUTER)
        );

        return _liquidity;
    }

    /// @notice Get Nerve ETH-anyETH LP tokens
    function _addLiquidityNerve(uint256 _amountETH, uint256 _amountANYETH)
        private
        returns (uint256 _liquidity)
    {
        uint256[] memory _amounts = new uint256[](2);
        _amounts[0] = _amountETH;
        _amounts[1] = _amountANYETH;

        _liquidity = NERVE_SWAP.addLiquidity(_amounts, 0, block.timestamp);

        emit LiquidityAdded(
            address(ETH),
            address(ANYETH),
            _amountETH,
            _amountANYETH,
            _liquidity,
            address(NERVE_SWAP)
        );
    }

    /// @notice Remove ETH-BETH Liquidity from Wault Swap
    function _removeLiquidityWault(uint256 _amount)
        private
        returns (uint256 _amountA, uint256 _amountB)
    {
        (_amountA, _amountB) = WAULT_ROUTER.removeLiquidity(
            address(ETH),
            address(BETH),
            _amount,
            0,
            0,
            address(this),
            block.timestamp
        );

        emit LiquidityRemoved(
            address(ETH_BETH_LP),
            _amount,
            _amountA,
            _amountB,
            address(WAULT_ROUTER)
        );
    }

    /// @notice Remove ETH-anyETH Liquidity from Nerve Swap
    function _removeLiquidityNerve(uint256 _amount)
        private
        returns (uint256 _amountA, uint256 _amountB)
    {
        uint256[] memory _minAmounts = new uint256[](2);
        _minAmounts[0] = 0;
        _minAmounts[1] = 0;

        uint256[] memory _returnedAmounts = NERVE_SWAP.removeLiquidity(
            _amount,
            _minAmounts,
            block.timestamp
        );

        _amountA = _returnedAmounts[0];
        _amountB = _returnedAmounts[1];

        emit LiquidityRemoved(
            address(ETH_ANYETH_LP),
            _amount,
            _amountA,
            _amountB,
            address(NERVE_SWAP)
        );
    }

    /// @notice Convert all rewards (WEX + NRV) into base token (ETH)
    function _liquidateRewards() private returns (uint256 _totalRewards) {
        // Liquidate Wault Rewards
        uint256 _waultRewards = _liquidateWaultRewards();
        // Liquidate Nerve Rewards
        uint256 _nerveRewards = _liquidateNerveRewards();
        // Calculate total ETH gained from rewards
        _totalRewards = _waultRewards.add(_nerveRewards);
    }

    /// @notice Function to transfer fees that collect from yield to wallets
    /// @param _amount Fees to transfer in ETH Token
    function _splitYieldFees(uint256 _amount) private {
        uint256 _creditToAdmin = (_amount).mul(2).div(5);
        uint256 _creditToCommunityWallet = (_amount).mul(2).div(5);
        uint256 _creditToStrategist = (_amount).mul(1).div(5);

        ETH.safeTransfer(admin, _creditToAdmin); // 40%
        ETH.safeTransfer(communityWallet, _creditToCommunityWallet); // 40%
        ETH.safeTransfer(strategist, _creditToStrategist); // 20%
    }

    /// @notice Converts WEX rewards to ETH
    function _liquidateWaultRewards() private returns (uint256 _yieldAmount) {
        uint256 _balanceOfWEX = WEX.balanceOf(address(this));
        _yieldAmount = 0;

        if (_balanceOfWEX > 0) {
            uint256[] memory _amounts = _swapExactTokensForTokens2(
                address(WEX),
                address(ETH),
                _balanceOfWEX
            );
            _yieldAmount = _amounts[2];
        }
    }

    /// @notice Converts NRV rewards to ETH
    function _liquidateNerveRewards() private returns (uint256 _yieldAmount) {
        uint256 _balanceOfNRV = NRV.balanceOf(address(this));
        _yieldAmount = 0;

        if (_balanceOfNRV > 0) {
            uint256[] memory _amounts = _swapExactTokensForTokens2(
                address(NRV),
                address(ETH),
                _balanceOfNRV
            );
            _yieldAmount = _amounts[2];
        }
    }

    /// @notice Function to swap tokens with PancakeSwap
    /// @param _tokenA Token to be swapped
    /// @param _tokenB Token to be received
    /// @param _amountIn Amount of token to be swapped
    /// @return _amounts Array that contains swapped amounts
    function _swapExactTokensForTokens(
        address _tokenA,
        address _tokenB,
        uint256 _amountIn
    ) private returns (uint256[] memory _amounts) {
        address[] memory _path = _getPath(_tokenA, _tokenB);
        uint256[] memory _amountsOut = PANCAKE_ROUTER.getAmountsOut(
            _amountIn,
            _path
        );
        if (_amountsOut[1] > 0) {
            _amounts = PANCAKE_ROUTER.swapExactTokensForTokens(
                _amountIn,
                0,
                _path,
                address(this),
                block.timestamp
            );
        } else {
            // Not enough amount to swap
            uint256[] memory _zeroReturn = new uint256[](2);
            _zeroReturn[0] = 0;
            _zeroReturn[1] = 0;
            return _zeroReturn;
        }
    }

    /// @notice Function to swap Exotic tokens with PancakeSwap
    /// @dev For tokens that cannot be swapped directly
    /// @param _tokenA Token to be swapped
    /// @param _tokenB Token to be received
    /// @param _amountIn Amount of token to be swapped
    /// @return _amounts Array that contains swapped amounts
    function _swapExactTokensForTokens2(
        address _tokenA,
        address _tokenB,
        uint256 _amountIn
    ) private returns (uint256[] memory _amounts) {
        address[] memory _path = _getPath2(_tokenA, _tokenB);
        uint256[] memory _amountsOut = PANCAKE_ROUTER.getAmountsOut(
            _amountIn,
            _path
        );
        if (_amountsOut[2] > 0) {
            _amounts = PANCAKE_ROUTER.swapExactTokensForTokens(
                _amountIn,
                0,
                _path,
                address(this),
                block.timestamp
            );
        } else {
            // Not enough amount to swap
            uint256[] memory _zeroReturn = new uint256[](2);
            _zeroReturn[0] = 0;
            _zeroReturn[2] = 0;
            return _zeroReturn;
        }
    }

    /// @notice Function to get path for PancakeSwap swap functions
    /// @param _tokenA Token to be swapped
    /// @param _tokenB Token to be received
    /// @return _path Array of address
    function _getPath(address _tokenA, address _tokenB)
        private
        pure
        returns (address[] memory)
    {
        address[] memory _path = new address[](2);
        _path[0] = _tokenA;
        _path[1] = _tokenB;
        return _path;
    }

    /// @notice Function to get path for PancakeSwap swap functions, for exotic tokens
    /// @param _tokenA Token to be swapped
    /// @param _tokenB Token to be received
    /// @return _path Array of address with WBNB in between
    function _getPath2(address _tokenA, address _tokenB)
        private
        view
        returns (address[] memory)
    {
        address[] memory _path = new address[](3);
        _path[0] = _tokenA;
        _path[1] = address(WBNB);
        _path[2] = _tokenB;
        return _path;
    }

    /// @notice Calculate price of 1 ETH-BETH LP in ETH
    function _calcPriceETH_BETH_LP()
        public
        view
        override
        returns (uint256 _valueInEth)
    {
        uint256 _totalSupply = ETH_BETH_LP.totalSupply();
        (uint256 _amountETH, uint256 _amountBETH, ) = ETH_BETH_LP.getReserves();

        address[] memory _path = _getPath(address(BETH), address(ETH));
        uint256[] memory _amountsOut = PANCAKE_ROUTER.getAmountsOut(ONE, _path);

        uint256 _priceBETH = _amountsOut[1];
        uint256 _valueBETH = _amountBETH.mul(_priceBETH).div(1e18);

        uint256 _totalAmount = _amountETH.add(_valueBETH);
        _valueInEth = _totalAmount.mul(1e18).div(_totalSupply);
    }

    /// @notice Calculate price of 1 ETH-anyETH LP in ETH
    function _calcPriceETH_ANYETH_LP()
        public
        view
        override
        returns (uint256 _valueInEth)
    {
        _valueInEth = NERVE_SWAP.getVirtualPrice(); // 1e18
    }

    /* ========== ADMIN FUNCTIONS ========== */

    /// @notice Function to set new admin address from vault contract
    /// @dev Only can set Once
    /// @param _address Address of Vault
    function setVault(address _address) external onlyOwner {
        require(
            address(vault) == address(0),
            "Strategy::setVault:Vault already set"
        );
        vault = IVault(_address);
        emit SetVault(_address);
    }

    /// @notice Function to set new admin address from vault contract
    /// @param _address Address of new admin
    function setAdmin(address _address) external override onlyVault {
        admin = _address;
        emit SetAdmin(_address);
    }

    /// @notice Function to set new strategist address from vault contract
    /// @param _address Address of new strategist
    function setStrategist(address _address) external override onlyVault {
        strategist = _address;
        emit SetStrategist(_address);
    }

    /// @notice Function to reimburse vault minimum keep amount by removing liquidity from all farms
    function reimburse() external override onlyVault {
        // Get total reimburse amount (6 decimals)
        uint256 _reimburseAmount = vault.getMinimumKeep();
        withdraw(_reimburseAmount);
    }

    /// @notice Function to reimburse vault minimum keep amount by removing liquidity from all farms
    function emergencyWithdraw() external override onlyVault whenNotPaused {
        (uint256 _amount_ETH_BETH_LP, , ) = WAULT_FARM.userInfo(
            WAULT_PID,
            address(this)
        );
        (uint256 _amount_ETH_ANYETH_LP, ) = NERVE_FARM.userInfo(
            NERVE_PID,
            address(this)
        );

        // Withdrawing automatically harvests yields
        _withdrawWault(_amount_ETH_BETH_LP);
        _withdrawNerve(_amount_ETH_ANYETH_LP);

        (
            uint256 _amountETHFromWault,
            uint256 _amountBETH
        ) = _removeLiquidityWault(_amount_ETH_BETH_LP);
        (
            uint256 _amountETHFromNerve,
            uint256 _amountANYETH
        ) = _removeLiquidityNerve(_amount_ETH_ANYETH_LP);

        uint256 _totalRewards = _liquidateRewards(); // in ETH
        uint256 _fees = _totalRewards.mul(yieldFeePerc).div(DENOMINATOR);
        _splitYieldFees(_fees);
        // Swap BETH and anyETH back to ETH
        uint256 _amountETHFromBETH = _swapBETHforETH(_amountBETH);
        uint256 _amountETHFromANYETH = _swapANYETHforETH(_amountANYETH);

        uint256 _amountETH = __calcETH(
            _amountETHFromWault,
            _amountETHFromNerve,
            _totalRewards,
            _fees,
            _amountETHFromBETH,
            _amountETHFromANYETH
        );

        // Send deserved ETH back to Vault
        ETH.safeTransfer(address(vault), _amountETH);
        _pause();
    }

    function __calcETH(
        uint256 a,
        uint256 b,
        uint256 c,
        uint256 d,
        uint256 e,
        uint256 f
    ) private pure returns (uint256 _amountETH) {
        _amountETH = a.add(b).add(c).sub(d).add(e);
        _amountETH = _amountETH.add(f);
    }

    /// @notice Function to invest back WETH into farms after emergencyWithdraw()
    function reinvest() external override onlyVault whenPaused {
        _unpause();
    }
}
