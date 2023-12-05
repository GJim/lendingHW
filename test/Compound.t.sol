// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Comptroller} from "compound-protocol/Comptroller.sol";
import {CToken} from "compound-protocol/CToken.sol";
import {SimplePriceOracle} from "compound-protocol/SimplePriceOracle.sol";
import {CErc20Delegate} from "compound-protocol/CErc20Delegate.sol";
import {CErc20Delegator} from "compound-protocol/CErc20Delegator.sol";
import {WhitePaperInterestRateModel} from "compound-protocol/WhitePaperInterestRateModel.sol";
import {Unitroller} from "compound-protocol/Unitroller.sol";
import {CErc20Interface, CTokenInterface} from "compound-protocol/CTokenInterfaces.sol";

contract Token is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}
}

contract CompoundTest is Test {
    address public owner;
    address public user1;
    address public user2;
    Token public tka;
    Token public tkb;
    SimplePriceOracle public oracle;
    Comptroller public comptrollerProxy;
    CErc20Delegator public delegator;
    CErc20Delegator public delegatorB;
    // constant variable use to calculate benefit
    uint256 public expScale = 1e18;
    uint256 public protocolSeizeShareMantissa = 2.8e16;

    function setUp() public {
        owner = makeAddr("owner");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        vm.startPrank(owner);
        // deploy underlying token contract
        tka = new Token("token A", "TKA");
        // deploy interest rate model contract, which borrow rate is 0
        WhitePaperInterestRateModel model = new WhitePaperInterestRateModel(0, 0);
        // deploy oracle contract
        oracle = new SimplePriceOracle();
        // deploy comptroller contract
        Comptroller comptroller = new Comptroller();
        // deploy cErc20 delegate contract
        CErc20Delegate delegate = new CErc20Delegate();
        
        // deploy unitroller contract
        Unitroller unitroller = new Unitroller();
        // set delegator implementation contract for unitroller
        unitroller._setPendingImplementation(address(comptroller));
        // accept implementation
        comptroller._become(unitroller);
        comptrollerProxy = Comptroller(address(unitroller));

        // deploy delegator contract
        delegator = new CErc20Delegator(
            address(tka),
            comptrollerProxy,
            model,
            // exchange rate should be 1:1
            1e18,
            "compound token A",
            "cTKA",
            18,
            payable(msg.sender),
            address(delegate),
            ""
        );
        
        // set oracle contract for comptroller
        comptrollerProxy._setPriceOracle(oracle);
        // add token A into the lending market
        comptrollerProxy._supportMarket(CToken(address(delegator)));
        // show current listing markets
        comptrollerProxy.getAllMarkets();

        // deploy second cErc20 contract
        tkb = new Token("token B", "TKB");
        CErc20Delegate delegateB = new CErc20Delegate();
        delegatorB = new CErc20Delegator(
            address(tkb),
            comptrollerProxy,
            model,
            // exchange rate should be 1:1
            1e18,
            "compound token B",
            "cTKB",
            18,
            payable(msg.sender),
            address(delegateB),
            ""
        );

        // add token B into the lending market
        comptrollerProxy._supportMarket(CToken(address(delegatorB)));
        
        // setting token A price to $1
        // oracle.setUnderlyingPrice(tka, 1*1e18);
        oracle.setDirectPrice(address(tka), 1e18);
        // setting token B price to $100
        oracle.setDirectPrice(address(tkb), 100e18);
        // set token B collateral factor 50%
        comptrollerProxy._setCollateralFactor(CToken(address(delegatorB)), 0.5e18);
        // set liquidation incentive 10%
        comptrollerProxy._setLiquidationIncentive(0.1e18);
        // set close factor 80%
        comptrollerProxy._setCloseFactor(0.8e18);

        // provide some A, B tokens for liquidity pool
        uint256 basicLiquidity = 100e18;
        deal(address(tka), owner, basicLiquidity);
        deal(address(tkb), owner, basicLiquidity);
        tka.approve(address(delegator), basicLiquidity);
        tkb.approve(address(delegatorB), basicLiquidity);
        delegator.mint(basicLiquidity);
        delegatorB.mint(basicLiquidity);
        address[] memory cTokens = new address[](2);
        cTokens[0] = address(delegator);
        cTokens[1] = address(delegatorB);
        comptrollerProxy.enterMarkets(cTokens);

        vm.stopPrank();
    }

    function testMintRedeem() public {
        vm.startPrank(user1);
        // deal 100 erc20 token for user1
        uint256 mintAmount = 100 * 10 ** tka.decimals();
        deal(address(tka), user1, mintAmount);
        // approve 100 erc20 token for delegator
        tka.approve(address(delegator), mintAmount);
        // mint cErc20
        delegator.mint(mintAmount);
        // the exchange rate of cErc20 should be 1:1
        assertEq(delegator.balanceOf(user1), mintAmount);
        delegator.redeem(mintAmount);
        // the amount of redeem should be the amount of mint
        assertEq(tka.balanceOf(user1), mintAmount);
        vm.stopPrank();
    }

    function testBorrowRepay() public {
        vm.startPrank(user1);
        uint256 mintAmount = 1 * 10 ** tkb.decimals();
        uint256 borrowAmount = 50 * 10 ** tka.decimals();
        // deal 1 token B for user1
        deal(address(tkb), user1, mintAmount);
        // approve 1 token B token for delegator
        tkb.approve(address(delegatorB), mintAmount);
        // mint 1 cTKB
        delegatorB.mint(mintAmount);
        // enter market
        address[] memory cTokens = new address[](1);
        cTokens[0] = address(delegatorB);
        comptrollerProxy.enterMarkets(cTokens);
        // borrow 50 TKA
        delegator.borrow(borrowAmount);
        // check user1 has 50 TKA
        assertEq(tka.balanceOf(user1), borrowAmount);
        vm.stopPrank();
    }

    function testUpdateCollateralFactorLiquidation() public {
        vm.startPrank(user1);
        uint256 mintAmount = 1 * 10 ** tkb.decimals();
        uint256 borrowAmount = 50 * 10 ** tka.decimals();
        // deal 1 token B for user1
        deal(address(tkb), user1, mintAmount);
        // approve 1 token B token for delegator
        tkb.approve(address(delegatorB), mintAmount);
        // mint 1 cTKB
        delegatorB.mint(mintAmount);
        // enter market
        address[] memory cTokens = new address[](1);
        cTokens[0] = address(delegatorB);
        comptrollerProxy.enterMarkets(cTokens);
        // borrow 50 TKA
        delegator.borrow(borrowAmount);
        // check user1 has 50 TKA
        assertEq(tka.balanceOf(user1), borrowAmount);
        vm.stopPrank();
        
        // change the token B collateral factor to 40%
        vm.startPrank(owner);
        comptrollerProxy._setCollateralFactor(CToken(address(delegatorB)), 0.4e18);
        vm.stopPrank();

        vm.startPrank(user2);

        // get the amount of user1 liquidity shortfall
        (, , uint shortfall) = comptrollerProxy.getAccountLiquidity(user1);

        // deal the amount of token A to user2
        deal(address(tka), user2, shortfall);
        // user2 approve token A to compound
        tka.approve(address(delegator), shortfall);

        // execute the liquidation
        delegator.liquidateBorrow(user1, shortfall, delegatorB);

        // calculate the benefit
        (, uint256 seizeAmount) = comptrollerProxy.liquidateCalculateSeizeTokens(address(delegator), address(delegatorB), shortfall);
        // token a commission by compound
        uint256 benefit = seizeAmount * (expScale - protocolSeizeShareMantissa) / expScale;
        
        // check the amount of token B after liquidation 
        assertEq(delegatorB.balanceOf(user2), benefit);
        vm.stopPrank();
    }

    function testUpdatePriceLiquidation() public {
        vm.startPrank(user1);
        uint256 mintAmount = 1 * 10 ** tkb.decimals();
        uint256 borrowAmount = 50 * 10 ** tka.decimals();
        // deal 1 token B for user1
        deal(address(tkb), user1, mintAmount);
        // approve 1 token B token for delegator
        tkb.approve(address(delegatorB), mintAmount);
        // mint 1 cTKB
        delegatorB.mint(mintAmount);
        // enter market
        address[] memory cTokens = new address[](1);
        cTokens[0] = address(delegatorB);
        comptrollerProxy.enterMarkets(cTokens);
        // borrow 50 TKA
        delegator.borrow(borrowAmount);
        // check user1 has 50 TKA
        assertEq(tka.balanceOf(user1), borrowAmount);
        vm.stopPrank();
        
        // setting token B price to $50
        oracle.setDirectPrice(address(tkb), 50e18);
        comptrollerProxy.liquidationIncentiveMantissa();

        vm.startPrank(user2);

        // get the amount of user1 liquidity shortfall
        (uint errorCode, uint liquidity, uint shortfall) = comptrollerProxy.getAccountLiquidity(user1);

        // deal the amount of token A to user2
        deal(address(tka), user2, shortfall);
        // user2 approve token A to compound
        tka.approve(address(delegator), shortfall);

        // execute the liquidation
        delegator.liquidateBorrow(user1, shortfall, delegatorB);

        // calculate the benefit
        (, uint256 seizeAmount) = comptrollerProxy.liquidateCalculateSeizeTokens(address(delegator), address(delegatorB), shortfall);
        // token a commission by compound
        uint256 benefit = seizeAmount * (expScale - protocolSeizeShareMantissa) / expScale;
        
        // check the amount of token B after liquidation 
        assertEq(delegatorB.balanceOf(user2), benefit);
        vm.stopPrank();
    }
}