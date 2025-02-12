// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MinimalDEX {
    struct Pool {
        uint256 ethReserve;
        uint256 tokenReserve;
        uint256 totalSupply;
    }

    mapping(address => Pool) public pools;
    mapping(address => mapping(address => uint256)) public liquidityBalances;

    event LiquidityAdded(
        address indexed provider,
        address indexed token,
        uint256 ethAmount,
        uint256 tokenAmount,
        uint256 liquidity
    );

    event LiquidityRemoved(
        address indexed provider,
        address indexed token,
        uint256 ethAmount,
        uint256 tokenAmount,
        uint256 liquidity
    );

    event Swapped(
        address indexed user,
        address indexed token,
        uint256 amountIn,
        uint256 amountOut
    );

    event TokenSwapped(
        address indexed user,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut
    );

    function addLiquidity(address token, uint256 tokenAmount) external payable {
        require(msg.value > 0, "Must send ETH");
        require(tokenAmount > 0, "Must send tokens");

        Pool storage pool = pools[token];
        uint256 ethAmount = msg.value;

        uint256 tokenBalanceBefore = IERC20(token).balanceOf(address(this));
        IERC20(token).transferFrom(msg.sender, address(this), tokenAmount);
        uint256 tokenBalanceAfter = IERC20(token).balanceOf(address(this));
        uint256 actualTokenAmount = tokenBalanceAfter - tokenBalanceBefore;

        if (pool.totalSupply == 0) {
            uint256 liquidity = sqrt(ethAmount * actualTokenAmount);
            require(liquidity > 0, "Insufficient initial liquidity");
            
            pool.ethReserve = ethAmount;
            pool.tokenReserve = actualTokenAmount;
            pool.totalSupply = liquidity;
            liquidityBalances[msg.sender][token] = liquidity;
        } else {
            uint256 ethReserve = pool.ethReserve;
            uint256 tokenReserve = pool.tokenReserve;
            
            uint256 requiredEth = (actualTokenAmount * ethReserve) / tokenReserve;
            require(ethAmount >= requiredEth, "Insufficient ETH sent");
            
            if (ethAmount > requiredEth) {
                payable(msg.sender).transfer(ethAmount - requiredEth);
            }

            uint256 liquidity = (actualTokenAmount * pool.totalSupply) / tokenReserve;
            require(liquidity > 0, "Insufficient liquidity minted");

            pool.ethReserve += requiredEth;
            pool.tokenReserve += actualTokenAmount;
            pool.totalSupply += liquidity;
            liquidityBalances[msg.sender][token] += liquidity;
        }

        emit LiquidityAdded(msg.sender, token, ethAmount, actualTokenAmount, liquidityBalances[msg.sender][token]);
    }

    function removeLiquidity(address token, uint256 liquidity) external {
        Pool storage pool = pools[token];
        require(liquidityBalances[msg.sender][token] >= liquidity, "Insufficient liquidity");

        uint256 totalSupply = pool.totalSupply;
        uint256 ethAmount = (liquidity * pool.ethReserve) / totalSupply;
        uint256 tokenAmount = (liquidity * pool.tokenReserve) / totalSupply;

        require(ethAmount > 0 && tokenAmount > 0, "Insufficient reserves");

        liquidityBalances[msg.sender][token] -= liquidity;
        pool.totalSupply -= liquidity;
        pool.ethReserve -= ethAmount;
        pool.tokenReserve -= tokenAmount;

        payable(msg.sender).transfer(ethAmount);
        IERC20(token).transfer(msg.sender, tokenAmount);

        emit LiquidityRemoved(msg.sender, token, ethAmount, tokenAmount, liquidity);
    }

    function swapEthForToken(address token, uint256 minTokens) external payable {
        require(msg.value > 0, "Must send ETH");
        Pool storage pool = pools[token];
        require(pool.totalSupply > 0, "Pool does not exist");

        uint256 fee = (msg.value * 3) / 1000;
        uint256 ethAmountLessFee = msg.value - fee;

        uint256 tokenReserve = pool.tokenReserve;
        uint256 tokensOut = (ethAmountLessFee * tokenReserve) / (pool.ethReserve + ethAmountLessFee);

        require(tokensOut >= minTokens, "Insufficient output amount");

        pool.ethReserve += msg.value;
        pool.tokenReserve -= tokensOut;

        IERC20(token).transfer(msg.sender, tokensOut);

        emit Swapped(msg.sender, token, msg.value, tokensOut);
    }

    function swapTokenForEth(address token, uint256 tokenAmount, uint256 minEth) external {
        Pool storage pool = pools[token];
        require(pool.totalSupply > 0, "Pool does not exist");

        uint256 tokenBalanceBefore = IERC20(token).balanceOf(address(this));
        IERC20(token).transferFrom(msg.sender, address(this), tokenAmount);
        uint256 tokenBalanceAfter = IERC20(token).balanceOf(address(this));
        uint256 actualTokenAmount = tokenBalanceAfter - tokenBalanceBefore;

        uint256 fee = (actualTokenAmount * 3) / 1000;
        uint256 tokenAmountLessFee = actualTokenAmount - fee;

        uint256 ethOut = (tokenAmountLessFee * pool.ethReserve) / (pool.tokenReserve + tokenAmountLessFee);
        require(ethOut >= minEth, "Insufficient output amount");

        pool.tokenReserve += actualTokenAmount;
        pool.ethReserve -= ethOut;

        payable(msg.sender).transfer(ethOut);

        emit Swapped(msg.sender, token, actualTokenAmount, ethOut);
    }

    function swapTokenForToken(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut
    ) external {
        require(tokenIn != tokenOut, "Same token");
        Pool storage poolIn = pools[tokenIn];
        Pool storage poolOut = pools[tokenOut];
        require(poolIn.totalSupply > 0 && poolOut.totalSupply > 0, "Pool does not exist");

        // Swap tokenIn to ETH
        uint256 tokenBalanceBefore = IERC20(tokenIn).balanceOf(address(this));
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        uint256 tokenBalanceAfter = IERC20(tokenIn).balanceOf(address(this));
        uint256 actualTokenInAmount = tokenBalanceAfter - tokenBalanceBefore;

        uint256 feeIn = (actualTokenInAmount * 3) / 1000;
        uint256 tokenInAmountLessFee = actualTokenInAmount - feeIn;

        uint256 ethAmount = (tokenInAmountLessFee * poolIn.ethReserve) / 
            (poolIn.tokenReserve + tokenInAmountLessFee);

        poolIn.tokenReserve += actualTokenInAmount;
        poolIn.ethReserve -= ethAmount;

        // Swap ETH to tokenOut
        uint256 feeEth = (ethAmount * 3) / 1000;
        uint256 ethAmountLessFee = ethAmount - feeEth;

        uint256 tokenOutAmount = (ethAmountLessFee * poolOut.tokenReserve) / 
            (poolOut.ethReserve + ethAmountLessFee);

        require(tokenOutAmount >= minAmountOut, "Insufficient output amount");

        poolOut.ethReserve += ethAmount;
        poolOut.tokenReserve -= tokenOutAmount;

        IERC20(tokenOut).transfer(msg.sender, tokenOutAmount);

        emit TokenSwapped(msg.sender, tokenIn, tokenOut, actualTokenInAmount, tokenOutAmount);
    }

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