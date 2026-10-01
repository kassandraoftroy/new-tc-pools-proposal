// SPDX-License-Identifier: MIT
pragma solidity ^0.5.8;
pragma experimental ABIEncoderV2;

interface IERC20Minimal {
    function balanceOf(address account) external view returns (uint256);
}

interface ITornadoInstance {
    function denomination() external view returns (uint256);

    function deposit(bytes32 commitment) external payable;
}

interface IInstanceRegistry {
    enum InstanceState {
        DISABLED,
        ENABLED
    }

    struct Instance {
        bool isERC20;
        IERC20Minimal token;
        InstanceState state;
        uint24 uniswapPoolSwappingFee;
        uint32 protocolFeePercentage;
    }

    struct Tornado {
        ITornadoInstance addr;
        Instance instance;
    }

    function updateInstance(Tornado calldata _tornado) external;

    function instances(ITornadoInstance)
        external
        view
        returns (
            bool isERC20,
            IERC20Minimal token,
            InstanceState state,
            uint24 uniswapPoolSwappingFee,
            uint32 protocolFeePercentage
        );

    function getAllInstanceAddresses() external view returns (ITornadoInstance[] memory);
}
