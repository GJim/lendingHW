// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console2} from "forge-std/Script.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {CToken} from "compound-protocol/CToken.sol";
import {Comptroller} from "compound-protocol/Comptroller.sol";
import {SimplePriceOracle} from "compound-protocol/SimplePriceOracle.sol";
import {CErc20Delegate} from "compound-protocol/CErc20Delegate.sol";
import {CErc20Delegator} from "compound-protocol/CErc20Delegator.sol";
import {WhitePaperInterestRateModel} from "compound-protocol/WhitePaperInterestRateModel.sol";
import {Unitroller} from "compound-protocol/Unitroller.sol";

contract Token is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}
}

contract CompoundScript is Script {
    function setUp() public {}

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);
        // deploy underlying token contract
        Token tka = new Token("token A", "TKA");
        // deploy interest rate model contract, which borrow rate is 0
        // to make borrow rate equal to 0
        // we need to set baseRatePerYear and multiplierPerYear to 0
        // which would make (ur * baseRatePerYear/2102400 / BASE + baseRatePerYear/2102400) = 0
        WhitePaperInterestRateModel model = new WhitePaperInterestRateModel(0, 0);
        // deploy oracle contract
        SimplePriceOracle oracle = new SimplePriceOracle();
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
        Comptroller comptrollerProxy = Comptroller(address(unitroller));

        // deploy delegator contract
        CErc20Delegator delegator = new CErc20Delegator(
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

        vm.stopBroadcast();
    }
}
