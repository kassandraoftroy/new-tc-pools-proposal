# Add ETH Pools — Tornado Cash Governance Proposal

Foundry repo that implements the on-chain execution for [adding 0.01, 0.03, 0.3, 3, and 30 ETH anonymity pools](https://gist.github.com/kassandraoftroy/d326c11ee6668a906d4251556d5e28b8).

## What it does

`AddEthPoolsProposal.executeProposal()` (delegatecalled by Tornado Governance):

1. Deploys five `ETHTornado` instances (merkle height 20) using the shared verifier and MiMC hasher
2. Registers each as `ENABLED` in the [InstanceRegistry](https://etherscan.io/address/0xB20c66C4DE72433F3cE747b58B86830c459CA911) so the [Tornado Router](https://etherscan.io/address/0xd90e2f925DA726b50C4Ed8D0Fb90Ad053324F31b) can route deposits/withdrawals

Denominations: `0.01 — 0.03 — 0.1 — 0.3 — 1 — 3 — 10 — 30 — 100` ETH (new sizes in bold conceptually: 0.01, 0.03, 0.3, 3, 30).

Protocol fee / anonymity mining are left unchanged (`protocolFeePercentage = 0`).

## Addresses

| Role | Address |
| --- | --- |
| Governance | `0x5efda50f22d34F262c29268506C5Fa42cB56A1Ce` |
| InstanceRegistry | `0xB20c66C4DE72433F3cE747b58B86830c459CA911` |
| TornadoRouter | `0xd90e2f925DA726b50C4Ed8D0Fb90Ad053324F31b` |
| Verifier | `0xce172ce1F20EC0B3728c9965470eaf994A03557A` |
| Hasher | `0x83584f83f26aF4eDDA9CBe8C730bc87C364b28fe` |

## Develop

```bash
forge install
forge build
ETH_RPC_URL=https://ethereum-rpc.publicnode.com forge test -vvv
```

The fork test spoofs a quorum-sized TORN holder (`deal`), runs the live governance cycle (`propose` → warp voting delay → `castVote` → warp voting period + execution delay → `execute`), asserts all five pools are `ENABLED` in the registry, then deposits into each new instance via the Tornado Router.

## Governance submission

1. Deploy `AddEthPoolsProposal` (no constructor args)
2. Verify source on Etherscan
3. Call `Governance.propose(proposalAddress, "Add 0.01, 0.03, 0.3, 3, and 30 ETH Tornado Cash anonymity pools")` with ≥ proposal threshold locked TORN
4. After voting + timelock, anyone can `execute(proposalId)`

## Layout

```
src/AddEthPoolsProposal.sol   # proposal (solc 0.7.6)
src/vendor/                   # audited ETHTornado stack
src/interfaces/               # InstanceRegistry ABI
test/AddEthPoolsProposal.t.sol
```
