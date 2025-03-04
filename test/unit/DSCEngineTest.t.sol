// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {DeployDSC} from "script/DeployDSC.s.sol";
import {DecentralizedStableCoin} from "src/DecentralizedStableCoin.sol";
import {DSCEngine} from "src/DSCEngine.sol";
import {HelperConfig} from "script/HelperConfig.s.sol";
import {ERC20Mock} from "test/mocks/ERC20Mock.sol";
import {MockFailedTransferFrom} from "test/mocks/MockFailedTransferFrom.sol";
import {MockV3Aggregator} from "test/mocks/MockV3Aggregator.sol";
import {MockTransferFailed} from "test/mocks/MockTransfer.sol";
import {MockMoreDebtDSC} from "test/mocks/MockFailedDebtDSC.sol";


contract DSCEngineTest is Test {
    // 部署合约
    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    DSCEngine dsce;
    HelperConfig helperConfig;
    event CollateralRedeemed(address indexed from,address indexed tokenCollateralAddress,uint256 amountCollateral);
    // 测试变量
    address public wethUsdPriceFeed;
    address public wbtcUsdPriceFeed;
    address public weth;
    address public wbtc;
    uint256 public deployerKey;
    address public user = makeAddr("user");
    address public liquidator = makeAddr("liquidator");
     uint256 public collateralToCover = 20 ether;
    // ether 是一个单位转换器，1 ether = 1e18
    uint256 public constant STARTING_BALANCE = 1000 ether;
    uint256 public constant amountCollateral = 10 ether;
    uint256 public constant amountToMint = 100 ether;
    // 设置测试环境
    function setUp() external {
        deployer = new DeployDSC();
        (dsc,dsce,helperConfig) = deployer.run();
        ( wethUsdPriceFeed,wbtcUsdPriceFeed, weth,wbtc,deployerKey) =
            helperConfig.activeNetworkConfig();
        if(block.chainid == 31337){
            vm.deal(user,STARTING_BALANCE);
        }

        ERC20Mock(weth).mint(user,STARTING_BALANCE);
        ERC20Mock(wbtc).mint(user,STARTING_BALANCE);
    }

    // 测试变量
    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    //构造函数测试
    function test_constructor_reverts_if_token_addresses_and_price_feed_addresses_lengths_are_not_the_same() public {
        tokenAddresses.push(weth);
        tokenAddresses.push(wbtc);
        priceFeedAddresses.push(wethUsdPriceFeed);
        vm.expectRevert(DSCEngine.DSCEngine__TokenAddressesAndPriceFeedAddressesLengthsMustBeTheSame.selector);
        new DSCEngine(tokenAddresses,priceFeedAddresses,address(dsc));
    }
    
    function test_constructor_reverts_if_token_address_is_zero_address() public {
        tokenAddresses.push(address(0));
        tokenAddresses.push(wbtc);
        priceFeedAddresses.push(wethUsdPriceFeed);
        priceFeedAddresses.push(wbtcUsdPriceFeed);
        vm.expectRevert(DSCEngine.DSCEngine__TokenAddressIsZeroAddress.selector);
        new DSCEngine(tokenAddresses,priceFeedAddresses,address(dsc));
    }

    // 价格测试
    // 测试 getTokenAmountFromUsd 函数
    function test_getTokenAmountFromUsd_returns_correct_amount() public {
        // 0.05 这样的小数需要转换为整数形式，通常是通过乘以相应的精度（比如 1e18）来实现。
        uint256 usdAmount = 100 ether;
        uint256 expectedWethAmount = 0.05 ether;
        uint256 wethAmount = dsce.getTokenAmountFromUsd(weth,usdAmount);
        assertEq(wethAmount,expectedWethAmount);
    }
    // 测试 getUsdValue 函数
    function test_getUsdValue_returns_correct_price() public {
        uint256 ethAmount = 10 ether;
        // uint256 expectedWethValue = 2000e8;
        // 2000$/ETH * 10 ether = 20000 e18
        uint256 expectedWethValue = 20000e18;
        uint256 wethUsdPrice = dsce.getUsdValue(weth,ethAmount);
        assertEq(wethUsdPrice,expectedWethValue);
        
    }

    // 抵押品测试
    // 测试 depositCollateral 函数在转账失败时会 revert
    function test_depositCollateral_reverts_if_transfer_failed() public {
        address owner = msg.sender;
        vm.prank(owner);
        MockFailedTransferFrom mockDsc = new MockFailedTransferFrom();
        vm.prank(owner);
        mockDsc.mint(owner,100 ether);
        tokenAddresses.push(address(mockDsc));
        priceFeedAddresses.push(wethUsdPriceFeed);
        vm.prank(owner);
        dsce = new DSCEngine(tokenAddresses,priceFeedAddresses,address(mockDsc));
        
        vm.startPrank(owner);
        ERC20Mock(address(mockDsc)).approve(address(dsce),100 ether);
        vm.expectRevert(DSCEngine.DSCEngine__TransferFailed.selector);
        dsce.depositCollateral(address(mockDsc),100 ether);
        vm.stopPrank();
    }

    // 测试 depositCollateral 函数在抵押品为0时会 revert
    function testRevertIfCollateralZero() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dsce),100 ether);
        vm.expectRevert(DSCEngine.DSCEngine__MoreThanZero.selector);
        dsce.depositCollateral(weth,0);
        vm.stopPrank();
    }

    // 测试 depositCollateral 函数在代币不允许时会 revert
    function testRevertsWithUnapprovedCollateral() public {
        ERC20Mock mockDsc = new ERC20Mock("Mock Dsc","MDC",user,100 ether);
        vm.startPrank(user);
        mockDsc.approve(address(dsce),10 ether);
        vm.expectRevert(DSCEngine.DSCEngine__TokenNotAllowed.selector);
        dsce.depositCollateral(address(mockDsc),10 ether);
        vm.stopPrank();
    }

    modifier depositedCollateral() {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dsce), amountCollateral);
        dsce.depositCollateral(weth, amountCollateral);
        vm.stopPrank();
        _;
    }

    modifier depositedCollateralAndMintedDsc() {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dsce), amountCollateral);
        dsce.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint);
        vm.stopPrank();
        _;
    }

    // 测试 账户的信息
    function test_getInformationOfUser() public depositedCollateral {
       (uint256 totalDscMinted,uint256 collateralValueInUsd) = dsce.getAccountInformation(user);
        uint256 expectedDepositAmount = dsce.getTokenAmountFromUsd(weth,collateralValueInUsd);
        assertEq(totalDscMinted,0);
        assertEq(expectedDepositAmount,10 ether);
    }

    // 测试 depositCollateralAndMintDsc 函数
    // 测试当mint的dsc数量超过抵押品数量时会 revert
     function testRevertsIfMintedDscBreaksHealthFactor() public {
        // 获取weth的价格
        (,int256 price,,,) = MockV3Aggregator(wethUsdPriceFeed).latestRoundData();
        // 计算没有经过利率转化mint的dsc数量
        uint256 amountToMint = (amountCollateral * (uint256(price)) * dsce.getAdditionalFeedPrecision()) / 1e18;
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dsce),amountCollateral);
        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorIsBroken.selector);
        dsce.depositCollateralAndMintDsc(weth,amountCollateral,amountToMint);
        vm.stopPrank();
     }

    // 测试是否可以铸造dsc
    function testCanMintDsc() public depositedCollateral {
        vm.prank(user);
        dsce.mintDsc(10 ether);
        // 获取用户铸造的dsc数量
        (uint256 totalDscMinted,uint256 collateralValueInUsd) = dsce.getAccountInformation(user);
        uint256 userBalance = totalDscMinted;
        assertEq(userBalance,10 ether);
    }

    // 测试当burn的dsc数量为0时会 revert
    function testRevertsIfBurnAmountIsZero() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dsce),amountCollateral);
        dsce.depositCollateralAndMintDsc(weth,amountCollateral,amountToMint);
        vm.expectRevert(DSCEngine.DSCEngine__MoreThanZero.selector);
        dsce.burnDsc(0);
        vm.stopPrank();
    }
    
    // 测试赎回函数
    // 测试赎回函数在转账失败时会 revert
    function test_redeemCollateral_reverts_if_transfer_failed() public  {
        address owner = msg.sender;
        vm.prank(owner);
        MockTransferFailed mockDsc = new MockTransferFailed();
        vm.prank(owner);
        mockDsc.mint(owner,100 ether);
        tokenAddresses.push(address(mockDsc));
        priceFeedAddresses.push(wethUsdPriceFeed);
        vm.prank(owner);
        DSCEngine Mockdsce = new DSCEngine(tokenAddresses,priceFeedAddresses,address(mockDsc));
        vm.prank(owner);
        mockDsc.transferOwnership(address(Mockdsce));
        vm.startPrank(owner);
        ERC20Mock(address(mockDsc)).approve(address(Mockdsce),10 ether);
        Mockdsce.depositCollateral(address(mockDsc),10 ether);
        vm.expectRevert(DSCEngine.DSCEngine__TransferFailed.selector);
        Mockdsce.redeemCollateral(address(mockDsc),10 ether);
        vm.stopPrank();
    }   

    // 测试赎回函数是否可以赎回 0 抵押品
    function test_redeemCollateral_reverts_if_amount_is_zero() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dsce),amountCollateral);
        dsce.depositCollateral(weth,amountCollateral);
        vm.expectRevert(DSCEngine.DSCEngine__MoreThanZero.selector);
        dsce.redeemCollateral(weth,0);
        vm.stopPrank();
    }

    // 测试是否可以正常赎回
   function testCanRedeemCollateral() public depositedCollateral {
        uint256 startingUserWethBalance = dsce.getCollateralBalanceOfUser(user,weth);
        assertEq(startingUserWethBalance,amountCollateral);
        vm.prank(user);
        dsce.redeemCollateral(weth,amountCollateral);
        uint256 endingUserWethBalance = dsce.getCollateralBalanceOfUser(user,weth);
        assertEq(endingUserWethBalance,0);
   }
   // 测试 emitCollateralRedeemedWithCorrectArgs 函数
   function testEmitCollateralRedeemedWithCorrectArgs() public depositedCollateral {
        vm.expectEmit(true,true,false,true,address(dsce));
        emit CollateralRedeemed(user,weth,amountCollateral);
        vm.startPrank(user);
        dsce.redeemCollateral(weth, amountCollateral);
        vm.stopPrank();
    }

    
    // 测试当burn的dsc数量为0时会 revert
    function testMustRedeemMoreThanZero() public depositedCollateralAndMintedDsc {
        vm.startPrank(user);
        dsc.approve(address(dsce),amountToMint);
        vm.expectRevert(DSCEngine.DSCEngine__MoreThanZero.selector);
        dsce.redeemCollateralForDsc(weth,amountCollateral,0);
        vm.stopPrank();
    }

   function testCanRedeemCollateralForDsc() public {
        vm.startPrank(user);
        // 1. 先批准 WETH 的使用权
        ERC20Mock(weth).approve(address(dsce), amountCollateral);
        // 2. 存入抵押品并铸造 DSC
        dsce.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint);
        
        // 3. 记录初始抵押品余额
        uint256 startingUserWethBalance = dsce.getCollateralBalanceOfUser(user, weth);
        assertEq(startingUserWethBalance, amountCollateral);
        
        // 4. 批准 DSC 的使用权（用于销毁）
        dsc.approve(address(dsce), amountToMint);
        
        // 5. 赎回抵押品并销毁 DSC
        dsce.redeemCollateralForDsc(weth, amountCollateral, amountToMint);
        
        // 6. 验证抵押品已经全部赎回
        uint256 endingUserWethBalance = dsce.getCollateralBalanceOfUser(user, weth);
        assertEq(endingUserWethBalance, 0);
        vm.stopPrank();
    }

    // 健康因子测试
    function testHealthFactorIsBroken() public depositedCollateralAndMintedDsc {
        // 1. 获取抵押品的 USD 价值
        uint256 collateralValueInUsd = dsce.getUsdValue(weth, amountCollateral);
        // 2. 获取用户信息
        (uint256 totalDscMinted,) = dsce.getAccountInformation(user);
        // 3. 计算健康因子
        uint256 expectedHealthFactor = dsce.calculateHealthFactor(totalDscMinted,collateralValueInUsd);
        // 4. 验证健康因子是否破损
        assertEq(dsce.getHealthFactor(user),expectedHealthFactor);
    }
    // 当价格变化时，健康因子是否变化
    function testHealthFactorIsNotBroken() public depositedCollateralAndMintedDsc {
        // 1. 将 ETH 价格更新为 $1000
        MockV3Aggregator(wethUsdPriceFeed).updateAnswer(1000e8); // 注意这里应该是 1000e8 而不是 1000e18
        
        // 2. 新的健康因子计算
        // 抵押品价值 = 10 ETH * $1000 = $10,000
        // 考虑清算阈值后 = $10,000 * 50% = $5,000
        // 健康因子 = $5,000 / $100 = 50
        
        uint256 healthFactor = dsce.getHealthFactor(user);
        assertEq(healthFactor, 50 ether); 

    }

    // 测试清算函数
    function testMustImproveHealthFactorOnLiquidation() public {
        // 1. 设置测试环境
        // 创建一个特殊的 DSC mock 合约，这个合约在 burn 时会将价格崩溃到 0
        MockMoreDebtDSC mockDsc = new MockMoreDebtDSC(wethUsdPriceFeed);
        // 设置支持的代币和价格源
        tokenAddresses.push(weth);
        priceFeedAddresses.push(wethUsdPriceFeed);
        
        // 部署新的 DSCEngine 并转移 DSC 的所有权
        address owner = msg.sender;
        vm.prank(owner);
        DSCEngine mockDsce = new DSCEngine(tokenAddresses, priceFeedAddresses, address(mockDsc));
        mockDsc.transferOwnership(address(mockDsce));

        // 2. 设置被清算用户
        vm.startPrank(user);
        // 用户批准 DSCEngine 使用其 WETH
        ERC20Mock(address(weth)).approve(address(mockDsce), amountCollateral);
        // 用户存入 10 ETH 并铸造 100 DSC
        mockDsce.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint);
        vm.stopPrank();

        // 3. 设置清算人
        // 给清算人铸造 1 ETH
        uint256 collateralToLiquidate = 1 ether;
        ERC20Mock(weth).mint(liquidator, collateralToLiquidate);

        // 4. 清算人的操作
        vm.startPrank(liquidator);
        // 清算人批准 DSCEngine 使用其 WETH
        ERC20Mock(address(weth)).approve(address(mockDsce), collateralToLiquidate);
        // 设置要清算的债务数量
        uint256 debtToCover = 10 ether;
        // 清算人也存入抵押品并铸造 DSC
        mockDsce.depositCollateralAndMintDsc(weth, collateralToLiquidate, amountToMint);
        // 批准 DSCEngine 使用清算人的 DSC
        mockDsc.approve(address(mockDsce), debtToCover);

        // 5. 触发清算条件
        // 将 ETH 价格更新为 $18，导致用户健康因子破坏
        int256 ethUsdUpdatedPrice = 18e8;
        MockV3Aggregator(wethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);

        // 6. 执行清算
        // 预期清算会失败，因为清算后的健康因子仍然是破坏的
        // 清算 10 DSC 的数量太小，无法显著改善健康因子
        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorIsBroken.selector);
        mockDsce.liquidate(weth, user , debtToCover);
        vm.stopPrank();
    }

    // 测试处于健康因子正常时，是否可以清算
    function testLiquidationDoesNotHappenIfHealthFactorIsAboveThreshold() public depositedCollateralAndMintedDsc{
        ERC20Mock(weth).approve(address(dsce),amountCollateral);
        vm.startPrank(liquidator);
        ERC20Mock(weth).mint(liquidator,amountCollateral);
        ERC20Mock(weth).approve(address(dsce),amountCollateral);
        dsce.depositCollateralAndMintDsc(weth,amountCollateral,amountToMint);
        uint256 debtToCover = 10 ether;
        ERC20Mock(weth).approve(address(dsce),debtToCover);
        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorIsNotBroken.selector);
        dsce.liquidate(weth,user,debtToCover);
        vm.stopPrank();
    }

    modifier liquidated(){
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dsce),amountCollateral);
        dsce.depositCollateralAndMintDsc(weth,amountCollateral,amountToMint);
        vm.stopPrank();
        int256 ethUsdUpdatedPrice = 18e8;

        MockV3Aggregator(wethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);
        uint256 userHealthFactor = dsce.getHealthFactor(user);

        ERC20Mock(address(weth)).mint(liquidator,collateralToCover);
        vm.startPrank(liquidator);
        ERC20Mock(weth).approve(address(dsce),collateralToCover);
        dsce.depositCollateralAndMintDsc(weth,collateralToCover,amountToMint);
        dsc.approve(address(dsce),amountToMint);
        dsce.liquidate(weth,user,amountToMint);
        vm.stopPrank();
        _;
    }

    function testLiquidationPayoutIsCorrect() public liquidated{
          uint256 liquidatorWethBalance = ERC20Mock(weth).balanceOf(liquidator);
        uint256 expectedWeth = dsce.getTokenAmountFromUsd(weth, amountToMint)
            + (dsce.getTokenAmountFromUsd(weth, amountToMint) * dsce.getLiquidationBonus() / dsce.getLiquidationPrecision());
        uint256 hardCodedExpected = 6_111_111_111_111_111_110;
        assertEq(liquidatorWethBalance, hardCodedExpected);
        assertEq(liquidatorWethBalance, expectedWeth);
    }

    function testUserStillHasSomeEthAfterLiquidation() public liquidated {
        // Get how much WETH the user lost
        uint256 amountLiquidated = dsce.getTokenAmountFromUsd(weth, amountToMint)
            + (dsce.getTokenAmountFromUsd(weth, amountToMint) * dsce.getLiquidationBonus() / dsce.getLiquidationPrecision());

        uint256 usdAmountLiquidated = dsce.getUsdValue(weth, amountLiquidated);
        uint256 expectedUserCollateralValueInUsd = dsce.getUsdValue(weth, amountCollateral) - (usdAmountLiquidated);

        (, uint256 userCollateralValueInUsd) = dsce.getAccountInformation(user);
        uint256 hardCodedExpectedValue = 70_000_000_000_000_000_020;
        assertEq(userCollateralValueInUsd, expectedUserCollateralValueInUsd);
        assertEq(userCollateralValueInUsd, hardCodedExpectedValue);
    }



}