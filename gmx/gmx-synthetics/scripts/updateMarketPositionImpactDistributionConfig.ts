import prompts from "prompts";
import hre from "hardhat";

import { getMarketKey, getMarketTokenAddresses, getOnchainMarkets } from "../utils/market";

import * as keys from "../utils/keys";
import { bigNumberify, formatAmount } from "../utils/math";

async function main() {
  const dataStore = await hre.ethers.getContract("DataStore");
  const multicall = await hre.ethers.getContract("Multicall3");
  const config = await hre.ethers.getContract("Config");

  const { read } = hre.deployments;
  const tokens = await (hre as any).gmx.getTokens();
  const tokensByAddress = Object.fromEntries(
    Object.entries(tokens).map(([symbol, t]) => [(t as any).address, { symbol, ...(t as any) }])
  );
  const markets = await (hre as any).gmx.getMarkets();

  const onchainMarketsByTokens = await getOnchainMarkets(read, dataStore.address);
  const multicallReadParams = [];

  for (const marketConfig of markets) {
    const [indexToken, longToken, shortToken] = getMarketTokenAddresses(marketConfig, tokens);
    const marketKey = getMarketKey(indexToken, longToken, shortToken);
    const onchainMarket = onchainMarketsByTokens[marketKey];
    if (!onchainMarket) {
      console.warn(
        "WARN onchain market with key %s does not exist. index: %s long: %s short: %s",
        marketKey,
        tokensByAddress[indexToken].symbol,
        tokensByAddress[longToken].symbol,
        tokensByAddress[shortToken].symbol
      );
      continue;
    }
    const marketToken = onchainMarket.marketToken;

    multicallReadParams.push({
      target: dataStore.address,
      allowFailure: false,
      callData: dataStore.interface.encodeFunctionData("getUint", [
        keys.positionImpactPoolDistributionRateKey(marketToken),
      ]),
    });
    multicallReadParams.push({
      target: dataStore.address,
      allowFailure: false,
      callData: dataStore.interface.encodeFunctionData("getUint", [keys.minPositionImpactPoolAmountKey(marketToken)]),
    });
  }

  const result = await multicall.callStatic.aggregate3(multicallReadParams);
  const dataCache = [];
  for (let i = 0; i < multicallReadParams.length; i++) {
    const value = bigNumberify(result[i].returnData);
    dataCache.push(value);
  }

  const multicallWriteParams = [];

  for (const [i, marketConfig] of markets.entries()) {
    const [indexToken, longToken, shortToken] = getMarketTokenAddresses(marketConfig, tokens);
    const marketKey = getMarketKey(indexToken, longToken, shortToken);
    const onchainMarket = onchainMarketsByTokens[marketKey];
    if (!onchainMarket) {
      continue;
    }
    const marketToken = onchainMarket.marketToken;

    if (
      (marketConfig.positionImpactPoolDistributionRate === undefined &&
        marketConfig.minPositionImpactPoolAmount !== undefined) ||
      (marketConfig.positionImpactPoolDistributionRate !== undefined &&
        marketConfig.minPositionImpactPoolAmount === undefined)
    ) {
      console.warn(
        "WARN: only one of impact fields is set for market %s positionImpactPoolDistributionRate=%s minPositionImpactPoolAmount=%s",
        marketToken,
        marketConfig.positionImpactExponentFactor,
        marketConfig.minPositionImpactPoolAmount
      );
    }
    if (
      marketConfig.positionImpactPoolDistributionRate === undefined ||
      marketConfig.minPositionImpactPoolAmount === undefined
    ) {
      continue;
    }

    const currentPositionImpactPoolDistributionRate = dataCache[i * 2];
    const currentMinPositionImpactPoolAmount = dataCache[i * 2 + 1];

    let wasChanged = false;

    const indexTokenConfig = tokensByAddress[indexToken];
    const longTokenConfig = tokensByAddress[longToken];
    const shortTokenConfig = tokensByAddress[shortToken];
    const marketLabel = `${indexTokenConfig?.symbol ?? "SPOT"} [${longTokenConfig.symbol}/${shortTokenConfig.symbol}]`;

    if (!currentPositionImpactPoolDistributionRate.eq(marketConfig.positionImpactPoolDistributionRate)) {
      const change = currentPositionImpactPoolDistributionRate.gt(0)
        ? bigNumberify(marketConfig.positionImpactPoolDistributionRate)
            .mul(10000)
            .div(currentPositionImpactPoolDistributionRate)
        : null;
      wasChanged = true;
      console.log(
        "positionImpactPoolDistributionRate    %s %s/day -> %s/day (%s)",
        marketLabel.padEnd(18),
        formatAmount(
          bigNumberify(currentPositionImpactPoolDistributionRate).mul(86400),
          30 + indexTokenConfig.decimals,
          4,
          true
        ),
        formatAmount(
          bigNumberify(marketConfig.positionImpactPoolDistributionRate).mul(86400),
          30 + indexTokenConfig.decimals,
          4,
          true
        ),
        change ? formatAmount(change, 4) + "x" : "-"
      );
    }

    if (!currentMinPositionImpactPoolAmount.eq(marketConfig.minPositionImpactPoolAmount)) {
      const change = currentMinPositionImpactPoolAmount.gt(0)
        ? bigNumberify(marketConfig.minPositionImpactPoolAmount).mul(10000).div(currentMinPositionImpactPoolAmount)
        : null;
      wasChanged = true;
      console.log(
        "minPositionImpactPoolAmount           %s %s -> %s (%s)",
        marketLabel.padEnd(18),
        formatAmount(currentMinPositionImpactPoolAmount, indexTokenConfig.decimals, 2, true),
        formatAmount(marketConfig.minPositionImpactPoolAmount, indexTokenConfig.decimals, 2, true),
        change ? formatAmount(change, 4) + "x" : "-"
      );
    }

    if (wasChanged) {
      multicallWriteParams.push(
        config.interface.encodeFunctionData("setPositionImpactDistributionRate", [
          marketToken,
          marketConfig.minPositionImpactPoolAmount,
          marketConfig.positionImpactPoolDistributionRate,
        ])
      );
    }
  }

  if (multicallWriteParams.length === 0) {
    console.log("configuration was not changed. skip update");
    return;
  }

  console.log(`updating ${multicallWriteParams.length} params`);
  console.log("multicallWriteParams", multicallWriteParams);

  let write = process.env.WRITE === "true";
  if (!write) {
    ({ write } = await prompts({
      type: "confirm",
      name: "write",
      message: "Do you want to execute the transactions?",
    }));
  }

  if (write) {
    const tx = await config.multicall(multicallWriteParams);
    console.log(`tx sent: ${tx.hash}`);
  } else {
    console.log("NOTE: executed in read-only mode, no transactions were sent");
  }
}

main()
  .then(() => {
    process.exit(0);
  })
  .catch((ex) => {
    console.error(ex);
    process.exit(1);
  });
