# Vendored dependencies

All required Solidity dependencies are included as ordinary files. No Git submodules, install hooks, generated stubs, or external filesystem imports are used. The original licenses are retained next to each dependency. `DEPENDENCIES.sha256` records the SHA-256 of every vendored file; the source files are unmodified.

## OpenZeppelin Contracts v5.0.2

- Source: [OpenZeppelin/openzeppelin-contracts, tag v5.0.2](https://github.com/OpenZeppelin/openzeppelin-contracts/tree/v5.0.2).
- Archive: `https://codeload.github.com/OpenZeppelin/openzeppelin-contracts/tar.gz/refs/tags/v5.0.2`.
- Archive SHA-256: `18c7b7e949b9a82dcd8cd394426c9c2636dfc263aa2317d4749dbfa0c7b3925a`.
- License: [MIT](lib/openzeppelin-contracts/LICENSE).
- Included subset: `ERC20.sol`, `IERC20.sol`, `IERC20Metadata.sol`, `Context.sol`, `draft-IERC6093.sol`, and the license. This is the complete transitive import closure used by the token.
- Remapping: `@openzeppelin/contracts/` to `lib/openzeppelin-contracts/contracts/`.

## Forge Standard Library v1.9.7

- Source: [foundry-rs/forge-std, tag v1.9.7](https://github.com/foundry-rs/forge-std/tree/v1.9.7).
- Archive: `https://codeload.github.com/foundry-rs/forge-std/tar.gz/refs/tags/v1.9.7`.
- Archive SHA-256: `45157353ab49eab01d294565866731e599b32401757229689ee459aa26b7ee94`.
- Licenses: [MIT](lib/forge-std/LICENSE-MIT) and [Apache-2.0](lib/forge-std/LICENSE-APACHE).
- Included subset: all Solidity files under upstream `src/` and both licenses. Used only by tests.
- Remapping: `forge-std/` to `lib/forge-std/src/`.

Only source files and licenses were extracted from release archives; upstream repositories, configuration, workflows, examples, and tests are not part of this project. Formatting excludes vendored sources to preserve their original bytes.
