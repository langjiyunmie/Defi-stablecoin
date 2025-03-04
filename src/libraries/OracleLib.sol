// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {AggregatorV3Interface} from
    "lib/chainlink-brownie-contracts/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

library OracleLib {
    // 检查价格是否过时
    error OracleLib__StalePrice();

    uint256 private constant TIMEOUT = 3 hours;

    // 检查价格是否过时
    function staleCheckLatestRoundData(AggregatorV3Interface chainlinkPriceFeed)
        public
        view
        returns (uint80, int256, uint256, uint256, uint80)
    {
        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            chainlinkPriceFeed.latestRoundData();
        if (updatedAt == 0 || answeredInRound < roundId) {
            revert OracleLib__StalePrice();
        }
        uint256 secondsSince = block.timestamp - updatedAt;
        if (secondsSince > TIMEOUT) {
            revert OracleLib__StalePrice();
        }
        return (roundId, answer, startedAt, updatedAt, answeredInRound);
    }

    function getTimeout(AggregatorV3Interface /*chainlinkPriceFeed*/ ) public pure returns (uint256) {
        return TIMEOUT;
    }
}
