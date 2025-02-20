// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

/// @title MinimalDEX
/// @notice A minimal decentralized exchange implementing core DEX functionality with liquidity pools and configurable swap fees
/// @dev Uses OpenZeppelin's ReentrancyGuard to prevent reentrant calls and AccessControl for role-based permissions
contract MinimalDEX is ReentrancyGuard, AccessControl {
    using SafeERC20 for IERC20;

    /// @dev Maximum fee in thousandths. 1000 => 100%
    uint256 public constant MAX_FEE_THOUSANDTHS = 1000;

    /// @notice Fee in thousandths. e.g. if fee=3, that's 3/1000 = 0.3%
    uint256 public fee;

    /// @dev Represents a liquidity pool for a specific ERC20 token
    /// @param ethReserve ETH reserve amount in the pool
    /// @param tokenReserve ERC20 token reserve amount in the pool
    /// @param totalSupply Total supply of liquidity provider (LP) tokens
    struct Pool {
        uint256 ethReserve;
        uint256 tokenReserve;
        uint256 totalSupply;
    }

    mapping(address => Pool) public pools; // Mapping of ERC20 token addresses to their corresponding liquidity pools
    mapping(address => mapping(address => uint256)) public liquidityBalances; // Mapping tracking LP token balances of users for each pool

    /// @notice Emitted when the fee is updated
    event FeeUpdated(uint256 newFee);

    // Emitted when liquidity is added to a pool
    event LiquidityAdded(
        address indexed provider,
        address indexed token,
        uint256 ethAmount,
        uint256 tokenAmount,
        uint256 liquidity
    );

    // Emitted when liquidity is removed from a pool
    event LiquidityRemoved(
        address indexed provider,
        address indexed token,
        uint256 ethAmount,
        uint256 tokenAmount,
        uint256 liquidity
    );

    // Emitted when a ETH/token swap occurs
    event Swapped(
        address indexed user,
        address indexed token,
        uint256 amountIn,
        uint256 amountOut
    );

    // Emitted when a token-to-token swap occurs
    event TokenSwapped(
        address indexed user,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut
    );

    /// @notice Sets the initial fee and grants DEFAULT_ADMIN_ROLE to msg.sender.
    /// @param _fee Fee in thousandths (e.g. 3 = 0.3%)
    constructor(uint256 _fee) {
        require(_fee <= MAX_FEE_THOUSANDTHS, "Fee must not exceed 100%");
        fee = _fee;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        emit FeeUpdated(_fee);
    }

    /// @notice Updates the fee (in thousandths). Only accounts with DEFAULT_ADMIN_ROLE can update the fee.
    function setFee(uint256 _fee) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_fee <= MAX_FEE_THOUSANDTHS, "Fee must not exceed 100%");
        fee = _fee;
        emit FeeUpdated(_fee);
    }

    /// @notice Adds liquidity to a pool by depositing ETH and ERC20 tokens
    /// @dev Initial liquidity mints LP tokens using geometric mean, subsequent deposits proportional to reserves
    /// @param token ERC20 token address for the pool
    /// @param tokenAmount Amount of tokens intended to deposit (actual may differ due to transfer fees)
    function addLiquidity(
        address token,
        uint256 tokenAmount
    ) external payable nonReentrant {
        require(msg.value > 0, "Must send ETH");
        require(tokenAmount > 0, "Must send tokens");

        Pool storage pool = pools[token];
        uint256 ethAmount = msg.value;

        uint256 tokenBalanceBefore = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), tokenAmount);
        uint256 tokenBalanceAfter = IERC20(token).balanceOf(address(this));
        uint256 actualTokenAmount = tokenBalanceAfter - tokenBalanceBefore;

        if (pool.totalSupply == 0) {
            // First liquidity
            uint256 liquidity = sqrt(ethAmount * actualTokenAmount);
            pool.ethReserve = ethAmount;
            pool.tokenReserve = actualTokenAmount;
            pool.totalSupply = liquidity;
            liquidityBalances[msg.sender][token] = liquidity;
        } else {
            // Subsequent liquidity
            uint256 ethReserve = pool.ethReserve;
            uint256 tokenReserve = pool.tokenReserve;

            uint256 requiredEth = (actualTokenAmount * ethReserve) / tokenReserve;
            require(ethAmount >= requiredEth, "Insufficient ETH sent");

            if (ethAmount > requiredEth) {
                (bool success, ) = payable(msg.sender).call{
                    value: ethAmount - requiredEth
                }("");
                require(success, "ETH transfer failed");
                ethAmount = requiredEth;
            }

            uint256 liquidity = (actualTokenAmount * pool.totalSupply) / tokenReserve;
            require(liquidity > 0, "Insufficient liquidity minted");

            pool.ethReserve += ethAmount;
            pool.tokenReserve += actualTokenAmount;
            pool.totalSupply += liquidity;
            liquidityBalances[msg.sender][token] += liquidity;
        }

        emit LiquidityAdded(
            msg.sender,
            token,
            ethAmount,
            actualTokenAmount,
            liquidityBalances[msg.sender][token]
        );
    }

    /// @notice Removes liquidity from a pool, withdrawing proportional ETH and tokens
    /// @dev Burns LP tokens and returns proportional share of reserves
    /// @param token ERC20 token address of the pool
    /// @param liquidity Amount of LP tokens to burn
    function removeLiquidity(
        address token,
        uint256 liquidity
    ) external nonReentrant {
        Pool storage pool = pools[token];
        require(
            liquidityBalances[msg.sender][token] >= liquidity,
            "Insufficient liquidity"
        );

        uint256 totalSupply = pool.totalSupply;
        uint256 ethAmount = (liquidity * pool.ethReserve) / totalSupply;
        uint256 tokenAmount = (liquidity * pool.tokenReserve) / totalSupply;

        require(ethAmount > 0 && tokenAmount > 0, "Insufficient reserves");

        liquidityBalances[msg.sender][token] -= liquidity;
        pool.totalSupply -= liquidity;
        pool.ethReserve -= ethAmount;
        pool.tokenReserve -= tokenAmount;

        (bool success, ) = payable(msg.sender).call{value: ethAmount}("");
        require(success, "ETH transfer failed");
        IERC20(token).safeTransfer(msg.sender, tokenAmount);

        emit LiquidityRemoved(
            msg.sender,
            token,
            ethAmount,
            tokenAmount,
            liquidity
        );
    }

    /// @notice Swap ETH for ERC20 tokens using the current fee
    /// @dev Input ETH amount must be >0, output calculated from pool reserves
    /// @param token ERC20 token address to receive
    /// @param minTokens Minimum tokens to receive (slippage protection)
    function swapEthForToken(
        address token,
        uint256 minTokens
    ) external payable nonReentrant {
        require(msg.value > 0, "Must send ETH");
        Pool storage pool = pools[token];
        require(pool.totalSupply > 0, "Pool does not exist");

        // Deduct fee
        uint256 feeAmount = (msg.value * fee) / MAX_FEE_THOUSANDTHS;
        uint256 ethAmountLessFee = msg.value - feeAmount;

        uint256 tokenReserve = pool.tokenReserve;
        // Standard AMM formula: out = (ΔX * Y_reserve) / (X_reserve + ΔX)
        uint256 tokensOut = (ethAmountLessFee * tokenReserve) /
            (pool.ethReserve + ethAmountLessFee);

        require(tokensOut >= minTokens, "Insufficient output amount");

        pool.ethReserve += msg.value;
        pool.tokenReserve -= tokensOut;

        IERC20(token).safeTransfer(msg.sender, tokensOut);

        emit Swapped(msg.sender, token, msg.value, tokensOut);
    }

    /// @notice Swap ERC20 tokens for ETH using the current fee
    /// @dev Input token amount must be >0, output calculated from pool reserves
    /// @param token ERC20 token address to sell
    /// @param tokenAmount Amount of tokens to sell
    /// @param minEth Minimum ETH to receive (slippage protection)
    function swapTokenForEth(
        address token,
        uint256 tokenAmount,
        uint256 minEth
    ) external nonReentrant {
        Pool storage pool = pools[token];
        require(pool.totalSupply > 0, "Pool does not exist");

        uint256 tokenBalanceBefore = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), tokenAmount);
        uint256 tokenBalanceAfter = IERC20(token).balanceOf(address(this));
        uint256 actualTokenAmount = tokenBalanceAfter - tokenBalanceBefore;

        // Deduct fee
        uint256 feeAmount = (actualTokenAmount * fee) / MAX_FEE_THOUSANDTHS;
        uint256 tokenAmountLessFee = actualTokenAmount - feeAmount;

        // Standard AMM formula: out = (ΔY * X_reserve) / (Y_reserve + ΔY)
        uint256 ethOut = (tokenAmountLessFee * pool.ethReserve) /
            (pool.tokenReserve + tokenAmountLessFee);
        require(ethOut >= minEth, "Insufficient output amount");

        pool.tokenReserve += actualTokenAmount;
        pool.ethReserve -= ethOut;

        (bool success, ) = payable(msg.sender).call{value: ethOut}("");
        require(success, "ETH transfer failed");

        emit Swapped(msg.sender, token, actualTokenAmount, ethOut);
    }

    /// @notice Swap between two ERC20 tokens using ETH as an intermediary
    /// @dev Executes two consecutive swaps (tokenIn->ETH and ETH->tokenOut), each with the current fee
    /// @param tokenIn ERC20 token address to sell
    /// @param tokenOut ERC20 token address to buy
    /// @param amountIn Amount of tokenIn to sell
    /// @param minAmountOut Minimum tokenOut to receive (slippage protection)
    function swapTokenForToken(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut
    ) external nonReentrant {
        require(tokenIn != tokenOut, "Same token");

        Pool storage poolIn = pools[tokenIn];
        Pool storage poolOut = pools[tokenOut];
        require(
            poolIn.totalSupply > 0 && poolOut.totalSupply > 0,
            "Pool does not exist"
        );

        // Step 1: tokenIn -> ETH
        uint256 tokenBalanceBefore = IERC20(tokenIn).balanceOf(address(this));
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        uint256 actualTokenInAmount = IERC20(tokenIn).balanceOf(address(this)) -
            tokenBalanceBefore;

        // Fee on the first swap
        uint256 feeIn = (actualTokenInAmount * fee) / MAX_FEE_THOUSANDTHS;
        uint256 tokenInAmountLessFee = actualTokenInAmount - feeIn;

        uint256 ethAmount = (tokenInAmountLessFee * poolIn.ethReserve) /
            (poolIn.tokenReserve + tokenInAmountLessFee);
        poolIn.tokenReserve += actualTokenInAmount;
        poolIn.ethReserve -= ethAmount;

        // Step 2: ETH -> tokenOut (with second fee)
        uint256 ethAmountLessFeeOut = (ethAmount * (MAX_FEE_THOUSANDTHS - fee)) /
            MAX_FEE_THOUSANDTHS;

        uint256 tokenOutAmount = (ethAmountLessFeeOut * poolOut.tokenReserve) /
            (poolOut.ethReserve + ethAmountLessFeeOut);
        require(tokenOutAmount >= minAmountOut, "Insufficient output amount");

        poolOut.ethReserve += ethAmount;
        poolOut.tokenReserve -= tokenOutAmount;

        IERC20(tokenOut).safeTransfer(msg.sender, tokenOutAmount);

        emit TokenSwapped(
            msg.sender,
            tokenIn,
            tokenOut,
            actualTokenInAmount,
            tokenOutAmount
        );
    }

    /// @dev Babylonian square root implementation for initial liquidity calculation
    /// @param y Number to calculate square root of
    /// @return z Calculated square root
    function sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }
}
