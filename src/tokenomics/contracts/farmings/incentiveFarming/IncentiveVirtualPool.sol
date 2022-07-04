// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.7.6;

import 'algebra/contracts/libraries/TickManager.sol';
import 'algebra/contracts/libraries/TickTable.sol';

import './interfaces/IAlgebraIncentiveVirtualPool.sol';

import '../AlgebraVirtualPoolBase.sol';

contract IncentiveVirtualPool is AlgebraVirtualPoolBase, IAlgebraIncentiveVirtualPool {
    using TickTable for mapping(int16 => uint256);
    using TickManager for mapping(int24 => TickManager.Tick);

    /// @inheritdoc IAlgebraIncentiveVirtualPool
    bool public override isFinished;

    /// @inheritdoc IAlgebraIncentiveVirtualPool
    uint32 public immutable override desiredEndTimestamp;
    /// @inheritdoc IAlgebraIncentiveVirtualPool
    uint32 public immutable override desiredStartTimestamp;

    constructor(
        address _farmingCenterAddress,
        address _farmingAddress,
        address _pool,
        uint32 _desiredStartTimestamp,
        uint32 _desiredEndTimestamp
    ) AlgebraVirtualPoolBase(_farmingCenterAddress, _farmingAddress, _pool) {
        desiredStartTimestamp = _desiredStartTimestamp;
        desiredEndTimestamp = _desiredEndTimestamp;
        prevTimestamp = _desiredStartTimestamp;
    }

    /// @inheritdoc IAlgebraIncentiveVirtualPool
    function finish() external override onlyFarming {
        isFinished = true;
        _increaseCumulative(desiredEndTimestamp);
    }

    /// @inheritdoc IAlgebraIncentiveVirtualPool
    function getFinalStats() external view override returns (bool _isFinished, uint32 _timeOutside) {
        return (isFinished, timeOutside);
    }

    function _crossTick(int24 nextTick) internal override returns (int128 liquidityDelta) {
        return ticks.cross(nextTick, 0, 0, globalSecondsPerLiquidityCumulative, 0, 0);
    }

    function _increaseCumulative(uint32 currentTimestamp) internal override returns (Status) {
        if (currentTimestamp <= desiredStartTimestamp) {
            return Status.NOT_STARTED;
        }
        if (currentTimestamp > desiredEndTimestamp) {
            return Status.NOT_EXIST;
        }

        uint32 _previousTimestamp = prevTimestamp;
        if (currentTimestamp > _previousTimestamp) {
            uint128 _currentLiquidity = currentLiquidity;
            if (_currentLiquidity > 0) {
                globalSecondsPerLiquidityCumulative +=
                    (uint160(currentTimestamp - _previousTimestamp) << 128) /
                    _currentLiquidity;
                prevTimestamp = currentTimestamp;
            } else {
                timeOutside += currentTimestamp - _previousTimestamp;
                prevTimestamp = currentTimestamp;
            }
        }

        return Status.ACTIVE;
    }

    function _updateTick(
        int24 tick,
        int24 currentTick,
        int128 liquidityDelta,
        bool isTopTick
    ) internal override returns (bool updated) {
        return ticks.update(tick, currentTick, liquidityDelta, 0, 0, 0, 0, 0, isTopTick);
    }
}
