// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.17;
pragma abicoder v1;

import './base/AlgebraPoolBase.sol';
import './base/ReentrancyGuard.sol';
import './base/Positions.sol';
import './base/SwapCalculation.sol';
import './base/ReservesManager.sol';
import './base/TickStructure.sol';

import './libraries/FullMath.sol';
import './libraries/Constants.sol';
import './libraries/SafeCast.sol';
import './libraries/TickMath.sol';
import './libraries/LiquidityMath.sol';
import './libraries/Plugins.sol';

import './interfaces/IAlgebraFactory.sol';
import './interfaces/callback/IAlgebraMintCallback.sol';
import './interfaces/callback/IAlgebraFlashCallback.sol';

/// @title Algebra concentrated liquidity pool
/// @notice This contract is responsible for liquidity positions, swaps and flashloans
/// @dev Version: Algebra Integral
contract AlgebraPool is AlgebraPoolBase, TickStructure, ReentrancyGuard, Positions, SwapCalculation, ReservesManager {
  using SafeCast for uint256;
  using SafeCast for uint128;
  using Plugins for uint8;
  using Plugins for bytes4;

  /// @inheritdoc IAlgebraPoolActions
  function initialize(uint160 initialPrice) external override {
    if (globalState.price != 0) revert alreadyInitialized(); // after initialization, the price can never become zero
    int24 tick = TickMath.getTickAtSqrtRatio(initialPrice); // getTickAtSqrtRatio checks validity of initialPrice inside

    _lock();

    if (plugin != address(0)) {
      IAlgebraPlugin(plugin).beforeInitialize(msg.sender, initialPrice).shouldReturn(IAlgebraPlugin.beforeInitialize.selector);
    }

    (uint16 _communityFee, int24 _tickSpacing, uint16 _fee) = _getDefaultConfiguration();
    tickSpacing = _tickSpacing;

    uint8 pluginConfig = globalState.pluginConfig;

    globalState.price = initialPrice;
    globalState.tick = tick;
    globalState.fee = _fee;
    globalState.communityFee = _communityFee;

    emit Initialize(initialPrice, tick);
    emit TickSpacing(_tickSpacing);
    emit CommunityFee(_communityFee);

    _unlock();

    if (pluginConfig.hasFlag(Plugins.AFTER_INIT_FLAG)) {
      IAlgebraPlugin(plugin).afterInitialize(msg.sender, initialPrice, tick).shouldReturn(IAlgebraPlugin.afterInitialize.selector);
    }
  }

  /// @inheritdoc IAlgebraPoolActions
  function mint(
    address leftoversRecipient,
    address recipient,
    int24 bottomTick,
    int24 topTick,
    uint128 liquidityDesired,
    bytes calldata data
  ) external override onlyValidTicks(bottomTick, topTick) returns (uint256 amount0, uint256 amount1, uint128 liquidityActual) {
    if (liquidityDesired == 0) revert zeroLiquidityDesired();

    _beforeModifyPosition(recipient, bottomTick, topTick, liquidityDesired.toInt128(), data);
    _lock();

    unchecked {
      int24 _tickSpacing = tickSpacing;
      if (bottomTick % _tickSpacing | topTick % _tickSpacing != 0) revert tickIsNotSpaced();
    }

    (amount0, amount1, ) = LiquidityMath.getAmountsForLiquidity(
      bottomTick,
      topTick,
      liquidityDesired.toInt128(),
      globalState.tick,
      globalState.price
    );

    (uint256 receivedAmount0, uint256 receivedAmount1) = _updateReserves();
    _mintCallback(amount0, amount1, data); // IAlgebraMintCallback.algebraMintCallback to msg.sender

    receivedAmount0 = amount0 == 0 ? 0 : _balanceToken0() - receivedAmount0;
    receivedAmount1 = amount1 == 0 ? 0 : _balanceToken1() - receivedAmount1;

    if (receivedAmount0 < amount0) {
      liquidityActual = uint128(FullMath.mulDiv(uint256(liquidityDesired), receivedAmount0, amount0));
    } else {
      liquidityActual = liquidityDesired;
    }
    if (receivedAmount1 < amount1) {
      uint128 liquidityForRA1 = uint128(FullMath.mulDiv(uint256(liquidityDesired), receivedAmount1, amount1));
      if (liquidityForRA1 < liquidityActual) liquidityActual = liquidityForRA1;
    }
    if (liquidityActual == 0) revert zeroLiquidityActual();

    // scope to prevent "stack too deep"
    {
      Position storage _position = getOrCreatePosition(recipient, bottomTick, topTick);
      (amount0, amount1) = _updatePositionTicksAndFees(_position, bottomTick, topTick, liquidityActual.toInt128());
    }

    unchecked {
      // return leftovers
      if (amount0 > 0) {
        if (receivedAmount0 > amount0) _transfer(token0, leftoversRecipient, receivedAmount0 - amount0);
        else assert(receivedAmount0 == amount0); // must always be true
      }
      if (amount1 > 0) {
        if (receivedAmount1 > amount1) _transfer(token1, leftoversRecipient, receivedAmount1 - amount1);
        else assert(receivedAmount1 == amount1); // must always be true
      }
    }

    _changeReserves(int256(amount0), int256(amount1), 0, 0);
    emit Mint(msg.sender, recipient, bottomTick, topTick, liquidityActual, amount0, amount1);

    _unlock();
    _afterModifyPosition(recipient, bottomTick, topTick, liquidityActual.toInt128(), amount0, amount1, data);
  }

  /// @inheritdoc IAlgebraPoolActions
  function burn(
    int24 bottomTick,
    int24 topTick,
    uint128 amount,
    bytes calldata data
  ) external override onlyValidTicks(bottomTick, topTick) returns (uint256 amount0, uint256 amount1) {
    if (amount > uint128(type(int128).max)) revert arithmeticError();

    int128 liquidityDelta = -int128(amount);

    _beforeModifyPosition(msg.sender, bottomTick, topTick, liquidityDelta, data);
    _lock();

    _updateReserves();
    Position storage position = getOrCreatePosition(msg.sender, bottomTick, topTick);

    (amount0, amount1) = _updatePositionTicksAndFees(position, bottomTick, topTick, liquidityDelta);

    if (amount0 | amount1 != 0) {
      (position.fees0, position.fees1) = (position.fees0 + uint128(amount0), position.fees1 + uint128(amount1));
    }

    if (amount | amount0 | amount1 != 0) emit Burn(msg.sender, bottomTick, topTick, amount, amount0, amount1);

    _unlock();
    _afterModifyPosition(msg.sender, bottomTick, topTick, liquidityDelta, amount0, amount1, data);
  }

  function _beforeModifyPosition(address owner, int24 bottomTick, int24 topTick, int128 liquidityDelta, bytes calldata data) internal {
    if (globalState.pluginConfig.hasFlag(Plugins.BEFORE_POSITION_MODIFY_FLAG)) {
      IAlgebraPlugin(plugin).beforeModifyPosition(msg.sender, owner, bottomTick, topTick, liquidityDelta, data).shouldReturn(
        IAlgebraPlugin.beforeModifyPosition.selector
      );
    }
  }

  function _afterModifyPosition(
    address owner,
    int24 bottomTick,
    int24 topTick,
    int128 liquidityDelta,
    uint256 amount0,
    uint256 amount1,
    bytes calldata data
  ) internal {
    if (globalState.pluginConfig.hasFlag(Plugins.AFTER_POSITION_MODIFY_FLAG)) {
      IAlgebraPlugin(plugin).afterModifyPosition(msg.sender, owner, bottomTick, topTick, liquidityDelta, amount0, amount1, data).shouldReturn(
        IAlgebraPlugin.afterModifyPosition.selector
      );
    }
  }

  /// @inheritdoc IAlgebraPoolActions
  function collect(
    address recipient,
    int24 bottomTick,
    int24 topTick,
    uint128 amount0Requested,
    uint128 amount1Requested
  ) external override nonReentrant returns (uint128 amount0, uint128 amount1) {
    // we don't check tick range validity, because if ticks are incorrect, the position will be empty
    Position storage position = getOrCreatePosition(msg.sender, bottomTick, topTick);
    (uint128 positionFees0, uint128 positionFees1) = (position.fees0, position.fees1);

    if (amount0Requested > positionFees0) amount0Requested = positionFees0;
    if (amount1Requested > positionFees1) amount1Requested = positionFees1;

    if (amount0Requested | amount1Requested != 0) {
      // use one if since fees0 and fees1 are tightly packed
      (amount0, amount1) = (amount0Requested, amount1Requested);

      unchecked {
        // single SSTORE
        (position.fees0, position.fees1) = (positionFees0 - amount0, positionFees1 - amount1);

        if (amount0 > 0) _transfer(token0, recipient, amount0);
        if (amount1 > 0) _transfer(token1, recipient, amount1);
        _changeReserves(-int256(uint256(amount0)), -int256(uint256(amount1)), 0, 0);
      }
      emit Collect(msg.sender, recipient, bottomTick, topTick, amount0, amount1);
    }
  }

  /// @inheritdoc IAlgebraPoolActions
  function swap(
    address recipient,
    bool zeroToOne,
    int256 amountRequired,
    uint160 limitSqrtPrice,
    bytes calldata data
  ) external override returns (int256 amount0, int256 amount1) {
    _beforeSwap(recipient, zeroToOne, amountRequired, limitSqrtPrice, false, data);
    _lock();

    {
      uint160 currentPrice;
      int24 currentTick;
      uint128 currentLiquidity;
      uint256 communityFee;
      (amount0, amount1, currentPrice, currentTick, currentLiquidity, communityFee) = _calculateSwap(zeroToOne, amountRequired, limitSqrtPrice);
      (uint256 balance0Before, uint256 balance1Before) = _updateReserves();
      if (zeroToOne) {
        unchecked {
          if (amount1 < 0) _transfer(token1, recipient, uint256(-amount1)); // amount1 cannot be > 0
        }
        _swapCallback(amount0, amount1, data); // callback to get tokens from the msg.sender
        if (balance0Before + uint256(amount0) > _balanceToken0()) revert insufficientInputAmount();
        _changeReserves(amount0, amount1, communityFee, 0); // reflect reserve change and pay communityFee
      } else {
        unchecked {
          if (amount0 < 0) _transfer(token0, recipient, uint256(-amount0)); // amount0 cannot be > 0
        }
        _swapCallback(amount0, amount1, data); // callback to get tokens from the msg.sender
        if (balance1Before + uint256(amount1) > _balanceToken1()) revert insufficientInputAmount();
        _changeReserves(amount0, amount1, 0, communityFee); // reflect reserve change and pay communityFee
      }

      emit Swap(msg.sender, recipient, amount0, amount1, currentPrice, currentLiquidity, currentTick);
    }

    _unlock();
    _afterSwap(recipient, zeroToOne, amountRequired, limitSqrtPrice, amount0, amount1, data);
  }

  /// @inheritdoc IAlgebraPoolActions
  function swapWithPaymentInAdvance(
    address leftoversRecipient,
    address recipient,
    bool zeroToOne,
    int256 amountToSell,
    uint160 limitSqrtPrice,
    bytes calldata data
  ) external override returns (int256 amount0, int256 amount1) {
    if (amountToSell < 0) revert invalidAmountRequired(); // we support only exactInput here

    _lock();
    // firstly we are getting tokens from the original caller of the transaction
    // since the pool can get less tokens then expected, _amountToSell_ can be changed
    {
      // scope to prevent "stack too deep"
      int256 amountReceived;
      if (zeroToOne) {
        uint256 balanceBefore = _balanceToken0();
        _swapCallback(amountToSell, 0, data); // callback to get tokens from the msg.sender
        uint256 balanceAfter = _balanceToken0();
        amountReceived = (balanceAfter - balanceBefore).toInt256();
        _changeReserves(amountReceived, 0, 0, 0);
      } else {
        uint256 balanceBefore = _balanceToken1();
        _swapCallback(0, amountToSell, data); // callback to get tokens from the msg.sender
        uint256 balanceAfter = _balanceToken1();
        amountReceived = (balanceAfter - balanceBefore).toInt256();
        _changeReserves(0, amountReceived, 0, 0);
      }
      if (amountReceived != amountToSell) amountToSell = amountReceived; // TODO think about < or !=
    }
    if (amountToSell == 0) revert insufficientInputAmount();

    _unlock();
    _beforeSwap(recipient, zeroToOne, amountToSell, limitSqrtPrice, true, data);
    _lock();

    _updateReserves();

    uint160 currentPrice;
    int24 currentTick;
    uint128 currentLiquidity;
    uint256 communityFee;
    (amount0, amount1, currentPrice, currentTick, currentLiquidity, communityFee) = _calculateSwap(zeroToOne, amountToSell, limitSqrtPrice);

    unchecked {
      // transfer to the recipient
      if (zeroToOne) {
        if (amount1 < 0) _transfer(token1, recipient, uint256(-amount1)); // amount1 cannot be > 0
        uint256 leftover = uint256(amountToSell - amount0); // return the leftovers
        if (leftover != 0) _transfer(token0, leftoversRecipient, leftover);
        _changeReserves(-leftover.toInt256(), amount1, communityFee, 0); // reflect reserve change and pay communityFee
      } else {
        if (amount0 < 0) _transfer(token0, recipient, uint256(-amount0)); // amount0 cannot be > 0
        uint256 leftover = uint256(amountToSell - amount1); // return the leftovers
        if (leftover != 0) _transfer(token1, leftoversRecipient, leftover);
        _changeReserves(amount0, -leftover.toInt256(), 0, communityFee); // reflect reserve change and pay communityFee
      }
    }

    emit Swap(msg.sender, recipient, amount0, amount1, currentPrice, currentLiquidity, currentTick);

    _unlock();
    _afterSwap(recipient, zeroToOne, amountToSell, limitSqrtPrice, amount0, amount1, data);
  }

  function _beforeSwap(
    address recipient,
    bool zto,
    int256 amountRequired,
    uint160 limitSqrtPrice,
    bool withPaymentInAdvance,
    bytes calldata data
  ) internal {
    if (globalState.pluginConfig.hasFlag(Plugins.BEFORE_SWAP_FLAG)) {
      IAlgebraPlugin(plugin).beforeSwap(msg.sender, recipient, zto, amountRequired, limitSqrtPrice, withPaymentInAdvance, data).shouldReturn(
        IAlgebraPlugin.beforeSwap.selector
      );
    }
  }

  function _afterSwap(
    address recipient,
    bool zto,
    int256 amountRequired,
    uint160 limitSqrtPrice,
    int256 amount0,
    int256 amount1,
    bytes calldata data
  ) internal {
    if (globalState.pluginConfig.hasFlag(Plugins.AFTER_SWAP_FLAG)) {
      IAlgebraPlugin(plugin).afterSwap(msg.sender, recipient, zto, amountRequired, limitSqrtPrice, amount0, amount1, data).shouldReturn(
        IAlgebraPlugin.afterSwap.selector
      );
    }
  }

  /// @inheritdoc IAlgebraPoolActions
  function flash(address recipient, uint256 amount0, uint256 amount1, bytes calldata data) external override {
    if (globalState.pluginConfig.hasFlag(Plugins.BEFORE_FLASH_FLAG)) {
      IAlgebraPlugin(plugin).beforeFlash(msg.sender, recipient, amount0, amount1, data).shouldReturn(IAlgebraPlugin.beforeFlash.selector);
    }

    _lock();

    uint256 paid0;
    uint256 paid1;
    {
      (uint256 balance0Before, uint256 balance1Before) = _updateReserves();
      uint256 fee0;
      if (amount0 > 0) {
        fee0 = FullMath.mulDivRoundingUp(amount0, Constants.FLASH_FEE, Constants.FEE_DENOMINATOR);
        _transfer(token0, recipient, amount0);
      }
      uint256 fee1;
      if (amount1 > 0) {
        fee1 = FullMath.mulDivRoundingUp(amount1, Constants.FLASH_FEE, Constants.FEE_DENOMINATOR);
        _transfer(token1, recipient, amount1);
      }

      _flashCallback(fee0, fee1, data); // IAlgebraFlashCallback.algebraFlashCallback to msg.sender

      paid0 = _balanceToken0();
      if (balance0Before + fee0 > paid0) revert flashInsufficientPaid0();
      paid1 = _balanceToken1();
      if (balance1Before + fee1 > paid1) revert flashInsufficientPaid1();

      unchecked {
        paid0 -= balance0Before;
        paid1 -= balance1Before;
      }

      uint256 _communityFee = globalState.communityFee;
      if (_communityFee > 0) {
        uint256 communityFee0;
        if (paid0 > 0) communityFee0 = FullMath.mulDiv(paid0, _communityFee, Constants.COMMUNITY_FEE_DENOMINATOR);
        uint256 communityFee1;
        if (paid1 > 0) communityFee1 = FullMath.mulDiv(paid1, _communityFee, Constants.COMMUNITY_FEE_DENOMINATOR);

        _changeReserves(int256(communityFee0), int256(communityFee1), communityFee0, communityFee1);
      }
      emit Flash(msg.sender, recipient, amount0, amount1, paid0, paid1);
    }

    _unlock();

    if (globalState.pluginConfig.hasFlag(Plugins.AFTER_FLASH_FLAG)) {
      IAlgebraPlugin(plugin).afterFlash(msg.sender, recipient, amount0, amount1, paid0, paid1, data).shouldReturn(IAlgebraPlugin.afterFlash.selector);
    }
  }

  /// @dev using function to save bytecode
  function _checkIfAdministrator() private view {
    if (!IAlgebraFactory(factory).hasRoleOrOwner(Constants.POOLS_ADMINISTRATOR_ROLE, msg.sender)) revert notAllowed();
  }

  /// @inheritdoc IAlgebraPoolPermissionedActions
  function setCommunityFee(uint16 newCommunityFee) external override nonReentrant {
    _checkIfAdministrator();
    if (newCommunityFee > Constants.MAX_COMMUNITY_FEE || newCommunityFee == globalState.communityFee) revert invalidNewCommunityFee();
    globalState.communityFee = newCommunityFee;
    emit CommunityFee(newCommunityFee);
  }

  /// @inheritdoc IAlgebraPoolPermissionedActions
  function setTickSpacing(int24 newTickSpacing) external override nonReentrant {
    _checkIfAdministrator();
    if (newTickSpacing <= 0 || newTickSpacing > Constants.MAX_TICK_SPACING || tickSpacing == newTickSpacing) revert invalidNewTickSpacing();
    tickSpacing = newTickSpacing;
    emit TickSpacing(newTickSpacing);
  }

  /// @inheritdoc IAlgebraPoolPermissionedActions
  function setPlugin(address newPluginAddress) external override {
    _checkIfAdministrator();
    plugin = newPluginAddress;
    emit Plugin(newPluginAddress);
  }

  /// @inheritdoc IAlgebraPoolPermissionedActions
  function setPluginConfig(uint8 newConfig) external override {
    if (msg.sender != plugin) _checkIfAdministrator();
    globalState.pluginConfig = newConfig;
    emit PluginConfig(newConfig);
  }

  /// @inheritdoc IAlgebraPoolPermissionedActions
  function setFee(uint16 newFee) external override {
    bool isDynamicFeeEnabled = globalState.pluginConfig.hasFlag(Plugins.DYNAMIC_FEE);

    if (msg.sender == plugin) {
      if (!isDynamicFeeEnabled) revert dynamicFeeDisabled();
    } else {
      if (isDynamicFeeEnabled) revert dynamicFeeActive();
      _checkIfAdministrator();
    }
    globalState.fee = newFee;
    emit Fee(newFee);
  }
}
