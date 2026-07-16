// V3 kill-test page (browser side): pair HashPack, fetch a REAL 402 from the
// local app, build the same foreign-feePayer TransferTransaction the x402
// client builds, ask the wallet to SIGN AND RETURN (never execute), then
// decode the returned bytes and report the verdict.
//
// Build:  npx esbuild scripts/spike/hashpack/page.mjs --bundle --minify \
//           --outfile=public/spike/hashpack.js   (run from repo root)
// Serve:  bin/dev, then open http://localhost:3000/spike/hashpack.html
import { HashConnect } from "hashconnect";
import {
  AccountId,
  Client,
  LedgerId,
  TokenId,
  Transaction,
  TransactionId,
  TransferTransaction,
} from "@hashgraph/sdk";

const el = (id) => document.getElementById(id);
const log = (msg) => {
  el("log").textContent += `${msg}\n`;
  console.log(msg);
};

let hashconnect;
let pairedAccount;

el("pair").addEventListener("click", async () => {
  const projectId = el("projectId").value.trim();
  if (!projectId) return log("! paste a WalletConnect Cloud project id first (free at cloud.reown.com)");
  localStorage.setItem("wc-project-id", projectId);

  hashconnect = new HashConnect(
    LedgerId.TESTNET,
    projectId,
    { name: "Printwright V3 spike", description: "x402 foreign-feePayer signature spike", icons: [], url: window.location.origin },
    true
  );
  hashconnect.pairingEvent.on((session) => {
    pairedAccount = session.accountIds[0];
    log(`ok paired: ${pairedAccount}`);
    el("sign").disabled = false;
  });
  await hashconnect.init();
  hashconnect.openPairingModal();
  log("pairing modal opened — approve in HashPack");
});

el("sign").addEventListener("click", async () => {
  try {
    // 1. real 402 from the local app
    const search = await (await fetch("/api/v1/models?q=snap+cable+clip", { headers: { accept: "application/json" } })).json();
    const model = search.models[0];
    const res = await fetch(`/api/v1/models/${model.id}/download?license=commercial_unit`, { headers: { accept: "application/json" } });
    if (res.status !== 402) return log(`! expected 402, got ${res.status}`);
    const paymentRequired = await res.json();
    const accept = paymentRequired.accepts.find((a) => a.asset !== "0.0.0") ?? paymentRequired.accepts[0];
    const feePayer = accept.extra.feePayer;
    log(`ok 402: pay ${accept.amount} of ${accept.asset} -> ${accept.payTo} (feePayer ${feePayer})`);

    // 2. the x402 transaction shape: buyer debit, payTo credit, feePayer's txId
    const buyer = AccountId.fromString(pairedAccount);
    const tx = new TransferTransaction();
    if (accept.asset === "0.0.0") {
      tx.addHbarTransfer(buyer, -Number(accept.amount) / 1e8);
      tx.addHbarTransfer(AccountId.fromString(accept.payTo), Number(accept.amount) / 1e8);
    } else {
      const token = TokenId.fromString(accept.asset);
      tx.addTokenTransfer(token, buyer, -Number(accept.amount));
      tx.addTokenTransfer(token, AccountId.fromString(accept.payTo), Number(accept.amount));
    }
    tx.setTransactionId(TransactionId.generate(AccountId.fromString(feePayer)));
    tx.freezeWith(Client.forTestnet());

    // 3. sign-and-return — the wallet must NOT submit
    log("requesting signature from HashPack (approve in the wallet)...");
    const signed = await hashconnect.signTransaction(buyer, tx);

    // 4. decode the returned bytes and judge
    const bytes = signed.toBytes();
    const decoded = Transaction.fromBytes(bytes);
    const sigPairs = decoded._signedTransactions.list[0]?.sigMap?.sigPair ?? [];
    const verdict = {
      spike: "V3 hashpack foreign-feePayer sign-and-return",
      paired_account: pairedAccount,
      tx_id: decoded.transactionId?.toString(),
      tx_id_account_is_fee_payer: decoded.transactionId?.accountId?.toString() === feePayer,
      signature_count: sigPairs.length,
      signature_present: sigPairs.length > 0,
      transaction_base64: btoa(String.fromCharCode(...bytes)),
    };
    log("\n=== VERDICT (copy into the wire-log) ===");
    log(JSON.stringify(verdict, null, 2));

    // 5. prove not-submitted: the mirror must NOT know this tx id
    const mirrorId = verdict.tx_id.replace("@", "-").replace(/\.(\d+)$/, "-$1");
    setTimeout(async () => {
      const check = await fetch(`https://testnet.mirrornode.hedera.com/api/v1/transactions/${mirrorId}`);
      log(`mirror lookup after 6s -> ${check.status} (404 = not submitted, as required)`);
    }, 6000);
  } catch (e) {
    log(`! ${e.message ?? e}`);
    console.error(e);
  }
});

el("projectId").value = localStorage.getItem("wc-project-id") ?? "";
