// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

interface IStrategy {
    /* ============= Main Function ============= */
    function invest(uint256 _amount) external;

    function withdraw(uint256 _amount) external;

    function compound() external;

    /* ========== Strategy Information ========== */
    function getStrategyPool() external view returns (uint256);

    /* ================= Admin ================= */
    function reimburse() external;

    function setAdmin(address _admin) external;

    function setStrategist(address _strategist) external;

    function emergencyWithdraw() external;

    function reinvest() external;

    function _calcPriceETH_BETH_LP()
        external
        view
        returns (uint256 _valueInEth);

    function _calcPriceETH_ANYETH_LP()
        external
        view
        returns (uint256 _valueInEth);

    /* ================= Events ================= */
    event Invested(uint256 amount);
    event Withdrawn(uint256 amount, uint256 withdrawalFee);
    event Harvested(uint256 claimedWEX, uint256 claimedNRV);
}
