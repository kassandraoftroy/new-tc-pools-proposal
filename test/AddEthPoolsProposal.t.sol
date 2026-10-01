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
    function verifier() external view returns (address);
    function levels() external view returns (uint32);
    function operator() external view returns (address);
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
 *
 * @dev Bytecode gate (test-only): `extcodehash` = keccak256(runtime). Runtime =
 *      [EVM body || solc CBOR metadata || uint16 metaLen]. We strip the metadata
 *      trailer and require the EVM body to equal the live 1 ETH pool byte-for-byte.
 *      Full extcodehash still differs (native solc 22be8592 vs emscripten c082d0b4).
 */
contract AddEthPoolsProposalTest is Test {
    address private constant _TORN = 0x77777FeDdddFfC19Ff86DB637967013e6C6A116C;
    address private constant _GOVERNANCE = 0x5efda50f22d34F262c29268506C5Fa42cB56A1Ce;
    address private constant _INSTANCE_REGISTRY = 0xB20c66C4DE72433F3cE747b58B86830c459CA911;
    address private constant _ROUTER = 0xd90e2f925DA726b50C4Ed8D0Fb90Ad053324F31b;
    address private constant _VERIFIER = 0xce172ce1F20EC0B3728c9965470eaf994A03557A;
    // Live 1 ETH pool — shared TornadoCash_eth runtime with 10/100 ETH.
    address private constant _LIVE_1_ETH = 0x47CE0C6eD5B0Ce3d3A51fdb1C52DC66a7c3c2936;

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
    /// @dev Metadata-stripped runtime of live 1 ETH (the EVM body inside extcodehash).
    bytes private _live1EthEvmBody;

    function setUp() external {
        string memory rpc = vm.envOr("ETH_RPC_URL", string("https://ethereum-rpc.publicnode.com"));
        _forkId = vm.createSelectFork(rpc);
        assertTrue(_LIVE_1_ETH.code.length > 0, "live 1 ETH code empty");
        _live1EthEvmBody = _evmBodyOfExtcode(_LIVE_1_ETH);
        assertTrue(_live1EthEvmBody.length > 0, "live 1 ETH EVM body empty");
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
        uint256 proposalId = _gov.propose(_proposal, "Add 0.01, 0.03, 0.3, 3, and 30 ETH Tornado Cash anonymity pools");

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

        // Bytecode match vs live 1 ETH (see assertEq in _assertExtcodeEvmBodyMatchesLive1Eth).
        // We strip the solc CBOR metadata trailer first: full extcodehash differs slightly
        // because Foundry's native 0.5.11 metadata != historical emscripten c082d0b4 metadata,
        // while the EVM body is identical.
        _assertExtcodeEvmBodyMatchesLive1Eth(pool001);
        _assertExtcodeEvmBodyMatchesLive1Eth(pool003);
        _assertExtcodeEvmBodyMatchesLive1Eth(pool03);
        _assertExtcodeEvmBodyMatchesLive1Eth(pool3);
        _assertExtcodeEvmBodyMatchesLive1Eth(pool30);

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

    function _depositViaRouter(address depositor, address pool, uint256 denomination, string memory tag) internal {
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
        assertEq(ITornadoInstance(pool).verifier(), _VERIFIER, "verifier");
        assertEq(ITornadoInstance(pool).levels(), uint32(20), "levels");
        assertEq(ITornadoInstance(pool).operator(), address(0), "operator");

        (bool isERC20, address token, IInstanceRegistry.InstanceState state, uint24 uniswapFee, uint32 protocolFee) =
            _registry.instances(pool);
        assertFalse(isERC20);
        assertEq(token, address(0));
        assertTrue(state == IInstanceRegistry.InstanceState.ENABLED);
        assertEq(uniswapFee, uint24(0));
        assertEq(protocolFee, uint32(0));
    }

    /**
     * @dev Assert the EVM body embedded in `extcodehash(pool)` matches live 1 ETH.
     *      `extcodehash` = keccak256(runtime); runtime = EVM body || CBOR metadata || len.
     *      We compare the stripped EVM body bytes (not full codehash).
     */
    function _assertExtcodeEvmBodyMatchesLive1Eth(address pool) internal view {
        bytes memory poolBody = _evmBodyOfExtcode(pool);
        // Stripping: compare EVM body only — full extcodehash differs by slight solc
        // metadata inconsistencies (CBOR trailer); the executable bytecode must match.
        assertEq(poolBody, _live1EthEvmBody, "extcode EVM body != live 1 ETH");
        // Sanity: full hashes differ only because of the metadata trailer we stripped.
        assertTrue(pool.codehash != _LIVE_1_ETH.codehash, "expected full extcodehash to differ (metadata)");
        assertEq(
            keccak256(abi.encodePacked(poolBody, _metadataTrailer(pool.code))),
            pool.codehash,
            "pool extcodehash != keccak(body||metadata)"
        );
    }

    /// @dev EVM body of `extcodehash` input: runtime with solc CBOR metadata trailer removed.
    function _evmBodyOfExtcode(address account) internal view returns (bytes memory) {
        return _stripMetadata(account.code);
    }

    /// @dev Drop solc CBOR metadata trailer (last 2 bytes = big-endian metadata length).
    function _stripMetadata(bytes memory code) internal pure returns (bytes memory) {
        (uint256 keep,) = _splitRuntime(code);
        bytes memory out = new bytes(keep);
        for (uint256 i = 0; i < keep; i++) {
            out[i] = code[i];
        }
        return out;
    }

    function _metadataTrailer(bytes memory code) internal pure returns (bytes memory) {
        (uint256 keep, uint256 metaLen) = _splitRuntime(code);
        bytes memory out = new bytes(metaLen + 2);
        for (uint256 i = 0; i < out.length; i++) {
            out[i] = code[keep + i];
        }
        return out;
    }

    function _splitRuntime(bytes memory code) internal pure returns (uint256 keep, uint256 metaLen) {
        require(code.length >= 2, "code too short");
        metaLen = (uint256(uint8(code[code.length - 2])) << 8) + uint256(uint8(code[code.length - 1]));
        require(code.length >= metaLen + 2, "metadata length");
        keep = code.length - metaLen - 2;
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
