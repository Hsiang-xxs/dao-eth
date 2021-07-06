// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

interface IVault {
    /* ============= Main Function ============= */
    function deposit(uint256 _amount) external;

    function withdraw(uint256 _amount) external;

    function invest() external;

    /* ========== Strategy Information ========== */
    function getTotalPool() external view returns (uint256);

    function getVaultPool() external view returns (uint256);

    function getMinimumKeep() external view returns (uint256);

    /* ========== Fees ========== */
    function setFeesDenominator() external;

    function getFeesDenominator() external view returns (uint256);

    function getTotalYield() external view returns (uint256);

    /* ================= Admin ================= */
    function reimburse() external;

    function setAdmin(address _admin) external;

    function setStrategist(address _strategist) external;

    function emergencyWithdraw() external;

    function reinvest() external;

    /* ================= Events ================= */
    event Deposited(address indexed user, uint256 amount);
    event Withdrawn(
        address indexed user,
        uint256 amount,
        uint256 withdrawalFee
    );
    event Harvested(uint256 profit);
}
