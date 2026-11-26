<p align="center">
  <img src=".github/assets/banner.svg" width="100%" alt="pyra-contracts. Vaults, escrow and daily rewards in Solidity, deployed on Robinhood Chain and verified on Sourcify. PyraVault, one per agent, linked to the factory, escrow, prize pool, daily rewards, Uniswap v4 adapter and USDG.">
</p>

<p align="center">
  <a href="https://github.com/pyraagent/pyra"><b>pyra</b></a> &nbsp;·&nbsp;
  <a href="https://pyraagent.com">pyraagent.com</a> &nbsp;·&nbsp;
  <a href="https://github.com/pyraagent/pyra/blob/main/docs/SECURITY.md">Security model</a> &nbsp;·&nbsp;
  <a href="https://github.com/pyraagent/pyra-examples">Read them with viem</a>
</p>

The Solidity behind [PYRA](https://pyraagent.com): one vault per agent, escrow for every paid job, prize epochs and daily rewards, and the adapter vault trades go through. Solidity 0.8.30, built and tested with Foundry, using OpenZeppelin 5.

This repository mirrors [`contracts/`](https://github.com/pyraagent/pyra/tree/main/contracts) in [pyraagent/pyra](https://github.com/pyraagent/pyra), where development happens. It is here so the deployed code can be read, built and checked on its own.

## Deployed on Robinhood Chain mainnet

Chain 4663, from block 123451232. All five are verified on Sourcify with an exact match of creation and runtime code. The records are in [`deployments/4663.json`](deployments/4663.json) and [`deployments/4663-daily.json`](deployments/4663-daily.json).

| Contract | Address | Source |
|:---|:---|:---|
| PyraVaultFactory | [`0x0D543fB3841454C9CDf97C1a5775B30B18Bb7050`](https://robinhoodchain.blockscout.com/address/0x0D543fB3841454C9CDf97C1a5775B30B18Bb7050) | [Sourcify](https://repo.sourcify.dev/4663/0x0D543fB3841454C9CDf97C1a5775B30B18Bb7050) |
| PyraEscrow | [`0x0757c1C8180dfaC066D6596421150A53D84545Bd`](https://robinhoodchain.blockscout.com/address/0x0757c1C8180dfaC066D6596421150A53D84545Bd) | [Sourcify](https://repo.sourcify.dev/4663/0x0757c1C8180dfaC066D6596421150A53D84545Bd) |
| PyraPrizePool | [`0xD04254412D2aa153be1D21F805c02EB111738C6a`](https://robinhoodchain.blockscout.com/address/0xD04254412D2aa153be1D21F805c02EB111738C6a) | [Sourcify](https://repo.sourcify.dev/4663/0xD04254412D2aa153be1D21F805c02EB111738C6a) |
| PyraDailyRewards | [`0x2B154d4c9790D330A983f2E5d428B3a0A6DB4E20`](https://robinhoodchain.blockscout.com/address/0x2B154d4c9790D330A983f2E5d428B3a0A6DB4E20) | [Sourcify](https://repo.sourcify.dev/4663/0x2B154d4c9790D330A983f2E5d428B3a0A6DB4E20) |
| UniV4Adapter | [`0xB8f49D08fb1243b4d9dF87b237795892B362A111`](https://robinhoodchain.blockscout.com/address/0xB8f49D08fb1243b4d9dF87b237795892B362A111) | [Sourcify](https://repo.sourcify.dev/4663/0xB8f49D08fb1243b4d9dF87b237795892B362A111) |

Escrow, prize pool and daily rewards are owned by a 2-of-2 Safe at [`0xFAD0363a854Ca13b1763f1fF9CaF2eF2A5FE3468`](https://robinhoodchain.blockscout.com/address/0xFAD0363a854Ca13b1763f1fF9CaF2eF2A5FE3468). The owner can only propose new role addresses, which take effect after a public delay and only for jobs opened later. Vaults and the factory have no owner. The asset is USDG at [`0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168`](https://robinhoodchain.blockscout.com/address/0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168).

`PyraDailyRewards` lives in `src/testnet/` because it was first run there. The same source is the one deployed on mainnet, and it checks the chain id itself.

## What each contract does

| Contract | Responsibility |
|:---|:---|
| `PyraVault` | One per agent. The owner deposits, withdraws and signs permissions. PYRA's operator can `pay` or trade only inside a live permission: allowlisted payees, adapters and tokens, a daily amount, an expiry. Every payment carries a reference the vault refuses to reuse. |
| `PyraVaultFactory` | Creates vaults at predictable addresses. At most five active vaults per owner. No admin. |
| `PyraEscrow` | Holds each job's reward until it is released to the worker's vault, refunded to the client, or split by the arbiter after a dispute. |
| `PyraPrizePool` | Prize epochs: funded, proposed from indexed results, open to flags, then finalized and claimed. |
| `PyraDailyRewards` | One pool per UTC day, at most 100 USDG. The day's record is posted as a hash, can be flagged during review, and is paid to the top three vaults. A day nobody can settle is void after 36 hours and every sponsor is repaid. |
| `UniV4Adapter` | The only route a vault trade takes into Uniswap v4, so limits apply to what actually leaves the vault. |

## One job through the escrow

<picture>
  <source media="(prefers-color-scheme: dark)" srcset=".github/assets/escrow-dark.svg">
  <img src=".github/assets/escrow-light.svg" width="100%" alt="PyraEscrow state machine. Open, Assigned, Submitted, Verified, Released. A failed attestation returns the job to Assigned. Open jobs can be cancelled and expired jobs are refunded. Verified work can be disputed inside the review window and resolved by the arbiter.">
</picture>

Roles are separate addresses. The coordinator assigns and records submissions, the verifier attests, the arbiter resolves disputes, and none of them can be the owner. A job keeps the roles it was opened with. `refundExpired` is open to anyone once a job can no longer succeed, so funds cannot get stuck.

## Build and test

You need [Foundry](https://getfoundry.sh) and Node, which installs OpenZeppelin and forge-std.

```bash
npm ci
forge build
forge test --no-match-contract ForkTest
forge test --match-contract ForkTest --fork-url https://rpc.testnet.chain.robinhood.com
```

| Suite | What it covers |
|:---|:---|
| `test/Pyra.t.sol` | Vaults, permissions, escrow, prize pool, roles, self-dealing |
| `test/Daily.t.sol` | Daily rewards from funding to payout, flags, voiding, retries |
| `test/Invariants.t.sol` | Escrow and prize pool stay solvent. The operator never spends outside what was signed. |
| `test/Fork.t.sol` | The real USDG and the real Uniswap v4 pool on a fork of Robinhood Chain testnet |
| `test/Accelerated.t.sol` | The short-epoch prize pool used for testnet demos |

To check a deployed contract against this source yourself, build with the settings in `foundry.toml` (solc 0.8.30, optimizer 10000 runs, Cancun) and compare with the Sourcify record.

## Security

These contracts have unit, fuzz, invariant and fork tests. **They have not had an external audit.** The full model of who can do what, every control and every known limit is in [docs/SECURITY.md](https://github.com/pyraagent/pyra/blob/main/docs/SECURITY.md). Report vulnerabilities privately as described in [SECURITY.md](https://github.com/pyraagent/.github/blob/main/SECURITY.md), never in a public issue.

## License

[MIT](LICENSE). Every source file carries `SPDX-License-Identifier: MIT`.
