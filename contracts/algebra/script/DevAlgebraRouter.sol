// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IAlgebraPool} from "@cryptoalgebra/integral-core/contracts/interfaces/IAlgebraPool.sol";

/// LOCAL DEV ONLY. Pays Algebra mint/swap callbacks from `payer` without checking that the caller is a
/// real pool, so any contract could pull approved tokens. Never deploy this to a real chain.
contract DevAlgebraRouter {
    uint160 internal constant MIN_SQRT_RATIO = 4295128739;
    uint160 internal constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;

    function mint(IAlgebraPool pool, int24 bottomTick, int24 topTick, uint128 liquidity) external {
        pool.mint(msg.sender, msg.sender, bottomTick, topTick, liquidity, abi.encode(msg.sender));
    }

    /// Exact-input swap.
    function swap(IAlgebraPool pool, bool zeroToOne, uint256 amountIn) external returns (int256, int256) {
        uint160 limit = zeroToOne ? MIN_SQRT_RATIO + 1 : MAX_SQRT_RATIO - 1;
        return pool.swap(msg.sender, zeroToOne, int256(amountIn), limit, abi.encode(msg.sender));
    }

    function algebraMintCallback(uint256 amount0, uint256 amount1, bytes calldata data) external {
        _pay(abi.decode(data, (address)), amount0, amount1);
    }

    function algebraSwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
        _pay(
            abi.decode(data, (address)),
            amount0Delta > 0 ? uint256(amount0Delta) : 0,
            amount1Delta > 0 ? uint256(amount1Delta) : 0
        );
    }

    function _pay(address payer, uint256 amount0, uint256 amount1) internal {
        IAlgebraPool pool = IAlgebraPool(msg.sender);
        if (amount0 > 0) IERC20(pool.token0()).transferFrom(payer, msg.sender, amount0);
        if (amount1 > 0) IERC20(pool.token1()).transferFrom(payer, msg.sender, amount1);
    }
}

contract DevToken is ERC20 {
    constructor(string memory s) ERC20(s, s) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
