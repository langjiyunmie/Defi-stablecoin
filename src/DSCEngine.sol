// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "lib/openzepplin-contracts/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "lib/openzepplin-contracts/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface, OracleLib} from "src/libraries/OracleLib.sol";

contract DSCEngine is ReentrancyGuard {
    DecentralizedStableCoin public immutable i_dsc;
    // 记录用户存入的抵押品
    event CollateralDeposited(address indexed user, address indexed tokenCollateralAddress, uint256 amountCollateral);
    // 记录用户赎回的抵押品
    event CollateralRedeemed(address indexed user, address indexed tokenCollateralAddress, uint256 amountCollateral);


    // 检查抵押品地址和价格源地址长度是否相同
    error DSCEngine__TokenAddressesAndPriceFeedAddressesLengthsMustBeTheSame();
    // 检查数量是否大于0
    error DSCEngine__MoreThanZero();
    // 检查转账是否成功
    error DSCEngine__TransferFailed();  
    // 检查铸造是否成功
    error DSCEngine__MintFailed();
    // 检查健康因子是否破损
    error DSCEngine__HealthFactorIsBroken();
    // 检查销毁是否成功
    error DSCEngine__BurnFailed();
    // 检查健康因子是否未破损
    error DSCEngine__HealthFactorIsNotBroken();
    
    
    
    // 获取抵押品的实时价格
    mapping(address collateralToken => address priceFeed) public priceFeeds;
    // 记录用户抵押品数量
    mapping(address user => mapping(address collateralToken => uint256 amount)) private _collateralDeposited;
    // 记录用户铸造的DSC数量
    mapping(address user => uint256 amount) private _dscMinted;
    // 记录支持的抵押品
    address[] private _collateralTokens;


   
    // 检查抵押品是否被允许
    modifier isAllowedToken(address tokenAddress){
        if(priceFeeds[tokenAddress] == address(0)){
            revert DSCEngine__TokenAddressesAndPriceFeedAddressesLengthsMustBeTheSame();
        }
        _;
    }

    // 检查数量是否大于0
    modifier moreThanZero(uint256 value){
        if(value <= 0){
            revert DSCEngine__MoreThanZero();
        }
        _;
    }

    // 精度
    uint256 private constant _PRECISION = 1e18;
    // 清算阈值
    uint256 private constant _LIQUIDATION_THRESHOLD = 50;
    // 清算奖励
    uint256 private constant _LIQUIDATION_BONUS = 10;
    // 清算精度
    uint256 private constant _LIQUIDATION_PRECISION = 100;
    // 最小健康因子
    uint256 private constant _MIN_HEALTH_FACTOR = 1e18;
    // 添加抵押品精度
    uint256 private constant _ADDITIONAL_FEED_PRECISION = 1e10;
    // 抵押品精度
    uint256 private constant _FEED_PRECISION = 1e8;
    


    // 构造函数，初始化抵押品和价格源
    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address dscAddress) {
        if(tokenAddresses.length != priceFeedAddresses.length){
            revert DSCEngine__TokenAddressesAndPriceFeedAddressesLengthsMustBeTheSame();
        }

        for(uint256 i = 0; i < tokenAddresses.length; i++){
            if(tokenAddresses[i] == address(0)){
                revert DSCEngine__TokenAddressesAndPriceFeedAddressesLengthsMustBeTheSame();
            }
            priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            _collateralTokens.push(tokenAddresses[i]);
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
        

    }

    /**
     * @notice 存入抵押品并铸造DSC代币
     * @dev 这是一个组合函数，允许用户在一次交易中完成存入抵押品和铸造DSC两个操作
     * 这样可以节省gas费用，提高用户体验
     */
    function depositCollateralAndMintDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToMint
    ) external nonReentrant {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(amountDscToMint);
    }

    /**
     * @notice 存入抵押品
     * @dev 用户可以存入支持的代币作为抵押品
     * 抵押品将被锁定在合约中，用于铸造DSC
     */
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral) public nonReentrant isAllowedToken(tokenCollateralAddress) moreThanZero(amountCollateral) {
        _collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if(!success){
            revert DSCEngine__TransferFailed();
        }
        
    }

    /**
     * @notice 赎回抵押品并销毁DSC
     * @dev 用户可以通过销毁DSC来赎回等值的抵押品
     * 这是一个组合操作，需要确保用户有足够的DSC余额
     */
    function redeemCollateralForDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToBurn
    ) external nonReentrant {
        _burnDsc(amountDscToBurn, msg.sender, msg.sender);
        _redeemCollateral(tokenCollateralAddress, amountCollateral, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral) external {
        _redeemCollateral(tokenCollateralAddress, amountCollateral, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * @notice 赎回抵押品
     * @dev 允许用户取回他们的抵押品
     * 需要确保赎回后维持足够的抵押率
     */
    function _redeemCollateral(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        address from,
        address to
    ) private  {
       _collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
       emit CollateralRedeemed(from, tokenCollateralAddress, amountCollateral);
       bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
       if(!success){
        revert DSCEngine__TransferFailed();
       }
    }

    /**
     * @notice 铸造DSC代币
     * @dev 用户可以基于已存入的抵押品铸造DSC
     * 需要确保铸造后维持健康的抵押率
     */
    function mintDsc(uint256 amountDscToMint) public moreThanZero(amountDscToMint) {
        _dscMinted[msg.sender] += amountDscToMint;
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if(!minted){
            revert DSCEngine__MintFailed();
        }
    }

    function burnDsc(
        uint256 amount
    ) external moreThanZero(amount) nonReentrant {
        _burnDsc(amount, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }
    
    /**
     * @notice 销毁DSC代币
     * @dev 用户可以销毁自己持有的DSC
     * 通常用于减少债务或准备赎回抵押品
     * 
     */
    function _burnDsc(uint256 amountDscToBurn,address onBehalfOf, address dscFrom) private {
        _dscMinted[onBehalfOf] -= amountDscToBurn;
        bool success = i_dsc.transferFrom(dscFrom, address(this), amountDscToBurn);
        if(!success){
            revert DSCEngine__BurnFailed();
        }
        i_dsc.burn(amountDscToBurn);
    }

    function liquidate(address collateral, address user, uint256 debtToCover) external {
        uint256 startingUserHealthFactor = _healthFactor(user);
        if(startingUserHealthFactor > _MIN_HEALTH_FACTOR){
            revert DSCEngine__HealthFactorIsNotBroken();
        }
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);

        uint256 bonusCollateral = (tokenAmountFromDebtCovered * _LIQUIDATION_BONUS) / _LIQUIDATION_PRECISION;
        // 赎回抵押品
        _redeemCollateral(collateral, tokenAmountFromDebtCovered + bonusCollateral, user, msg.sender);
        _burnDsc(debtToCover, user, msg.sender);
        // 检查清算后的健康因子
        uint256 endingUserHealthFactor = _healthFactor(user);
        if(endingUserHealthFactor <= _MIN_HEALTH_FACTOR){
            revert DSCEngine__HealthFactorIsBroken();
        }
        _revertIfHealthFactorIsBroken(msg.sender);

    }

    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 healthFactor = _healthFactor(user);
        if(healthFactor < _MIN_HEALTH_FACTOR){
            revert DSCEngine__HealthFactorIsBroken();
        }
    }

    function calculateHealthFactor(
        uint256 totalDscMinted, 
        uint256 totalCollateralValue) public pure returns (uint256) {
        return _calculateHealthFactor(totalDscMinted, totalCollateralValue);
    }

    function _healthFactor(address user) private view returns (uint256){
        (uint256 totalDscMinted, uint256 totalCollateralValue) = getAccountInformation(user);
        return _calculateHealthFactor(totalDscMinted, totalCollateralValue);
    }

    /**
     * @notice 获取账户健康因子
     * @dev 返回用户账户的健康状况
     * 健康因子 = 抵押品总价值 / 铸造的DSC数量  
     * @return 健康因子，用uint256表示
     */
    function _calculateHealthFactor(
        uint256 totalDscMinted, 
        uint256 totalCollateralValue) internal pure returns (uint256) {
        if(totalDscMinted == 0){
            return type(uint256).max;// 如果DSC铸造为0，则健康因子为最大值
        }
        uint256 collateralAdjustedForThreshold = (totalCollateralValue * _LIQUIDATION_THRESHOLD) / _LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * _PRECISION) / totalDscMinted;
    }

    /**
     * @notice 获取用户账户信息
     * @dev 返回用户铸造的DSC数量和所有抵押品总价值
     * @param user 用户地址
     * @return totalDscMinted 用户铸造的DSC数量
     * @return totalCollateralValue 用户所有抵押品总价值
     */
    function getAccountInformation(address user) public view returns (uint256 totalDscMinted, uint256 totalCollateralValue){
        (totalDscMinted, totalCollateralValue) = _getAccountInformation(user);
    }
    
    function _getAccountInformation(address user) private view returns (uint256 totalDscMinted, uint256 totalCollateralValue){
        totalDscMinted = _dscMinted[user];
        totalCollateralValue = getAccountCollateralValue(user);
        
    }

    /**
     * @notice 获取用户所有抵押品的总价值（以USD计）
     * @dev 遍历用户的所有抵押品，计算它们的总价值
     * @param user 要查询的用户地址
     * @return totalCollateralValue 用户所有抵押品的总价值（以USD计，18位精度）
     */
    function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralValue) {
        for (uint256 index = 0; index < _collateralTokens.length; index++) {
            address token = _collateralTokens[index];
            uint256 amount = _collateralDeposited[user][token];
            totalCollateralValue += _getUsdValue(token, amount);
        }
        return totalCollateralValue;
    }

    /**
     * @notice 计算给定USD金额需要多少代币
     * @dev 使用Chainlink预言机获取代币价格，然后进行计算
     * 例如：要借100 USD，ETH价格是2000 USD，则需要0.05 ETH
     * @param tokenCollateralAddress 代币地址
     * @param usdAmountIn USD金额（18位精度）
     * @return 需要的代币数量（以代币精度为单位）
     */
    function getTokenAmountFromUsd(address tokenCollateralAddress, uint256 usdAmountIn) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(priceFeeds[tokenCollateralAddress]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        return (usdAmountIn * _PRECISION) / (uint256(price) * _ADDITIONAL_FEED_PRECISION);
    }

    /**
     * @notice 获取代币的USD价值
     * @dev 公开函数，调用内部的 _getUsdValue 函数
     * @param token 代币地址
     * @param amount 代币数量
     * @return USD价值（18位精度）
     */
    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        return _getUsdValue(token, amount);
    }

    /**
     * @notice 计算代币的USD价值
     * @dev 使用Chainlink预言机获取价格，并进行精度转换
     * 例如：1 ETH = 1000 USD，Chainlink返回1000 * 1e8
     * @param token 代币地址
     * @param amount 代币数量
     * @return USD价值（18位精度）
     */
    function _getUsdValue(address token, uint256 amount) private view returns(uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        return ((uint256(price) * _ADDITIONAL_FEED_PRECISION * amount) / _PRECISION);
    }

    /**
     * @notice 获取用户特定代币的抵押数量
     * @dev 直接从存储中读取用户的抵押品余额
     * @param user 用户地址
     * @param tokenCollateralAddress 抵押品代币地址
     * @return 抵押品数量（以代币精度为单位）
     */
    function getCollateralBalanceOfUser(address user, address tokenCollateralAddress) public view returns (uint256) {
        return _collateralDeposited[user][tokenCollateralAddress];
    }

    function getPrecision() external pure returns (uint256) {
        return _PRECISION;
    }

    function getAdditionalFeedPrecision() external pure returns (uint256) {
        return _ADDITIONAL_FEED_PRECISION;
    }

    function getLiquidationThreshold() external pure returns (uint256) {
        return _LIQUIDATION_THRESHOLD;
    }

    function getLiquidationBonus() external pure returns (uint256) {
        return _LIQUIDATION_BONUS;
    }

    function getLiquidationPrecision() external pure returns (uint256) {
        return _LIQUIDATION_PRECISION;
    }

    function getMinHealthFactor() external pure returns (uint256) {
        return _MIN_HEALTH_FACTOR;
    }

    function getCollateralTokens() external view returns (address[] memory) {
        return _collateralTokens;
    }

    function getDsc() external view returns (address) {
        return address(i_dsc);
    }

    function getCollateralTokenPriceFeed(address token) external view returns (address) {
            return priceFeeds[token];
    }

    function getHealthFactor(address user) external view returns (uint256) {
        return _healthFactor(user);
    }

}

    
    


