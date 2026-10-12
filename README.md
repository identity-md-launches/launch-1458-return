# Return (RETURN)

A fixed-supply ERC-20 token. The constructor mints **1,000,000,000 RETURN with 18 decimals**, all to its caller, in one mint. The implementation is [src/ReturnToken.sol](src/ReturnToken.sol).

## Behavior and assumptions

- Name `Return`, symbol `RETURN`, decimals `18`.
- Total supply is permanently `1000000000000000000000000000` smallest units (`10^27`). No rounding is involved.
- Standard ERC-20 transfers, balances, approvals, and delegated transfers use the vendored OpenZeppelin ERC20 implementation. Successful operations return `true`; invalid operations revert with ERC-6093 custom errors.
- There are no fees, rebases, transfer restrictions by role, minting after construction, exposed burns, owner, pause, blacklist, confiscation, proxy, upgrade, permit, or rescue functions.
- Transfers deliver exactly the requested amount. Zero-value and self-transfers are valid; transfers to the zero address are rejected, including zero-value transfers.
- `approve` replaces the caller's allowance for a spender. `transferFrom` spends finite allowances; `type(uint256).max` is an unlimited allowance and remains unchanged until replaced or revoked. A failure rolls back both balances and allowance.
- The constructor emits one `Transfer` event from the zero address. Transfers emit `Transfer`; explicit approvals emit `Approval`. This library version does not emit an additional `Approval` event when `transferFrom` spends allowance; integrations should read `allowance`.
- The token makes no external calls and accepts no ordinary native ETH payments. ERC-20 transfers do not invoke recipient callbacks. Assets mistakenly transferred to the token contract, or native ETH forcibly sent to it, cannot be recovered.

## Build and test

Run from the repository root with Foundry and Solidity 0.8.26 installed:

```sh
forge build
forge test
forge fmt --check
```

`foundry.toml` pins Solidity `0.8.26`, Cancun EVM, optimizer enabled with 200 runs, and `bytecode_hash = "none"`. FFI and filesystem cheatcode permissions are disabled. Both dependencies are ordinary source files in `lib/`, with licenses and provenance in [DEPENDENCIES.md](DEPENDENCIES.md); no network installation, submodule, or package manager is required. The compiler is supplied by the verification environment, not included in this repository.

For an explicitly offline run with a compiler already installed:

```sh
forge build --offline
forge test --offline
shasum -a 256 -c DEPENDENCIES.sha256
```

The tests do not read or set environment variables, use a fork, access files, or require an RPC URL. Every test deploys independent local state.

## Deployment parameters

| Parameter | Value |
| --- | --- |
| Source and contract | `src/ReturnToken.sol:ReturnToken` |
| Solidity identifier | `ReturnToken` |
| Constructor arguments | None (`[]`) |
| Constructor ETH value | `0` |
| Initial recipient | Immediate constructor caller (`msg.sender`) |
| Supply in smallest units | `1000000000000000000000000000` |
| Application contracts | None |
| External addresses or configuration | None |
| Initialization calls | None |
| Linked libraries | None |

The assignment targets Ethereum mainnet, chain ID 1. Deploy the built creation bytecode directly through the launch factory. The factory receives the entire supply; neither the transaction origin nor the requester receives an automatic constructor allocation. A direct EOA deployment instead gives every token to that EOA. Do not deploy through a helper that cannot subsequently transfer its received tokens.

The ABI and creation bytecode can be inspected locally without broadcasting:

```sh
forge inspect src/ReturnToken.sol:ReturnToken abi
forge inspect src/ReturnToken.sol:ReturnToken bytecode
```

The network's separate manifest step supplies `launch.json` after acceptance. No deployment script, key, RPC endpoint, or manifest is needed for this token implementation. The launch factory, distributor, pool creation, and launch economics are external responsibilities and are not implemented by this token.

## After launch

There are no settings, owner actions, keepers, or ongoing maintenance calls. The launch operator must verify the deployed code and metadata, the constructor mint to the factory, and the subsequent distributions. For this assignment the factory distributes 10% to the swarm distributor, allocates 80% to the pool, and forwards the remaining 10% to the requester-specified remainder recipient. The factory and manifest are responsible for those allocations and the supplied pool parameters; this contract does not hardcode any recipient or pool address.

Holders are responsible for securing their accounts, choosing recipients, and approving only trusted spenders. Use appropriately bounded allowances; to replace an outstanding allowance safely, revoke it to zero and confirm that transaction before granting the replacement. No administrator can undo a transfer, freeze an account, recover lost tokens, or grant an allowance for another holder.

## Validation and security review

- `test/ReturnToken.t.sol` checks metadata, exact mint and transfer events, balances, full-supply and self-transfers, zero values, approvals, allowance isolation, revocation, unlimited allowance behavior, failure rollback, and rejection of invalid inputs. Four fuzz tests check successful and failing transfer accounting across varied amounts.
- `test/ReturnTokenLaunch.t.sol` checks CREATE2 deployment to a factory, exact distribution and claim amounts, token transfers into and out of a pool holder, rejection of mint/admin/burn selectors from both the factory and a stranger, and runtime size and forbidden opcodes.
- `test/ReturnTokenInvariant.t.sol` executes randomized sequences of transfers, approvals, and delegated transfers over four accounts, checking conservation of balances, permanent supply, zero-address balance, and unchanged metadata. Defaults are 128 sequences of 64 calls; fuzz tests use 512 cases each.

The local launch tests validate token-side behavior. They do not stand in for the supplied protected harness's real Uniswap v4 initialization, liquidity seeding, and swaps. That independent harness uses the later manifest and the network's launch contracts and environment; it is not included in this standalone project.

Review against the supplied security reference found no external interactions, oracle, randomness, signature, privileged role, upgrade, or user-controlled delegatecall surface in this token. The only mint is the constructor call; all later balance changes use standard ERC-20 transfers. Validation uses the pinned compiler, Foundry unit/fuzz/invariant tests, and dependency checksums. Slither and Mythril were not run. This local review is not an independent security audit; independent review and explorer verification remain the launch operator's release responsibilities. No transactions were broadcast.
