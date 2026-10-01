# Add ETH Pools — Tornado Cash Governance Proposal

Foundry repo that implements the on-chain execution for [adding 0.01, 0.03, 0.3, 3, and 30 ETH anonymity pools](https://gist.github.com/kassandraoftroy/d326c11ee6668a906d4251556d5e28b8).

## What it does

`AddEthPoolsProposal.executeProposal()` (delegatecalled by Tornado Governance):

1. Deploys five classic `TornadoCash_eth` instances (merkle height 20, `operator = address(0)`) using the shared verifier, with the MiMC `Hasher` library linked to the same address as live 1/10/100 ETH pools
2. Registers each as `ENABLED` in the [InstanceRegistry](https://etherscan.io/address/0xB20c66C4DE72433F3cE747b58B86830c459CA911) so the [Tornado Router](https://etherscan.io/address/0xd90e2f925DA726b50C4Ed8D0Fb90Ad053324F31b) can route deposits/withdrawals

Denominations: `0.01 — 0.03 — 0.1 — 0.3 — 1 — 3 — 10 — 30 — 100` ETH (new sizes: 0.01, 0.03, 0.3, 3, 30).

Protocol fee / anonymity mining are left unchanged (`protocolFeePercentage = 0`).

## Compiler (bytecode match)

Pools are compiled like mainnet [1 ETH](https://etherscan.io/address/0x47CE0C6eD5B0Ce3d3A51fdb1C52DC66a7c3c2936) / 10 / 100:

| Setting | Value |
| --- | --- |
| Contract | `TornadoCash_eth` |
| solc | `0.5.11` (optimizer **200** runs, **petersburg**) |
| Hasher library | `0x83584f83f26aF4eDDA9CBe8C730bc87C364b28fe` |

The fork test asserts each new pool’s **metadata-stripped** runtime bytecode equals the live 1 ETH pool (opcode-identical). Full `extcodehash` still differs by the solc CBOR trailer: mainnet was verified with emscripten `0.5.11+commit.c082d0b4`, while Foundry uses the native binary `0.5.11+commit.22be8592`. That gate is **test-only** (not in `executeProposal()`). The 0.1 ETH pool is a close sibling (`TornadoCash_Eth_01`) with a different codehash.

## Addresses

| Role | Address |
| --- | --- |
| Governance | `0x5efda50f22d34F262c29268506C5Fa42cB56A1Ce` |
| InstanceRegistry | `0xB20c66C4DE72433F3cE747b58B86830c459CA911` |
| TornadoRouter | `0xd90e2f925DA726b50C4Ed8D0Fb90Ad053324F31b` |
| Verifier | `0xce172ce1F20EC0B3728c9965470eaf994A03557A` |
| Hasher | `0x83584f83f26aF4eDDA9CBe8C730bc87C364b28fe` |
| Live 1 ETH (codehash ref) | `0x47CE0C6eD5B0Ce3d3A51fdb1C52DC66a7c3c2936` |

## Develop

```bash
forge install
forge build
ETH_RPC_URL=https://ethereum-rpc.publicnode.com forge test -vvv
```

The fork test spoofs a quorum-sized TORN holder (`deal`), runs the live governance cycle (`propose` → warp voting delay → `castVote` → warp voting period + execution delay → `execute`), asserts all five pools are `ENABLED` and opcode-match live 1 ETH, then deposits into each via the Tornado Router.

## Governance submission

1. Deploy `AddEthPoolsProposal` (no constructor args)
2. Verify source on Etherscan
3. Call `Governance.propose(proposalAddress, "Add 0.01, 0.03, 0.3, 3, and 30 ETH Tornado Cash anonymity pools")` with ≥ proposal threshold locked TORN
4. After voting + timelock, anyone can `execute(proposalId)`

## Layout

```
src/AddEthPoolsProposal.sol   # proposal (solc 0.5.11)
src/classic/TornadoCash_eth.sol  # verified classic mixer template
src/interfaces/               # InstanceRegistry ABI
test/AddEthPoolsProposal.t.sol
```
