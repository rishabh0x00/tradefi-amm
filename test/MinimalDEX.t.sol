// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../src/MinimalDEX.sol";

contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }
}

contract MinimalDEXTest is Test {
    MinimalDEX dex;
    MockERC20 tokenA;
    MockERC20 tokenB;
    address user1 = address(0x1);
    address user2 = address(0x2);

    function setUp() public {
        dex = new MinimalDEX();
        tokenA = new MockERC20("TokenA", "TA");
        tokenB = new MockERC20("TokenB", "TB");

        // Mint tokens to users
        tokenA.mint(user1, 1000 ether);
        tokenA.mint(user2, 1000 ether);
        tokenB.mint(user1, 1000 ether);
        tokenB.mint(user2, 1000 ether);
        vm.deal(user1, 1000 ether);
        vm.deal(user2, 1000 ether);
    }

    // Helper function to calculate square root
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

    // Unit Tests

    function testAddLiquidity() public {
        vm.startPrank(user1);
        tokenA.approve(address(dex), 100 ether);
        dex.addLiquidity{value: 100 ether}(address(tokenA), 100 ether);
        vm.stopPrank();

        (uint256 ethReserve, uint256 tokenReserve, uint256 totalSupply) = dex.pools(address(tokenA));
        assertEq(ethReserve, 100 ether);
        assertEq(tokenReserve, 100 ether);
        assertEq(totalSupply, sqrt(100 ether * 100 ether));
    }

    function testRemoveLiquidity() public {
        vm.startPrank(user1);
        tokenA.approve(address(dex), 100 ether);
        dex.addLiquidity{value: 100 ether}(address(tokenA), 100 ether);
        dex.removeLiquidity(address(tokenA), dex.liquidityBalances(user1, address(tokenA)));
        vm.stopPrank();

        (uint256 ethReserve, uint256 tokenReserve, uint256 totalSupply) = dex.pools(address(tokenA));
        assertEq(ethReserve, 0);
        assertEq(tokenReserve, 0);
        assertEq(totalSupply, 0);
    }

    function testSwapEthForToken() public {
        vm.startPrank(user1);
        tokenA.approve(address(dex), 100 ether);
        dex.addLiquidity{value: 100 ether}(address(tokenA), 100 ether);
        vm.stopPrank();

        (uint256 currentEthReserve, uint256 currentTokenReserve, ) = dex.pools(address(tokenA));
        uint256 expectedFees = (10 ether * 3) / 1000;
        uint256 netEthDeposit = 10 ether - expectedFees;
        uint256 expectedTokensOut = (netEthDeposit * currentTokenReserve) / (currentEthReserve + netEthDeposit);

        vm.startPrank(user2);
        dex.swapEthForToken{value: 10 ether}(address(tokenA), 0);
        vm.stopPrank();

        (uint256 actualEthReserve, uint256 actualTokenReserve, ) = dex.pools(address(tokenA));

        assertEq(actualEthReserve, currentEthReserve + 10 ether);
        assertEq(actualTokenReserve, currentTokenReserve - expectedTokensOut); // Adjusted for fees
    }

    function testSwapTokenForEth() public {
        vm.startPrank(user1);
        tokenA.approve(address(dex), 100 ether);
        dex.addLiquidity{value: 100 ether}(address(tokenA), 100 ether);
        vm.stopPrank();

        (uint256 currentEthReserve, uint256 currentTokenReserve, ) = dex.pools(address(tokenA));
        uint256 expectedFee = (10 ether * 3) / 1000;
        uint256 netTokenDeposit = 10 ether - expectedFee;
        uint256 expectedEthOut = (currentEthReserve * netTokenDeposit) / (currentTokenReserve + netTokenDeposit);

        vm.startPrank(user2);
        tokenA.approve(address(dex), 10 ether);
        dex.swapTokenForEth(address(tokenA), 10 ether, 0);
        vm.stopPrank();

        (uint256 actualEthReserve, uint256 actualTokenReserve, ) = dex.pools(address(tokenA));
        assertEq(actualTokenReserve, currentTokenReserve + 10 ether); 
        assertEq(actualEthReserve, currentEthReserve - expectedEthOut); // Adjusted for fees
    }

    function testSwapTokenForToken() public {
        vm.startPrank(user1);
        tokenA.approve(address(dex), 100 ether);
        dex.addLiquidity{value: 100 ether}(address(tokenA), 100 ether);
        tokenB.approve(address(dex), 100 ether);
        dex.addLiquidity{value: 100 ether}(address(tokenB), 100 ether);
        vm.stopPrank();

        (uint256 currentEthReserveA, uint256 currentTokenReserveA, ) = dex.pools(address(tokenA));
        (uint256 currentEthReserveB, uint256 currentTokenReserveB, ) = dex.pools(address(tokenB));

        uint256 expectedFeesIn = (10 ether * 3) / 1000;
        uint256 expectedEthInAmount = ((10 ether - expectedFeesIn) * currentEthReserveA ) / (currentTokenReserveA + 10 ether - expectedFeesIn);
        uint256 expectedTokensOut = ((expectedEthInAmount * (1000 - 3)) / 1000 * currentTokenReserveB) / (currentEthReserveB + ((expectedEthInAmount * (1000 - 3)) / 1000));

        vm.startPrank(user2);
        tokenA.approve(address(dex), 10 ether);
        dex.swapTokenForToken(address(tokenA), address(tokenB), 10 ether, 0);
        vm.stopPrank();


        (uint256 actualEthReserveA, uint256 actualTokenReserveA, ) = dex.pools(address(tokenA));
        (uint256 actualEthReserveB, uint256 actualTokenReserveB, ) = dex.pools(address(tokenB));

        assertEq(actualEthReserveB, currentEthReserveB + expectedEthInAmount);
        assertEq(actualEthReserveA, currentEthReserveA - expectedEthInAmount);
        assertEq(actualTokenReserveB, currentTokenReserveB - expectedTokensOut);
        assertEq(actualTokenReserveA, currentTokenReserveA + 10 ether); // Adjusted for fees
    }

    function testMultipleUsersAddLiquidity() public {
        vm.startPrank(user1);
        tokenA.approve(address(dex), 100 ether);
        dex.addLiquidity{value: 100 ether}(address(tokenA), 100 ether);
        vm.stopPrank();

        vm.startPrank(user2);
        tokenA.approve(address(dex), 50 ether);
        dex.addLiquidity{value: 50 ether}(address(tokenA), 50 ether);
        vm.stopPrank();

        (uint256 ethReserve, uint256 tokenReserve, uint256 totalSupply) = dex.pools(address(tokenA));
        assertEq(ethReserve, 150 ether);
        assertEq(tokenReserve, 150 ether);
        assertEq(totalSupply, sqrt(100 ether * 100 ether) + sqrt(50 ether * 50 ether));
    }

    // Fuzzing Tests

    function testFuzzAddLiquidity(uint256 ethAmount, uint256 tokenAmount) public {
        vm.assume(ethAmount > 0 && ethAmount <= 1000 ether);
        vm.assume(tokenAmount > 0 && tokenAmount <= 1000 ether);

        vm.startPrank(user1);
        tokenA.approve(address(dex), tokenAmount);
        dex.addLiquidity{value: ethAmount}(address(tokenA), tokenAmount);
        vm.stopPrank();

        (uint256 ethReserve, uint256 tokenReserve, uint256 totalSupply) = dex.pools(address(tokenA));
        assertEq(ethReserve, ethAmount);
        assertEq(tokenReserve, tokenAmount);
        assertEq(totalSupply, sqrt(ethAmount * tokenAmount));
    }

    // 100% Coverage Tests

    function testRevertAddLiquidityZeroETH() public {
        vm.startPrank(user1);
        tokenA.approve(address(dex), 100 ether);
        vm.expectRevert("Must send ETH");
        dex.addLiquidity{value: 0}(address(tokenA), 100 ether);
        vm.stopPrank();
    }

    function testRevertAddLiquidityZeroTokens() public {
        vm.startPrank(user1);
        tokenA.approve(address(dex), 0);
        vm.expectRevert("Must send tokens");
        dex.addLiquidity{value: 100 ether}(address(tokenA), 0);
        vm.stopPrank();
    }

    function testRevertSwapEthForTokenNoPool() public {
        vm.startPrank(user1);
        vm.expectRevert("Pool does not exist");
        dex.swapEthForToken{value: 10 ether}(address(tokenA), 0);
        vm.stopPrank();
    }

    function testRevertSwapTokenForEthNoPool() public {
        vm.startPrank(user1);
        vm.expectRevert("Pool does not exist");
        dex.swapTokenForEth(address(tokenA), 10 ether, 0);
        vm.stopPrank();
    }

    function testRevertSwapTokenForTokenNoPool() public {
        vm.startPrank(user1);
        vm.expectRevert("Pool does not exist");
        dex.swapTokenForToken(address(tokenA), address(tokenB), 10 ether, 0);
        vm.stopPrank();
    }
}