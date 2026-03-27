// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IFlashLoanSimpleReceiver} from "@aave/contracts/flashloan/interfaces/IFlashLoanSimpleReceiver.sol";
import {IPool} from "@aave/contracts/interfaces/IPool.sol";
import {IPoolAddressesProvider} from "@aave/contracts/interfaces/IPoolAddressesProvider.sol";
import {IUniswapV2Router02} from "./interfaces/IUniswapV2Router02.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title Flashswap
/// @notice Executes atomic flash loan arbitrage between two Uniswap V2-compatible DEXes via Aave V3.
/// @dev Implements IFlashLoanSimpleReceiver. Only the owner may initiate flash loans.
contract Flashswap is IFlashLoanSimpleReceiver, Ownable {
    using SafeERC20 for IERC20;

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    error Flashswap__ZeroAddress();
    error Flashswap__Unauthorized();
    error Flashswap__ZeroAmount();
    error Flashswap__InsufficientProfit();

    // -------------------------------------------------------------------------
    // Immutables
    // -------------------------------------------------------------------------

    IPool private immutable i_aavePool;

    // -------------------------------------------------------------------------
    // Structs
    // -------------------------------------------------------------------------

    /// @dev Encoded into `params` for executeOperation to avoid stack-too-deep.
    struct ArbitrageParams {
        address routerFrom;
        address routerTo;
        address tokenIn;  // asset borrowed from Aave (e.g. USDC)
        address tokenOut; // intermediate token (e.g. WETH)
        uint256 minProfit;
    }

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    constructor(address aavePool) Ownable(msg.sender) {
        if (aavePool == address(0)) revert Flashswap__ZeroAddress();
        i_aavePool = IPool(aavePool);
    }

    // -------------------------------------------------------------------------
    // External
    // -------------------------------------------------------------------------

    /// @notice Initiates a flash loan arbitrage. Only callable by owner.
    /// @param asset     The token to borrow from Aave (e.g. USDC).
    /// @param amount    The amount to borrow.
    /// @param routerFrom  DEX router to buy tokenOut (asset becomes cheaper here).
    /// @param routerTo    DEX router to sell tokenOut (asset is more expensive here).
    /// @param tokenOut  The intermediate token to arb through (e.g. WETH).
    /// @param minProfit Minimum profit in `asset` terms, or revert.
    function initiateFlashloan(
        address asset,
        uint256 amount,
        address routerFrom,
        address routerTo,
        address tokenOut,
        uint256 minProfit
    ) external onlyOwner {
        if (asset == address(0) || routerFrom == address(0) || routerTo == address(0) || tokenOut == address(0)) {
            revert Flashswap__ZeroAddress();
        }
        if (amount == 0) revert Flashswap__ZeroAmount();

        // Pre-approve Aave to pull repayment (amount + premium) after executeOperation.
        // type(uint256).max is acceptable here as the contract should hold no persistent funds.
        IERC20(asset).approve(address(i_aavePool), type(uint256).max);

        bytes memory params = abi.encode(ArbitrageParams({
            routerFrom: routerFrom,
            routerTo: routerTo,
            tokenIn: asset,
            tokenOut: tokenOut,
            minProfit: minProfit
        }));

        i_aavePool.flashLoanSimple({
            receiverAddress: address(this),
            asset: asset,
            amount: amount,
            params: params,
            referralCode: 0
        });
    }

    /// @inheritdoc IFlashLoanSimpleReceiver
    /// @dev Called by Aave after funds are deposited. Executes two swaps and verifies profit.
    ///      Aave pulls repayment via transferFrom after this function returns.
    function executeOperation(
        address asset,
        uint256 amount,
        uint256 premium,
        address initiator,
        bytes calldata params
    ) external returns (bool) {
        if (msg.sender != address(i_aavePool)) revert Flashswap__Unauthorized();
        if (initiator != address(this)) revert Flashswap__Unauthorized();

        ArbitrageParams memory arb = abi.decode(params, (ArbitrageParams));

        uint256 repayAmount = amount + premium;

        // Capture pre-arb balance (excluding the flash loaned funds themselves).
        uint256 balanceBefore = IERC20(asset).balanceOf(address(this)) - amount;

        // --- Swap 1: tokenIn → tokenOut on routerFrom ---
        address[] memory pathA = new address[](2);
        pathA[0] = arb.tokenIn;
        pathA[1] = arb.tokenOut;

        IERC20(arb.tokenIn).approve(arb.routerFrom, amount);

        uint256[] memory amountsA = IUniswapV2Router02(arb.routerFrom).swapExactTokensForTokens({
            amountIn: amount,
            amountOutMin: 0,
            path: pathA,
            to: address(this),
            deadline: block.timestamp
        });

        // --- Swap 2: tokenOut → tokenIn on routerTo ---
        address[] memory pathB = new address[](2);
        pathB[0] = arb.tokenOut;
        pathB[1] = arb.tokenIn;

        uint256 tokenOutReceived = amountsA[amountsA.length - 1];
        IERC20(arb.tokenOut).approve(arb.routerTo, tokenOutReceived);

        IUniswapV2Router02(arb.routerTo).swapExactTokensForTokens({
            amountIn: tokenOutReceived,
            amountOutMin: repayAmount + arb.minProfit, // enforce minimum at swap level
            path: pathB,
            to: address(this),
            deadline: block.timestamp
        });

        // --- Profit check ---
        // Aave has not yet pulled repayAmount (happens after this function returns),
        // so we subtract it manually from balanceAfter.
        uint256 balanceAfter = IERC20(asset).balanceOf(address(this));
        if (balanceAfter - repayAmount - balanceBefore < arb.minProfit) {
            revert Flashswap__InsufficientProfit();
        }

        return true;
    }

    // -------------------------------------------------------------------------
    // IFlashLoanSimpleReceiver views
    // -------------------------------------------------------------------------

    /// @inheritdoc IFlashLoanSimpleReceiver
    function ADDRESSES_PROVIDER() external view returns (IPoolAddressesProvider) {
        return i_aavePool.ADDRESSES_PROVIDER();
    }

    /// @inheritdoc IFlashLoanSimpleReceiver
    function POOL() external view returns (IPool) {
        return i_aavePool;
    }

    // -------------------------------------------------------------------------
    // Owner utilities
    // -------------------------------------------------------------------------

    /// @notice Rescue any tokens accidentally left in the contract.
    function rescueTokens(address token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert Flashswap__ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
    }
}
