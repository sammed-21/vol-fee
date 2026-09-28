// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";

/// @title VolFeeHook
/// @notice Keeper-driven dynamic LP fee. Volatility is computed off-chain; a keeper writes the fee,
///         and `beforeSwap` only reads it. No oracle, no hookData, no vol math in the swap path.
/// @dev A fee written in block N takes effect in block N+1. Every swap in a block pays the fee that
///      was live at the start of that block, so `feeFor(id)` read at block N is exactly what a swap
///      in block N will be charged (quote = fill), and the keeper cannot reprice a block mid-flight.
///      Pools must be initialized with `LPFeeLibrary.DYNAMIC_FEE_FLAG` (0x800000).
///      Required hook address flags: AFTER_INITIALIZE | BEFORE_SWAP.
contract VolFeeHook {
    using LPFeeLibrary for uint24;

    /// @dev Packed into one slot.
    struct FeeState {
        uint24 fee; // fee live until `nextFeeBlock`
        uint24 nextFee; // fee live from `nextFeeBlock` onward
        uint64 nextFeeBlock;
        uint64 updatedAt; // timestamp of last keeper write (for off-chain staleness monitoring)
        bool initialized;
    }

    error NotPoolManager();
    error NotOwner();
    error NotKeeper();
    error MustUseDynamicFee();
    error PoolNotInitialized();
    error FeeOutOfBounds(uint24 fee, uint24 minFee, uint24 maxFee);
    error InvalidBounds();

    event FeeScheduled(PoolId indexed id, uint24 fee, uint64 effectiveBlock);
    event BoundsSet(uint24 minFee, uint24 maxFee, uint24 initialFee);
    event KeeperSet(address indexed keeper);
    event OwnerSet(address indexed owner);

    IPoolManager public immutable poolManager;

    address public owner;
    address public keeper;

    /// @notice Fee bounds in pips (1e6 = 100%, 100 = 1 bp).
    uint24 public minFee;
    uint24 public maxFee;
    /// @notice Fee a pool starts with before the keeper's first write.
    uint24 public initialFee;

    mapping(PoolId => FeeState) internal _state;

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(
        IPoolManager _poolManager,
        address _owner,
        address _keeper,
        uint24 _minFee,
        uint24 _maxFee,
        uint24 _initialFee
    ) {
        poolManager = _poolManager;
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());

        owner = _owner;
        keeper = _keeper;
        _setBounds(_minFee, _maxFee, _initialFee);
        emit OwnerSet(_owner);
        emit KeeperSet(_keeper);
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory p) {
        p.afterInitialize = true;
        p.beforeSwap = true;
    }

    // ---------------------------------------------------------------------
    // Keeper
    // ---------------------------------------------------------------------

    /// @notice Schedule `fee` for the pool, effective from the next block.
    function setFee(PoolId id, uint24 fee) external {
        if (msg.sender != keeper) revert NotKeeper();
        if (fee < minFee || fee > maxFee) revert FeeOutOfBounds(fee, minFee, maxFee);

        FeeState storage s = _state[id];
        if (!s.initialized) revert PoolNotInitialized();

        uint64 effectiveBlock = uint64(block.number + 1);
        // Roll the currently-live fee into `fee` before overwriting the pending slot.
        s.fee = _liveFee(s);
        s.nextFee = fee;
        s.nextFeeBlock = effectiveBlock;
        s.updatedAt = uint64(block.timestamp);

        emit FeeScheduled(id, fee, effectiveBlock);
    }

    // ---------------------------------------------------------------------
    // Views (what routers / quoters read)
    // ---------------------------------------------------------------------

    /// @notice The fee a swap in the current block will pay.
    function feeFor(PoolId id) public view returns (uint24) {
        FeeState storage s = _state[id];
        if (!s.initialized) revert PoolNotInitialized();
        return _clamp(_liveFee(s));
    }

    function feeState(PoolId id) external view returns (FeeState memory) {
        return _state[id];
    }

    // ---------------------------------------------------------------------
    // Hook callbacks
    // ---------------------------------------------------------------------

    function afterInitialize(address, PoolKey calldata key, uint160, int24) external onlyPoolManager returns (bytes4) {
        if (!key.fee.isDynamicFee()) revert MustUseDynamicFee();
        _state[key.toId()] = FeeState({
            fee: initialFee,
            nextFee: initialFee,
            nextFeeBlock: 0,
            updatedAt: uint64(block.timestamp),
            initialized: true
        });
        return IHooks.afterInitialize.selector;
    }

    function beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        uint24 fee = feeFor(key.toId());
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    // ---------------------------------------------------------------------
    // Admin
    // ---------------------------------------------------------------------

    function setKeeper(address _keeper) external onlyOwner {
        keeper = _keeper;
        emit KeeperSet(_keeper);
    }

    function setOwner(address _owner) external onlyOwner {
        owner = _owner;
        emit OwnerSet(_owner);
    }

    /// @notice Tightening bounds applies immediately: live fees are clamped on read.
    function setBounds(uint24 _minFee, uint24 _maxFee, uint24 _initialFee) external onlyOwner {
        _setBounds(_minFee, _maxFee, _initialFee);
    }

    // ---------------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------------

    function _liveFee(FeeState storage s) internal view returns (uint24) {
        return block.number >= s.nextFeeBlock ? s.nextFee : s.fee;
    }

    function _clamp(uint24 fee) internal view returns (uint24) {
        if (fee < minFee) return minFee;
        if (fee > maxFee) return maxFee;
        return fee;
    }

    function _setBounds(uint24 _minFee, uint24 _maxFee, uint24 _initialFee) internal {
        if (_minFee > _maxFee || _maxFee > LPFeeLibrary.MAX_LP_FEE) revert InvalidBounds();
        if (_initialFee < _minFee || _initialFee > _maxFee) revert InvalidBounds();
        minFee = _minFee;
        maxFee = _maxFee;
        initialFee = _initialFee;
        emit BoundsSet(_minFee, _maxFee, _initialFee);
    }
}
