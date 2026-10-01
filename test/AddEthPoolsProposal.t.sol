// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
}

interface IGovernance {
    function EXECUTION_DELAY() external view returns (uint256);
    function QUORUM_VOTES() external view returns (uint256);
    function VOTING_DELAY() external view returns (uint256);
    function VOTING_PERIOD() external view returns (uint256);
    function lockWithApproval(uint256 amount) external;
    function lockedBalance(address account) external view returns (uint256);
    function propose(address target, string memory description) external returns (uint256);
    function castVote(uint256 proposalId, bool support) external;
    function execute(uint256 proposalId) external;
    function state(uint256 proposalId) external view returns (uint8);
}

interface ITornadoInstance {
    function denomination() external view returns (uint256);
    function commitments(bytes32) external view returns (bool);
}

interface IInstanceRegistry {
    enum InstanceState {
        DISABLED,
        ENABLED
    }

    function instances(address)
        external
        view
        returns (
            bool isERC20,
            address token,
            InstanceState state,
            uint24 uniswapPoolSwappingFee,
            uint32 protocolFeePercentage
        );

    function getAllInstanceAddresses() external view returns (address[] memory);
}

interface ITornadoRouter {
    function deposit(address _tornado, bytes32 _commitment, bytes calldata _encryptedNote) external payable;
}

/**
 * @dev Mainnet-fork E2E: spoof a large TORN holder, run propose → vote → execute
 *      with time warps matching live governance delays, then deposit via TornadoRouter
 *      into each newly registered ETH pool.
 */
contract AddEthPoolsProposalTest is Test {
    address private constant _TORN = 0x77777FeDdddFfC19Ff86DB637967013e6C6A116C;
    address private constant _GOVERNANCE = 0x5efda50f22d34F262c29268506C5Fa42cB56A1Ce;
    address private constant _INSTANCE_REGISTRY = 0xB20c66C4DE72433F3cE747b58B86830c459CA911;
    address private constant _ROUTER = 0xd90e2f925DA726b50C4Ed8D0Fb90Ad053324F31b;

    // Governance ProposalState enum (live contract).
    uint8 private constant _STATE_AWAITING_EXECUTION = 4;
    uint8 private constant _STATE_EXECUTED = 5;

    uint256 private constant _DENOM_001 = 0.01 ether;
    uint256 private constant _DENOM_003 = 0.03 ether;
    uint256 private constant _DENOM_03 = 0.3 ether;
    uint256 private constant _DENOM_3 = 3 ether;
    uint256 private constant _DENOM_30 = 30 ether;

    IGovernance private constant _gov = IGovernance(_GOVERNANCE);
    IInstanceRegistry private constant _registry = IInstanceRegistry(_INSTANCE_REGISTRY);
    ITornadoRouter private constant _router = ITornadoRouter(_ROUTER);
    IERC20 private constant _torn = IERC20(_TORN);

    uint256 private _forkId;
    address private _proposal;

    function setUp() external {
        string memory rpc = vm.envOr("ETH_RPC_URL", string("https://ethereum-rpc.publicnode.com"));
        _forkId = vm.createSelectFork(rpc);
        _proposal = deployCode("AddEthPoolsProposal.sol:AddEthPoolsProposal");
    }

    function testGovernanceVoteExecuteAndRouterDeposits() external {
        assertEq(vm.activeFork(), _forkId);
        assertTrue(_proposal.code.length > 0, "proposal not deployed");

        uint256 addressesBefore = _registry.getAllInstanceAddresses().length;

        // --- Spoof a large TORN holder with enough locked power for quorum ---
        address voter = makeAddr("voter");
        uint256 lockAmount = _gov.QUORUM_VOTES();
        deal(_TORN, voter, lockAmount);
        assertEq(_torn.balanceOf(voter), lockAmount);

        vm.startPrank(voter);
        assertTrue(_torn.approve(_GOVERNANCE, lockAmount));
        _gov.lockWithApproval(lockAmount);
        assertEq(_gov.lockedBalance(voter), lockAmount);

        // --- Propose ---
        uint256 proposalId = _gov.propose(
            _proposal, "Add 0.01, 0.03, 0.3, 3, and 30 ETH Tornado Cash anonymity pools"
        );

        // --- Fast-forward past voting delay, cast FOR vote ---
        vm.warp(block.timestamp + _gov.VOTING_DELAY() + 1);
        _gov.castVote(proposalId, true);

        // --- Fast-forward past voting period + execution timelock ---
        vm.warp(block.timestamp + _gov.VOTING_PERIOD() + _gov.EXECUTION_DELAY() + 1);
        assertEq(_gov.state(proposalId), _STATE_AWAITING_EXECUTION);

        _gov.execute(proposalId);
        assertEq(_gov.state(proposalId), _STATE_EXECUTED);
        vm.stopPrank();

        // --- Five new pools registered ---
        address[] memory all = _registry.getAllInstanceAddresses();
        assertEq(all.length, addressesBefore + 5);

        address pool001 = _findNewPool(all, addressesBefore, _DENOM_001);
        address pool003 = _findNewPool(all, addressesBefore, _DENOM_003);
        address pool03 = _findNewPool(all, addressesBefore, _DENOM_03);
        address pool3 = _findNewPool(all, addressesBefore, _DENOM_3);
        address pool30 = _findNewPool(all, addressesBefore, _DENOM_30);

        _assertEthPool(pool001, _DENOM_001);
        _assertEthPool(pool003, _DENOM_003);
        _assertEthPool(pool03, _DENOM_03);
        _assertEthPool(pool3, _DENOM_3);
        _assertEthPool(pool30, _DENOM_30);

        // --- Router deposits into every new instance ---
        address depositor = makeAddr("depositor");
        _depositViaRouter(depositor, pool001, _DENOM_001, "c-0.01");
        _depositViaRouter(depositor, pool003, _DENOM_003, "c-0.03");
        _depositViaRouter(depositor, pool03, _DENOM_03, "c-0.3");
        _depositViaRouter(depositor, pool3, _DENOM_3, "c-3");
        _depositViaRouter(depositor, pool30, _DENOM_30, "c-30");
    }

    // BN254 scalar field — Tornado commitments must be field elements.
    uint256 private constant _FIELD_SIZE =
        21888242871839275222246405745257275088548364400416034343698204186575808495617;

    function _depositViaRouter(address depositor, address pool, uint256 denomination, string memory tag)
        internal
    {
        bytes32 commitment = bytes32(uint256(keccak256(bytes(tag))) % _FIELD_SIZE);
        deal(depositor, denomination);

        uint256 balBefore = pool.balance;
        vm.prank(depositor);
        _router.deposit{value: denomination}(pool, commitment, "");

        assertEq(pool.balance, balBefore + denomination, "pool balance");
        assertTrue(ITornadoInstance(pool).commitments(commitment), "commitment missing");
    }

    function _assertEthPool(address pool, uint256 denomination) internal view {
        assertEq(ITornadoInstance(pool).denomination(), denomination);
        (
            bool isERC20,
            address token,
            IInstanceRegistry.InstanceState state,
            uint24 uniswapFee,
            uint32 protocolFee
        ) = _registry.instances(pool);
        assertFalse(isERC20);
        assertEq(token, address(0));
        assertTrue(state == IInstanceRegistry.InstanceState.ENABLED);
        assertEq(uniswapFee, uint24(0));
        assertEq(protocolFee, uint32(0));
    }

    function _findNewPool(address[] memory all, uint256 startIndex, uint256 denomination)
        internal
        view
        returns (address)
    {
        for (uint256 i = startIndex; i < all.length; i++) {
            if (ITornadoInstance(all[i]).denomination() == denomination) {
                return all[i];
            }
        }
        revert("pool not found");
    }
}
