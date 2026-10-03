// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {KeeperFeePlugin} from "./KeeperFeePlugin.sol";

/// @title KeeperFeePluginFactory
/// @notice Holds the config shared by every KeeperFeePlugin (owner, keeper, fee bounds) and deploys
///         one plugin per Algebra pool. The pool administrator then attaches it with `pool.setPlugin`.
/// @dev Fees are in hundredths of a bip (1e6 = 100%, 100 = 1 bp), the unit Algebra's `overrideFee` uses.
contract KeeperFeePluginFactory {
    /// @dev Algebra treats overrideFee == 0 as "no override", and overrideFee + pluginFee must stay below 1e6.
    uint24 public constant MAX_FEE = 1e6 - 1;

    error NotOwner();
    error InvalidBounds();
    error PluginExists(address pool, address plugin);

    event PluginCreated(address indexed pool, address plugin);
    event BoundsSet(uint24 minFee, uint24 maxFee, uint24 initialFee);
    event KeeperSet(address indexed keeper);
    event OwnerSet(address indexed owner);

    address public owner;
    address public keeper;
    uint24 public minFee;
    uint24 public maxFee;
    uint24 public initialFee;

    mapping(address pool => address plugin) public pluginByPool;

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(address _owner, address _keeper, uint24 _minFee, uint24 _maxFee, uint24 _initialFee) {
        owner = _owner;
        keeper = _keeper;
        _setBounds(_minFee, _maxFee, _initialFee);
        emit OwnerSet(_owner);
        emit KeeperSet(_keeper);
    }

    function createPlugin(address pool) external onlyOwner returns (address plugin) {
        if (pluginByPool[pool] != address(0)) revert PluginExists(pool, pluginByPool[pool]);
        plugin = address(new KeeperFeePlugin(pool));
        pluginByPool[pool] = plugin;
        emit PluginCreated(pool, plugin);
    }

    /// @notice One read for the swap path.
    function bounds() external view returns (uint24, uint24) {
        return (minFee, maxFee);
    }

    function setKeeper(address _keeper) external onlyOwner {
        keeper = _keeper;
        emit KeeperSet(_keeper);
    }

    function setOwner(address _owner) external onlyOwner {
        owner = _owner;
        emit OwnerSet(_owner);
    }

    /// @notice Tightening bounds applies immediately: plugins clamp live fees on read.
    function setBounds(uint24 _minFee, uint24 _maxFee, uint24 _initialFee) external onlyOwner {
        _setBounds(_minFee, _maxFee, _initialFee);
    }

    function _setBounds(uint24 _minFee, uint24 _maxFee, uint24 _initialFee) internal {
        if (_minFee == 0 || _minFee > _maxFee || _maxFee > MAX_FEE) revert InvalidBounds();
        if (_initialFee < _minFee || _initialFee > _maxFee) revert InvalidBounds();
        minFee = _minFee;
        maxFee = _maxFee;
        initialFee = _initialFee;
        emit BoundsSet(_minFee, _maxFee, _initialFee);
    }
}
