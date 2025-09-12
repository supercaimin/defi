const { sendTxn, contractAt } = require("../shared/helpers")
const { formatAmount } = require("../../test/shared/utilities")
const { getValues } = require("../shared/fundAccountsUtils")

async function main() {
  const { sender, transfers, totalTransferAmount, tokens, gasToken } = await getValues()

  for (let i = 0; i < transfers.length; i++) {
    const transferItem = transfers[i]

    if (transferItem.amount.eq(0)) {
      continue
    }

    await sendTxn(sender.sendTransaction({
      to: transferItem.address,
      value: transferItem.amount
    }), `${formatAmount(transferItem.amount, 18, 2)} ${gasToken} to ${transferItem.address}`)
  }
}

main()
  .then(() => process.exit(0))
  .catch(error => {
    console.error(error)
    process.exit(1)
  })
