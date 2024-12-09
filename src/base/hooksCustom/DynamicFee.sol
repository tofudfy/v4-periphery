// SPDX-License-Identifier: UNLICENSED
// a uniswapV4 hook that allows the pool use dynamic fees
pragma solidity ^0.8.20;
// import "hardhat/console.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Pool} from "@uniswap/v4-core/src/libraries/Pool.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {BaseHook} from "../hooks/BaseHook.sol";
import {Currency} from "@uniswap/v4-core/src/libraries/CurrencyDelta.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";

/// @notice The dynamic fee manager determines fees for pools
/// @dev note that this pool is only called if the PoolKey fee value is equal to the DYNAMIC_FEE magic value
interface IDynamicFeeManager {
    function getFee(PoolKey calldata key) external returns (uint24);
}

contract DynamicFee is BaseHook, IDynamicFeeManager{
    using SafeCast for uint256;
    using Pool for Pool.State;
    using StateLibrary for IPoolManager;

    uint160 public lastPrice; 
    uint160 public nowPrice;
    uint256 public lastBlockNumber;
    uint24 public feeNow;

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function afterInitialize(address, PoolKey calldata key, uint160, int24, bytes calldata)
        external
        override
        virtual
        returns (bytes4)
    {
        // Initializing the nowPrice during the initialization of the contract
        (nowPrice,,,) = poolManager.getSlot0(PoolIdLibrary.toId(key));
        lastBlockNumber = block.number;

        return DynamicFee.afterInitialize.selector;
    }

    function getFee(PoolKey calldata key) external returns (uint24) {
        if(block.number > lastBlockNumber) {
            lastPrice = nowPrice;

            // 调用function getSlot0(PoolId id), 获取价格信息存入price_now
            (nowPrice,,,) = poolManager.getSlot0(PoolIdLibrary.toId(key));
            
            // 比较price_now和price_last, 根据price波动率设定fee
            if(nowPrice > lastPrice) {
                feeNow = 30;
            } else {
                feeNow = 5;
            }
            
            lastBlockNumber = block.number; // Update the last block number
        }
        return feeNow;
    }

    function afterSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, BalanceDelta, bytes calldata) external override virtual returns (bytes4, int128) {
        // Update lastBlockNumber after the swap
        lastBlockNumber = block.number;
        return (DynamicFee.afterSwap.selector, 0);
    }

}