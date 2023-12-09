// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {FlashLoanSimpleReceiverBase} from "aave/flashloan/base/FlashLoanSimpleReceiverBase.sol";
import {IPoolAddressesProvider} from "aave/interfaces/IPoolAddressesProvider.sol";
import {Comptroller} from "compound-protocol/Comptroller.sol";
import {CToken} from "compound-protocol/CToken.sol";
import {SimplePriceOracle} from "compound-protocol/SimplePriceOracle.sol";
import {CErc20Delegate} from "compound-protocol/CErc20Delegate.sol";
import {CErc20Delegator} from "compound-protocol/CErc20Delegator.sol";
import {CErc20Interface, CTokenInterface} from "compound-protocol/CTokenInterfaces.sol";
import {WhitePaperInterestRateModel} from "compound-protocol/WhitePaperInterestRateModel.sol";
import {Unitroller} from "compound-protocol/Unitroller.sol";
import {ISwapRouter} from '@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol';

contract Arbitrage is FlashLoanSimpleReceiverBase {

    ISwapRouter private swapRouter = ISwapRouter(0xE592427A0AEce92De3Edee1F18E0157C05861564);

    struct Callback {
        // liquidator address
        address owner;
        // the borrower could be liquidated
        address borrower;
        // the cToken borrowed by borrower
        address borrowDelegator;
        // the collateral cToken address
        address collateralDelegator;
    }

    constructor(address _addressProvider)
        FlashLoanSimpleReceiverBase(IPoolAddressesProvider(_addressProvider)){}
    
    function requestFlashLoan(address _token, uint256 _amount, bytes calldata params) public {
        address initiator = address(this);
        address asset = _token;
        uint256 amount = _amount;
        uint16 referralCode = 0;

        // trigger flashloan action
        POOL.flashLoanSimple(
            initiator,
            asset,
            amount,
            params,
            referralCode
        );
    }
    
    function executeOperation(
        address asset,
        uint256 amount,
        uint256 premium,
        address initiator,
        bytes calldata params
    )  external override returns (bool) {
        IERC20 USDC = IERC20(asset);
        IERC20 UNI = IERC20(0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984);

        // check received USDC amount
        require(USDC.balanceOf(address(this)) == amount, "USDC not received");

        // decode the callback data encoded in arbitrage function
        // In this case, 
        // owner: user2
        // borrower: user1
        // borrowDelegator: cUSDC
        // collateralDelegator: cUNI
        Callback memory decode = abi.decode(params, (Callback));

        // approve the amount of USDC borrowed by user1 to cUSDC
        USDC.approve(decode.borrowDelegator, amount);

        // execute the liquidation, which would payback user1 borrowed USDC
        // and receive the user1 collateral asset (cUNI)
        CErc20Interface(decode.borrowDelegator).liquidateBorrow(decode.borrower, amount, CTokenInterface(decode.collateralDelegator));

        // redeem all UNI from cUNI
        CErc20Interface(decode.collateralDelegator).redeem(IERC20(decode.collateralDelegator).balanceOf(address(this)));

        // get the amount of UNI 
        uint256 UNIBalance = UNI.balanceOf(address(this));

        // approve all UNI to uniswap v3 router
        UNI.approve(address(swapRouter), UNIBalance);
        // swap all UNI for USDC
        ISwapRouter.ExactInputSingleParams memory swapParams =
        ISwapRouter.ExactInputSingleParams({
            tokenIn: address(UNI),
            tokenOut: address(USDC),
            fee: 3000, // 0.3%
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: UNIBalance,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });

        // get the amount of USDC after swap
        uint256 amountOut = swapRouter.exactInputSingle(swapParams);
        
        // calculate the total amount of USDC need to payback for aave loan
        uint256 totalAmount = amount + premium;

        // transfer benefit of USDC back to user2
        USDC.transfer(decode.owner, amountOut - totalAmount);

        // approve aave loan fee
        USDC.approve(address(POOL), totalAmount);

        return true;
        // aave pool would take the loan fee from this contract
    }
}

contract LiquidationTest is Test {
    address public owner;
    address public user1;
    address public user2;
    IERC20 public USDC;
    IERC20 public UNI;
    uint256 public USDCDecimal;
    uint256 public UNIDecimal;
    SimplePriceOracle public oracle;
    Comptroller public comptrollerProxy;
    CErc20Delegator public USDCDelegator;
    CErc20Delegator public UNIDelegator;

    // constant variable use to calculate benefit
    uint256 public constant expScale = 1e18;
    uint256 public constant protocolSeizeShareMantissa = 2.8e16;

    struct Callback {
        address owner;
        address borrower;
        address borrowDelegator;
        address collateralDelegator;
    }

    function setUp() public {
        // Fork Ethereum mainnet at block 17465000
        uint256 forkId = vm.createFork(vm.envString("ALCHEMY_RPC_URL"));
        vm.selectFork(forkId);
        vm.rollFork(17465000);

        // setup test account
        owner = makeAddr("owner");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");

        vm.startPrank(owner);

        // setup token USDC, UNI
        USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
        UNI = IERC20(0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984);
        USDCDecimal = IERC20Metadata(address(USDC)).decimals();
        UNIDecimal = IERC20Metadata(address(UNI)).decimals();

        WhitePaperInterestRateModel model = new WhitePaperInterestRateModel(0, 0);
        // deploy oracle contract
        oracle = new SimplePriceOracle();
        // deploy comptroller contract
        Comptroller comptroller = new Comptroller();
        // deploy USDC, UNI cErc20 delegate contract
        CErc20Delegate USDCDelegate = new CErc20Delegate();
        CErc20Delegate UNIDelegate = new CErc20Delegate();

        // deploy unitroller contract
        Unitroller unitroller = new Unitroller();
        // set delegator implementation contract for unitroller
        unitroller._setPendingImplementation(address(comptroller));
        // accept implementation
        comptroller._become(unitroller);
        comptrollerProxy = Comptroller(address(unitroller));

        // deploy USDC, UNI delegator contract
        // with 18 decimals and 1:1 exchange rate
        // exchange rate decimal precision: 
        // expScale * (1 * 10 ** underlying decimal) / (1* 10 ** cToken decimal)
        USDCDelegator = new CErc20Delegator(
            address(USDC),
            comptrollerProxy,
            model,
            // 1e18 * (10 ** USDCDecimal) / 1e18
            10 ** USDCDecimal,
            "compound USDC",
            "cUSDC",
            18,
            payable(msg.sender),
            address(USDCDelegate),
            ""
        );
        UNIDelegator = new CErc20Delegator(
            address(UNI),
            comptrollerProxy,
            model,
            // 1e18 * (10 ** UNIDecimal) / 1e18
            10 ** UNIDecimal,
            "compound UNI",
            "cUNI",
            18,
            payable(msg.sender),
            address(UNIDelegate),
            ""
        );

        // set oracle contract for comptroller
        comptrollerProxy._setPriceOracle(oracle);
        // add tokens into the lending market
        comptrollerProxy._supportMarket(CToken(address(USDCDelegator)));
        comptrollerProxy._supportMarket(CToken(address(UNIDelegator)));
        // set tokens close factor 50%
        comptrollerProxy._setCloseFactor(0.5e18);
        // set tokens liquidation incentive 8%
        comptrollerProxy._setLiquidationIncentive(1.08e18);
        // set USDC price $1, UNI price $5
        // price decimal precision:
        // expScale * (1* 10 ** cToken decimal) / (1 * 10 ** underlying decimal)
        // which can represent 18 + "cToken decimal" - "underlying decimal"
        // in my case, cToken decimal is setted to 18
        // so the formula would be 36 - "underlying decimal"
        oracle.setDirectPrice(address(USDC), 1 * 10 ** (36 - USDCDecimal));
        oracle.setDirectPrice(address(UNI), 5 * 10 ** (36 - UNIDecimal));
        // set UNI collateral factor 50%
        comptrollerProxy._setCollateralFactor(CToken(address(UNIDelegator)), 0.5e18);
        comptrollerProxy._setCollateralFactor(CToken(address(USDCDelegator)), 0.5e18);

        // provide some UNI, USDC for liquidity pool
        uint256 USDCBasicLiquidity = 10000 * 10 ** USDCDecimal;
        uint256 UNIBasicLiquidity = 10000 * 10 ** UNIDecimal;
        deal(address(USDC), owner, USDCBasicLiquidity);
        deal(address(UNI), owner, UNIBasicLiquidity);
        USDC.approve(address(USDCDelegator), USDCBasicLiquidity);
        UNI.approve(address(UNIDelegator), UNIBasicLiquidity);
        USDCDelegator.mint(USDCBasicLiquidity);
        UNIDelegator.mint(UNIBasicLiquidity);
        address[] memory cTokens = new address[](2);
        cTokens[0] = address(USDCDelegator);
        cTokens[1] = address(UNIDelegator);
        comptrollerProxy.enterMarkets(cTokens);

        // (, uint liquidity, uint shortfall) = comptrollerProxy.getAccountLiquidity(owner);
        vm.stopPrank();
    }

    function testLiquidation() public {
        vm.startPrank(user1);
        
        uint256 mintAmount = 1000 * 10 ** UNIDecimal;
        uint256 borrowAmount = 2500 * 10 ** USDCDecimal;
        // deal 1000 UNI for user1
        deal(address(UNI), user1, mintAmount);
        // collateral 1000 UNI for cUNI
        UNI.approve(address(UNIDelegator), mintAmount);
        UNIDelegator.mint(mintAmount);
        // enter UNI market
        address[] memory cTokens = new address[](1);
        cTokens[0] = address(UNIDelegator);
        comptrollerProxy.enterMarkets(cTokens);
        // borrow 2500 USDC
        USDCDelegator.borrow(borrowAmount);
        vm.stopPrank();

        // set UNI price as $4
        oracle.setDirectPrice(address(UNI), 4 * 10 ** (36 - UNIDecimal));

        vm.startPrank(user2);

        // calculate the shortfall of user1 collaterals
        (, , uint shortfall) = comptrollerProxy.getAccountLiquidity(user1);

        // define parameters used for liquidation contract
        Callback memory data = Callback(user2, user1, address(USDCDelegator), address(UNIDelegator));

        // get the pool address provider from following links
        // https://docs.aave.com/developers/deployed-contracts/v3-mainnet/ethereum-mainnet
        // initialize liquidation contract
        Arbitrage arbitrage = new Arbitrage(0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e);

        // shortfall is used compound expScale decimal precision
        // convert decimal precision to USDC decimal
        uint256 flashloanAmount = shortfall * 10 ** USDCDecimal / 1e18;

        // trigger liquidation contract, which can perform a flashloan from aave
        // and execute liquidation to user1 and transfer benefit back to user2
        arbitrage.requestFlashLoan(address(USDC), flashloanAmount, abi.encode(data));

        // ensure liquidation contract has no asset
        assertEq(UNI.balanceOf(address(arbitrage)), 0);
        assertEq(USDC.balanceOf(address(arbitrage)), 0);
        assertEq(IERC20(address(UNIDelegator)).balanceOf(address(arbitrage)), 0);
        assertEq(IERC20(address(USDCDelegator)).balanceOf(address(arbitrage)), 0);

        // ensure user2 has benefit after liquidation
        assertGt(USDC.balanceOf(user2), 0);
        vm.stopPrank();
    }
}