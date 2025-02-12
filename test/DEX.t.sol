// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "../src/DEX.sol";

contract DEXTest is Test {
    DEX public pool;
    address public token0;
    address public token1;
    address public lp1 = address(0x1);
    address public lp2 = address(0x2);
    address public swapper = address(0x3);

    function setUp() public {
        // Deploy mock ERC20 tokens
        token0 = address(new MockERC20("Token0", "TKN0"));
        token1 = address(new MockERC20("Token1", "TKN1"));

        // Deploy the pool
        pool = new DEX(token0, token1);

        // Mint tokens to LPs and swapper
        MockERC20(token0).mint(lp1, 1000 ether);
        MockERC20(token1).mint(lp1, 1000 ether);
        MockERC20(token0).mint(lp2, 1000 ether);
        MockERC20(token1).mint(lp2, 1000 ether);
        MockERC20(token0).mint(swapper, 1000 ether);
        MockERC20(token1).mint(swapper, 1000 ether);
    }

    // Test adding liquidity
    function testAddLiquidity() public {
        vm.startPrank(lp1);
        MockERC20(token0).approve(address(pool), 100 ether);
        MockERC20(token1).approve(address(pool), 100 ether);
        pool.addLiquidity(100 ether, 100 ether, -100, 100);
        vm.stopPrank();

        // Check LP's position
        uint128 liquidity = pool.getLiquidity(lp1);
        assertEq(liquidity, 100 ether);
    }

    // Test removing liquidity
    function testRemoveLiquidity() public {
        vm.startPrank(lp1);
        MockERC20(token0).approve(address(pool), 100 ether);
        MockERC20(token1).approve(address(pool), 100 ether);
        pool.addLiquidity(100 ether, 100 ether, -100, 100);
        pool.removeLiquidity(-100, 100);
        vm.stopPrank();

        // Check LP's position
        uint128 liquidity = pool.getLiquidity(lp1);
        assertEq(liquidity, 0);
    }

    // Test swapping token0 for token1
    function testSwapToken0ForToken1() public {
        // Add liquidity first
        vm.startPrank(lp1);
        MockERC20(token0).approve(address(pool), 100 ether);
        MockERC20(token1).approve(address(pool), 100 ether);
        pool.addLiquidity(100 ether, 100 ether, -100, 100);
        vm.stopPrank();

        // Perform swap
        vm.startPrank(swapper);
        MockERC20(token0).approve(address(pool), 10 ether);
        pool.swap(10 ether, 9 ether, token0, token1);
        vm.stopPrank();

        // Check swapper's balance
        assertEq(MockERC20(token1).balanceOf(swapper), 9 ether);
    }

    // Test swapping token1 for token0
    function testSwapToken1ForToken0() public {
        // Add liquidity first
        vm.startPrank(lp1);
        MockERC20(token0).approve(address(pool), 100 ether);
        MockERC20(token1).approve(address(pool), 100 ether);
        pool.addLiquidity(100 ether, 100 ether, -100, 100);
        vm.stopPrank();

        // Perform swap
        vm.startPrank(swapper);
        MockERC20(token1).approve(address(pool), 10 ether);
        pool.swap(10 ether, 9 ether, token1, token0);
        vm.stopPrank();

        // Check swapper's balance
        assertEq(MockERC20(token0).balanceOf(swapper), 9 ether);
    }

    // Test edge case: swapping with insufficient liquidity
    function testSwapInsufficientLiquidity() public {
        // Add liquidity first
        vm.startPrank(lp1);
        MockERC20(token0).approve(address(pool), 100 ether);
        MockERC20(token1).approve(address(pool), 100 ether);
        pool.addLiquidity(100 ether, 100 ether, -100, 100);
        vm.stopPrank();

        // Attempt swap with insufficient liquidity
        vm.startPrank(swapper);
        MockERC20(token0).approve(address(pool), 1000 ether);
        vm.expectRevert("Insufficient output amount");
        pool.swap(1000 ether, 900 ether, token0, token1);
        vm.stopPrank();
    }

    // Test edge case: adding liquidity with invalid tick range
    function testAddLiquidityInvalidTickRange() public {
        vm.startPrank(lp1);
        MockERC20(token0).approve(address(pool), 100 ether);
        MockERC20(token1).approve(address(pool), 100 ether);
        vm.expectRevert("Invalid tick range");
        pool.addLiquidity(100 ether, 100 ether, 100, -100);
        vm.stopPrank();
    }

    // Test edge case: removing liquidity with no position
    function testRemoveLiquidityNoPosition() public {
        vm.startPrank(lp1);
        vm.expectRevert("No liquidity to remove");
        pool.removeLiquidity(-100, 100);
        vm.stopPrank();
    }

    // Test edge case: swapping with deflationary tokens
    function testSwapWithDeflationaryToken() public {
        // Deploy a deflationary token
        address deflationaryToken = address(new MockDeflationaryERC20("DeflationaryToken", "DFT"));

        // Add liquidity with deflationary token
        vm.startPrank(lp1);
        MockERC20(token0).approve(address(pool), 100 ether);
        MockERC20(deflationaryToken).approve(address(pool), 100 ether);
        pool.addLiquidity(100 ether, 100 ether, -100, 100);
        vm.stopPrank();

        // Perform swap
        vm.startPrank(swapper);
        MockERC20(token0).approve(address(pool), 10 ether);
        vm.expectRevert("Deflationary token detected");
        pool.swap(10 ether, 9 ether, token0, deflationaryToken);
        vm.stopPrank();
    }
}

// Mock ERC20 token for testing
contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function mint(address to, uint256 amount) public {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) public returns (bool) {
        return true;
    }

    function transfer(address to, uint256 amount) public virtual returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public virtual returns (bool) {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

// Mock deflationary ERC20 token for testing
contract MockDeflationaryERC20 is MockERC20 {
    constructor(string memory _name, string memory _symbol) MockERC20(_name, _symbol) {}

    function transfer(address to, uint256 amount) public override returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount - 1; // Simulate deflationary behavior
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        balanceOf[from] -= amount;
        balanceOf[to] += amount - 1; // Simulate deflationary behavior
        return true;
    }
}
