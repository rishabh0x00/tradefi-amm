// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

contract DEX is ReentrancyGuard {
    struct Position {
        uint128 liquidity; // Liquidity provided by the LP
        int24 lowerTick;   // Lower tick of the price range
        int24 upperTick;   // Upper tick of the price range
        uint256 feeGrowthInside0Last; // Fee growth for token0 at the time of last update
        uint256 feeGrowthInside1Last; // Fee growth for token1 at the time of last update
    }

    struct Pool {
        uint160 sqrtPriceX96; // Current square root of the price (Q64.96 format)
        uint128 liquidity;    // Total liquidity in the pool
        mapping(int24 => uint128) tickLiquidity; // Liquidity at each tick
        mapping(address => Position) positions;  // LP positions
    }

    address public immutable token0;
    address public immutable token1;
    uint24 public constant fee = 3000; // 0.3% fee
    Pool public pool;

    event LiquidityAdded(
        address indexed provider,
        uint256 amount0,
        uint256 amount1,
        uint128 liquidity,
        int24 lowerTick,
        int24 upperTick
    );
    event LiquidityRemoved(
        address indexed provider,
        uint256 amount0,
        uint256 amount1,
        uint128 liquidity,
        int24 lowerTick,
        int24 upperTick
    );
    event Swap(
        address indexed sender,
        uint256 amountIn,
        uint256 amountOut,
        address tokenIn,
        address tokenOut
    );

    constructor(address _token0, address _token1) {
        token0 = _token0;
        token1 = _token1;
    }

    // Add liquidity within a price range
    function addLiquidity(
        uint256 amount0Desired,
        uint256 amount1Desired,
        int24 lowerTick,
        int24 upperTick
    ) external nonReentrant {
        require(amount0Desired > 0 && amount1Desired > 0, "Amounts must be greater than 0");
        require(lowerTick < upperTick, "Invalid tick range");

        // Transfer tokens from the user
        IERC20(token0).transferFrom(msg.sender, address(this), amount0Desired);
        IERC20(token1).transferFrom(msg.sender, address(this), amount1Desired);

        // Calculate liquidity (simplified for demonstration)
        uint128 liquidity = uint128(Math.min(amount0Desired, amount1Desired));

        // Update pool state
        pool.liquidity += liquidity;
        pool.tickLiquidity[lowerTick] += liquidity;
        pool.tickLiquidity[upperTick] += liquidity;

        // Update user position
        Position storage position = pool.positions[msg.sender];
        position.liquidity += liquidity;
        position.lowerTick = lowerTick;
        position.upperTick = upperTick;

        emit LiquidityAdded(msg.sender, amount0Desired, amount1Desired, liquidity, lowerTick, upperTick);
    }

    // Remove liquidity
    function removeLiquidity(int24 lowerTick, int24 upperTick) external nonReentrant {
        Position storage position = pool.positions[msg.sender];
        require(position.liquidity > 0, "No liquidity to remove");
        require(position.lowerTick == lowerTick && position.upperTick == upperTick, "Invalid tick range");

        // Calculate amounts to return (simplified for demonstration)
        uint256 amount0 = (position.liquidity * uint256(uint128(pool.tickLiquidity[lowerTick]))) / pool.liquidity;
        uint256 amount1 = (position.liquidity * uint256(uint128(pool.tickLiquidity[upperTick]))) / pool.liquidity;

        // Update pool state
        pool.liquidity -= position.liquidity;
        pool.tickLiquidity[lowerTick] -= position.liquidity;
        pool.tickLiquidity[upperTick] -= position.liquidity;

        // Update user position
        position.liquidity = 0;

        // Transfer tokens back to the user
        IERC20(token0).transfer(msg.sender, amount0);
        IERC20(token1).transfer(msg.sender, amount1);

        emit LiquidityRemoved(msg.sender, amount0, amount1, position.liquidity, lowerTick, upperTick);
    }
}
