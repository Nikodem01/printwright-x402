import {
  HederaAdapter,
  HederaChainDefinition,
  HederaProvider,
  hederaNamespace,
} from "@hashgraph/hedera-wallet-connect";
import { createAppKit } from "@reown/appkit";
import {
  buildPaymentTransaction,
  paymentSignatureHeaders,
  selectAcceptedPayment,
} from "./payment.js";

class PrintwrightBrowserWallet {
  constructor(element) {
    this.element = element;
    this.projectId = element.dataset.projectId;
    this.network = element.dataset.network;
    this.connectButton = element.querySelector("[data-wallet-connect]");
    this.disconnectButton = element.querySelector("[data-wallet-disconnect]");
    this.connectionWaiters = [];
  }

  async init() {
    const network = this.network === "mainnet"
      ? HederaChainDefinition.Native.Mainnet
      : HederaChainDefinition.Native.Testnet;
    const metadata = {
      name: "Printwright",
      description: "License 3D-printable models over x402 on Hedera.",
      url: window.location.origin,
      icons: [`${window.location.origin}/icon-192.png`],
    };
    const adapter = new HederaAdapter({
      projectId: this.projectId,
      networks: [network],
      namespace: hederaNamespace,
    });
    this.provider = await HederaProvider.init({ projectId: this.projectId, metadata });
    this.appKit = createAppKit({
      adapters: [adapter],
      universalProvider: this.provider,
      projectId: this.projectId,
      metadata,
      networks: [network],
      defaultNetwork: network,
      features: { analytics: false, email: false, socials: [] },
      termsConditionsUrl: `${window.location.origin}/terms`,
      privacyPolicyUrl: `${window.location.origin}/privacy`,
    });
    this.appKit.subscribeAccount((account) => {
      this.accountId = account?.isConnected ? account.address : null;
      this.render();
      if (this.accountId) this.connectionWaiters.splice(0).forEach((resolve) => resolve(this.accountId));
    }, hederaNamespace);
    this.accountId = this.appKit.getAccount(hederaNamespace)?.address || null;
    this.render();
  }

  async connect() {
    this.setBusy("Opening wallet…");
    try {
      await this.appKit.open({ view: "Connect" });
      this.render();
    } catch (error) {
      this.render(error?.message || "Wallet connection was cancelled");
    }
  }

  async disconnect() {
    this.setBusy("Disconnecting…");
    try {
      await this.appKit.disconnect(hederaNamespace);
      this.accountId = null;
      this.render();
    } catch (error) {
      this.render(error?.message || "Could not disconnect wallet");
    }
  }

  async sign(paymentRequired) {
    const accountId = this.accountId || await this.connectForPayment();
    const { accepted, amount } = selectAcceptedPayment(paymentRequired, this.network);
    const transaction = buildPaymentTransaction({ accepted, amount, accountId, network: this.network });
    const signed = await this.provider.hedera_signTransaction({
      signerAccountId: `hedera:${this.network}:${accountId}`,
      transactionBody: transaction,
    });
    return paymentSignatureHeaders(paymentRequired, accepted, signed);
  }

  async connectForPayment() {
    const connected = new Promise((resolve, reject) => {
      this.connectionWaiters.push(resolve);
      let opened = false;
      const unsubscribe = this.appKit.subscribeState((state) => {
        opened ||= state.open;
        if (opened && !state.open && !this.accountId) {
          unsubscribe();
          this.connectionWaiters = this.connectionWaiters.filter((waiter) => waiter !== resolve);
          reject(new Error("Wallet connection was cancelled"));
        }
      });
      setTimeout(() => {
        unsubscribe();
        this.connectionWaiters = this.connectionWaiters.filter((waiter) => waiter !== resolve);
        reject(new Error("Wallet connection timed out"));
      }, 120000);
    });
    await this.appKit.open({ view: "Connect" });
    return connected;
  }

  setBusy(label) {
    this.connectButton.disabled = true;
    this.connectButton.textContent = label;
    this.disconnectButton.hidden = true;
  }

  render(error) {
    this.connectButton.disabled = false;
    this.connectButton.textContent = this.accountId || "Connect wallet";
    this.connectButton.setAttribute("aria-label", this.accountId ? `Connected wallet ${this.accountId}` : "Connect Hedera wallet");
    this.disconnectButton.hidden = !this.accountId;
    this.element.dataset.connected = this.accountId ? "true" : "false";
    this.element.title = error || (this.accountId ? `Connected on Hedera ${this.network}` : `Pay with a Hedera ${this.network} wallet`);
    window.dispatchEvent(new CustomEvent("printwright:wallet-change", {
      detail: { accountId: this.accountId, network: this.network, error },
    }));
  }
}

async function boot() {
  const element = document.querySelector("[data-hedera-wallet]");
  if (!element) throw new Error("Wallet controls are not present on this page");
  const wallet = new PrintwrightBrowserWallet(element);
  window.PrintwrightWallet = wallet;
  await wallet.init();
  return wallet;
}

window.PrintwrightWalletReady = boot();
