// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console2} from "forge-std/Script.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
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
        Token erc20 = new Token("jim", "JIM");
        // borrow rate should be 0
        // so we need to set baseRatePerYear and multiplierPerYear to 0
        // which would make (ur * baseRatePerYear/2102400 / BASE + baseRatePerYear/2102400) = 0
        WhitePaperInterestRateModel model = new WhitePaperInterestRateModel(0, 0);
        SimplePriceOracle oracle = new SimplePriceOracle();
        Comptroller comptroller = new Comptroller();
        comptroller._setPriceOracle(oracle);
        CErc20Delegate delegate = new CErc20Delegate();
        CErc20Delegator delegator = new CErc20Delegator(
            address(erc20),
            comptroller,
            model,
            // exchange rate should be 1:1
            1e18,
            "compound jim",
            "cJIM",
            18,
            payable(msg.sender),
            address(delegate),
            "0x"
        );
        Unitroller unitroller = new Unitroller();
        unitroller._setPendingImplementation(address(delegator));
        unitroller._acceptImplementation();

        vm.stopBroadcast();
    }
}
