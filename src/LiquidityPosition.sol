// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {IPoolManager} from '@uniswap/v4-core/src/interfaces/IPoolManager.sol';
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from '@uniswap/v4-core/src/PoolManager.sol';
import {IUnlockCallback} from '@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol';
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {CurrencyDelta, Currency} from '@uniswap/v4-core/src/libraries/CurrencyDelta.sol';
import {TickMath} from '@uniswap/v4-core/src/libraries/TickMath.sol';

contract LiquidityPosition is IUnlockCallback {
    using SafeERC20 for IERC20;
    using CurrencyDelta for Currency;
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    bytes4 constant FUNCSIG_LIQUIDITY = 0x00000001;
    bytes4 constant FUNCSIG_SWAP = 0x00000002;
    bytes4 constant FUNCSIG_DONATE = 0x00000003;

    struct LiquidityParams {
        int24 tickLower;
        int24 tickUpper;
        int256 liquidityDelta;
    }

    IPoolManager public immutable poolManager;
    PoolKey key;

    mapping(address => BalanceDelta) rewards;

    error InvalidParams();

    constructor(IPoolManager _poolManager, PoolKey memory _key) {
        poolManager = _poolManager;
        key = _key;
    }

    function getSlot0()
        public
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee)
    {
        return poolManager.getSlot0(key.toId());
    }

    function addLiquidity(
        LiquidityParams calldata params, 
        bytes calldata hookData
    ) external {
        IPoolManager.ModifyLiquidityParams memory positionParams = IPoolManager.ModifyLiquidityParams({
            tickLower: params.tickLower,
            tickUpper: params.tickUpper,
            liquidityDelta: params.liquidityDelta,
            salt: bytes32(uint256(uint160(msg.sender)))
        });

        _unlock(FUNCSIG_LIQUIDITY, abi.encode(positionParams, hookData));
        /*
        poolManager.unlock(
            abi.encodeCall(this.addLiquidity, (positionParams, hookData))
        );*/
    }

    function executeSwap(
        IPoolManager.SwapParams memory params, 
        bytes calldata hookData
    ) external {
        _unlock(FUNCSIG_SWAP, abi.encode(params, hookData));
        /*
        poolManager.unlock(
            abi.encodeCall(this.executeSwap, (params, hookData))
        );*/
    }

    function donate(
        uint256 amount0,
        uint256 amount1,
        bytes calldata hookData
    ) external {
        _unlock(FUNCSIG_DONATE, abi.encode(amount0, amount1, hookData));
        /*
        poolManager.unlock(
            abi.encodeCall(this.donate, (amount0, amount1, hookData))
        );*/
    }

    function _unlock(
        bytes4 funcSig, 
        bytes memory args
    ) private {
        poolManager.unlock(abi.encode(funcSig, msg.sender, args));
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        (bytes4 funcSig, address recipient, bytes memory args) = abi.decode(data, (bytes4, address, bytes));

        if (funcSig == FUNCSIG_LIQUIDITY) {
            _handleLiquidity(args, recipient);
        } else if (funcSig == this.executeSwap.selector) {
            _handleSwap(args, recipient);
        } else if (funcSig == this.donate.selector) {
            _handleDonate(args, recipient);
        } else {
            revert InvalidParams();
        }

        return bytes("");
    }

    function _handleLiquidity(bytes memory args, address recipient) private {
        (IPoolManager.ModifyLiquidityParams memory positionParams, bytes memory hookData) = abi.decode(args, (IPoolManager.ModifyLiquidityParams, bytes));

        (BalanceDelta delta, BalanceDelta fees) = poolManager.modifyLiquidity(key, positionParams, hookData);
        
        rewards[recipient] = rewards[recipient] + fees;

        _settleCurrencyBalance(key.currency0, recipient, delta.amount0());
        _settleCurrencyBalance(key.currency1, recipient, delta.amount1());
    }
    
    function _handleSwap(bytes memory args, address recipient) private {
        (IPoolManager.SwapParams memory swapParams, bytes memory hookData) = abi.decode(args, (IPoolManager.SwapParams, bytes));
        
        BalanceDelta delta = poolManager.swap(key, swapParams, hookData);
        
        _settleCurrencyBalance(key.currency0, recipient, delta.amount0());
        _settleCurrencyBalance(key.currency1, recipient, delta.amount1());
    }

    function _handleDonate(bytes memory args, address recipient) private {
        (uint256 address0, uint256 address1, bytes memory hookData) = abi.decode(args, (uint256, uint256, bytes));
        
        BalanceDelta delta = poolManager.donate(key, address0, address1, hookData);
        
        _settleCurrencyBalance(key.currency0, recipient, delta.amount0());
        _settleCurrencyBalance(key.currency1, recipient, delta.amount1());
    }

    // [Mark] ref: https://learnblockchain.cn/article/6984
    function _settleCurrencyBalance(
        Currency currency,
        address recipient,
        int128 deltaAmount
    ) private {
        if (deltaAmount > 0) {
            poolManager.take(currency, recipient, uint128(deltaAmount));
        } else if (deltaAmount < 0) {
            uint128 amount = uint128(-deltaAmount);
            if (currency.isNative()) {
                currency.transfer(address(poolManager), amount);
                // todo: is {value: uint128(deltaAmount)} correct? 
                poolManager.settle{value: uint128(deltaAmount)}();
            } else {
                IERC20(Currency.unwrap(currency)).safeTransferFrom(
                    recipient,
                    address(this),
                    amount
                );
                poolManager.sync(currency);
                currency.transfer(address(poolManager), amount);
                poolManager.settle();
            }
        }
    }
}
