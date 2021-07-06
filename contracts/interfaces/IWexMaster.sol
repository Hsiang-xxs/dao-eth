// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

interface IWexMaster {
    function deposit(
        uint256 _pid,
        uint256 _amount,
        bool _withdrawRewards
    ) external;

    function withdraw(
        uint256 _pid,
        uint256 _amount,
        bool _withdrawRewards
    ) external;

    function pendingWex(uint256 _pid, address _user) external returns (uint256);

    function claim(uint256 _pid) external;

    function userInfo(uint256, address)
        external
        returns (
            uint256 amount,
            uint256 rewardDebt,
            uint256 pendingRewards
        );
}
