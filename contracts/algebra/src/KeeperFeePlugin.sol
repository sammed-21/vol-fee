// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IAlgebraPlugin} from "@cryptoalgebra/integral-core/contracts/interfaces/plugin/IAlgebraPlugin.sol";
import {IAlgebraPool} from "@cryptoalgebra/integral-core/contracts/interfaces/IAlgebraPool.sol";
import {Plugins} from "@cryptoalgebra/integral-core/contracts/libraries/Plugins.sol";

interface IKeeperFeeConfig {
    function keeper() external view returns (address);
    function initialFee() external view returns (uint24);
    function bounds() external view returns (uint24 minFee, uint24 maxFee);
}

/// @title KeeperFeePlugin
/// @notice Algebra Integral v1.2.2 plugin: a keeper writes the fee, `beforeSwap` only reads it and
///         returns it as `feeOverride`. Same rules as the Uniswap v4 VolFeeHook in this repo.
/// @dev A fee written in block N takes effect in block N+1, so every swap in block N pays `feeFor()`
///      as read at block N (quote = fill). One plugin per pool; keeper and bounds live in the factory.
///      Implements the GPL IAlgebraPlugin interface directly (no BUSL base-plugin code).
contract KeeperFeePlugin is IAlgebraPlugin {
    /// @dev Packed into one slot.
    struct FeeState {
        uint24 fee; // fee live until `nextFeeBlock`
        uint24 nextFee; // fee live from `nextFeeBlock` onward
        uint64 nextFeeBlock;
        uint64 updatedAt; // timestamp of last keeper write (for off-chain staleness monitoring)
    }

    error NotPool();
    error NotKeeper();
    error FeeOutOfBounds(uint24 fee, uint24 minFee, uint24 maxFee);

    event FeeScheduled(uint24 fee, uint64 effectiveBlock);

    /// @inheritdoc IAlgebraPlugin
    uint8 public constant override defaultPluginConfig = uint8(Plugins.BEFORE_SWAP_FLAG | Plugins.DYNAMIC_FEE);

    address public immutable pool;
    IKeeperFeeConfig public immutable factory;

    FeeState internal _state;

    modifier onlyPool() {
        if (msg.sender != pool) revert NotPool();
        _;
    }

    /// @dev Deployed by KeeperFeePluginFactory. Starts at the factory's initial fee, so it can be
    ///      attached to a pool that is already initialized.
    constructor(address _pool) {
        pool = _pool;
        factory = IKeeperFeeConfig(msg.sender);
        uint24 initial = factory.initialFee();
        _state = FeeState({fee: initial, nextFee: initial, nextFeeBlock: 0, updatedAt: uint64(block.timestamp)});
    }

    // ---------------------------------------------------------------------
    // Keeper
    // ---------------------------------------------------------------------

    /// @notice Schedule `fee` for this pool, effective from the next block.
    function setFee(uint24 fee) external {
        if (msg.sender != factory.keeper()) revert NotKeeper();
        (uint24 minFee, uint24 maxFee) = factory.bounds();
        if (fee < minFee || fee > maxFee) revert FeeOutOfBounds(fee, minFee, maxFee);

        uint64 effectiveBlock = uint64(block.number + 1);
        FeeState storage s = _state;
        // Roll the currently-live fee into `fee` before overwriting the pending slot.
        s.fee = _liveFee(s);
        s.nextFee = fee;
        s.nextFeeBlock = effectiveBlock;
        s.updatedAt = uint64(block.timestamp);

        emit FeeScheduled(fee, effectiveBlock);
    }

    // ---------------------------------------------------------------------
    // Views (what routers / quoters read)
    // ---------------------------------------------------------------------

    /// @notice The fee a swap in the current block will pay.
    function feeFor() public view returns (uint24) {
        (uint24 minFee, uint24 maxFee) = factory.bounds();
        uint24 fee = _liveFee(_state);
        if (fee < minFee) return minFee;
        if (fee > maxFee) return maxFee;
        return fee;
    }

    function feeState() external view returns (FeeState memory) {
        return _state;
    }

    // ---------------------------------------------------------------------
    // Hooks
    // ---------------------------------------------------------------------

    /// @dev Turns on BEFORE_SWAP + DYNAMIC_FEE when attached before initialization. For a pool that is
    ///      already initialized, the administrator calls `pool.setPluginConfig(defaultPluginConfig)`.
    function beforeInitialize(address, uint160) external override onlyPool returns (bytes4) {
        IAlgebraPool(pool).setPluginConfig(defaultPluginConfig);
        return IAlgebraPlugin.beforeInitialize.selector;
    }

    function beforeSwap(address, address, bool, int256, uint160, bool, bytes calldata)
        external
        view
        override
        onlyPool
        returns (bytes4, uint24, uint24)
    {
        return (IAlgebraPlugin.beforeSwap.selector, feeFor(), 0);
    }

    // Hooks below are not enabled in defaultPluginConfig; they only return their selectors.

    function afterInitialize(address, uint160, int24) external view override onlyPool returns (bytes4) {
        return IAlgebraPlugin.afterInitialize.selector;
    }

    function beforeModifyPosition(address, address, int24, int24, int128, bytes calldata)
        external
        view
        override
        onlyPool
        returns (bytes4, uint24)
    {
        return (IAlgebraPlugin.beforeModifyPosition.selector, 0);
    }

    function afterModifyPosition(address, address, int24, int24, int128, uint256, uint256, bytes calldata)
        external
        view
        override
        onlyPool
        returns (bytes4)
    {
        return IAlgebraPlugin.afterModifyPosition.selector;
    }

    function afterSwap(address, address, bool, int256, uint160, int256, int256, bytes calldata)
        external
        view
        override
        onlyPool
        returns (bytes4)
    {
        return IAlgebraPlugin.afterSwap.selector;
    }

    function beforeFlash(address, address, uint256, uint256, bytes calldata)
        external
        view
        override
        onlyPool
        returns (bytes4)
    {
        return IAlgebraPlugin.beforeFlash.selector;
    }

    function afterFlash(address, address, uint256, uint256, uint256, uint256, bytes calldata)
        external
        view
        override
        onlyPool
        returns (bytes4)
    {
        return IAlgebraPlugin.afterFlash.selector;
    }

    /// @dev This plugin charges no plugin fee.
    function handlePluginFee(uint256, uint256) external view override onlyPool returns (bytes4) {
        return IAlgebraPlugin.handlePluginFee.selector;
    }

    // ---------------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------------

    function _liveFee(FeeState storage s) internal view returns (uint24) {
        return block.number >= s.nextFeeBlock ? s.nextFee : s.fee;
    }
}
