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

    // Swap tokens using the constant product formula and concentrated liquidity
    function swap(
        uint256 amountIn,
        uint256 amountOutMin,
        address tokenIn,
        address tokenOut
    ) external nonReentrant {
        require(amountIn > 0, "Amount must be greater than 0");
        require(tokenIn == token0 || tokenIn == token1, "Invalid tokenIn");
        require(tokenOut == token0 || tokenOut == token1, "Invalid tokenOut");
        require(tokenIn != tokenOut, "Tokens must be different");

        // Transfer tokens from the user
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);

        // Calculate swap amount using the constant product formula
        uint256 amountOut;
        if (tokenIn == token0) {
            amountOut = getAmountOut(amountIn, pool.tickLiquidity[getCurrentTick()], pool.tickLiquidity[getCurrentTick() + 1]);
            require(amountOut >= amountOutMin, "Insufficient output amount");

            // Update reserves (simplified for demonstration)
            pool.tickLiquidity[getCurrentTick()] += uint128(amountIn);
            pool.tickLiquidity[getCurrentTick() + 1] -= uint128(amountOut);
        } else {
            amountOut = getAmountOut(amountIn, pool.tickLiquidity[getCurrentTick()], pool.tickLiquidity[getCurrentTick() - 1]);
            require(amountOut >= amountOutMin, "Insufficient output amount");

            // Update reserves (simplified for demonstration)
            pool.tickLiquidity[getCurrentTick()] += uint128(amountIn);
            pool.tickLiquidity[getCurrentTick() - 1] -= uint128(amountOut);
        }

        // Handle deflationary tokens
        uint256 balanceBefore = IERC20(tokenOut).balanceOf(address(this));
        IERC20(tokenOut).transfer(msg.sender, amountOut);
        uint256 balanceAfter = IERC20(tokenOut).balanceOf(address(this));
        require(balanceAfter >= balanceBefore - amountOut, "Deflationary token detected");

        // Distribute fees
        _updateFees(amountIn, amountOut);

        emit Swap(msg.sender, amountIn, amountOut, tokenIn, tokenOut);
    }

    // Calculate the amount of output tokens using the constant product formula
    function getAmountOut(
        uint256 amountIn,
        uint128 liquidityLower,
        uint128 liquidityUpper
    ) internal pure returns (uint256) {
        require(amountIn > 0, "AmountIn must be greater than 0");
        require(liquidityLower > 0 && liquidityUpper > 0, "Liquidity must be greater than 0");

        // Calculate amountOut with fee
        uint256 amountInWithFee = amountIn * (10000 - fee);
        uint256 numerator = amountInWithFee * uint256(liquidityUpper);
        uint256 denominator = (uint256(liquidityLower) * 10000 + amountInWithFee);
        uint256 amountOut = numerator / denominator;

        return amountOut;
    }

    // Get the current tick (simplified for demonstration)
    function getCurrentTick() internal view returns (int24) {
        return int24(uint24(pool.sqrtPriceX96 >> 96));
    }

    function getLiquidity(address lp) external view returns (uint128 liquidity) {
        Position storage position = pool.positions[lp];
        liquidity = position.liquidity;
    }

    // Distribute fees to liquidity providers
    function _updateFees(uint256 amountIn, uint256 amountOut) internal {
        uint256 feeAmount0 = (amountIn * fee) / 10000;
        uint256 feeAmount1 = (amountOut * fee) / 10000;

        // Distribute fees to LPs based on their liquidity share
        // (Simplified for demonstration)
        pool.tickLiquidity[getCurrentTick()] += uint128(feeAmount0);
        pool.tickLiquidity[getCurrentTick()] += uint128(feeAmount1);
    }
}
