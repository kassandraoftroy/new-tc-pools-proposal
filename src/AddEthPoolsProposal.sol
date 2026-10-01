// SPDX-License-Identifier: MIT
pragma solidity ^0.5.8;
pragma experimental ABIEncoderV2;

import "./classic/TornadoCash_eth.sol";
import "./interfaces/IInstanceRegistry.sol";

/**
 * @notice Tornado Cash governance proposal: deploy 0.01, 0.03, 0.3, 3, and 30 ETH
 *         anonymity pools and register them with the InstanceRegistry (Router reads it).
 * @dev Governance.execute() delegatecalls `executeProposal()`. No proposal storage —
 *      constants only. Deploys classic TornadoCash_eth (solc 0.5.11 template) with
 *      Hasher linked to the shared MiMC library. Operator is address(0).
 */
contract AddEthPoolsProposal {
    address public constant INSTANCE_REGISTRY = 0xB20c66C4DE72433F3cE747b58B86830c459CA911;
    address public constant VERIFIER = 0xce172ce1F20EC0B3728c9965470eaf994A03557A;
    uint32 public constant MERKLE_TREE_HEIGHT = 20;

    event PoolAdded(address indexed instance, uint256 denomination);

    function executeProposal() external {
        _add(0.01 ether);
        _add(0.03 ether);
        _add(0.3 ether);
        _add(3 ether);
        _add(30 ether);
    }

    function _add(uint256 denomination) internal {
        address instance =
            address(new TornadoCash_eth(IVerifier(VERIFIER), denomination, MERKLE_TREE_HEIGHT, address(0)));

        IInstanceRegistry.Instance memory cfg = IInstanceRegistry.Instance({
            isERC20: false,
            token: IERC20Minimal(address(0)),
            state: IInstanceRegistry.InstanceState.ENABLED,
            uniswapPoolSwappingFee: 0,
            protocolFeePercentage: 0
        });

        IInstanceRegistry(INSTANCE_REGISTRY)
            .updateInstance(IInstanceRegistry.Tornado({addr: ITornadoInstance(instance), instance: cfg}));

        assert(ITornadoInstance(instance).denomination() == denomination);

        (,, IInstanceRegistry.InstanceState state,,) =
            IInstanceRegistry(INSTANCE_REGISTRY).instances(ITornadoInstance(instance));
        assert(state == IInstanceRegistry.InstanceState.ENABLED);

        emit PoolAdded(instance, denomination);
    }
}
