export type Network = "testnet" | "mainnet";
export type Asset = "usdc" | "hbar" | string;

export interface PrintwrightClientOptions {
  baseUrl?: string;
  accountId?: string;
  privateKey?: string | object;
  network?: Network;
  fetch?: typeof globalThis.fetch;
  autoAssociate?: boolean;
  sandbox?: boolean;
}

export interface SearchOptions {
  query: string;
  maxPriceCents?: number;
  material?: string;
  supports?: boolean;
  category?: string;
  collection?: string;
}

export interface LicenseOffer {
  kind: string;
  price_cents: number;
  currency: string;
  max_units?: number | null;
  terms?: Record<string, unknown>;
}

export interface ModelSummary {
  id: number;
  title: string;
  slug: string;
  category?: string | null;
  collections?: string[];
  license_offers: LicenseOffer[];
  printability?: Record<string, unknown>;
  [key: string]: unknown;
}

export interface SearchResponse {
  count: number;
  models: ModelSummary[];
}

export interface ModelDetails extends ModelSummary {
  description?: string;
  tags?: string[];
  file_hash?: string;
  designer?: Record<string, unknown>;
}

export interface QuoteOptions {
  modelId: number;
  license?: "personal" | "commercial_unit" | string;
  asset?: Asset;
}

export interface PurchaseOptions extends Partial<QuoteOptions> {
  quote?: PaymentQuote;
}

export interface BatchItem {
  modelId: number;
  license?: "personal" | "commercial_unit" | string;
}

export interface BatchWebhook {
  url: string;
  secret: string;
}

export interface BatchPaymentQuote {
  items: ReadonlyArray<{ model_id: number; license: string }>;
  webhook?: Readonly<BatchWebhook>;
  resourceUrl: string;
  requestBody: string;
  paymentRequired: Record<string, unknown> & { accepts?: Array<Record<string, unknown>> };
  accepted: Record<string, unknown> & { asset: string; amount: string; payTo: string };
  sandbox: boolean;
  responseHeaders: Record<string, string>;
}

export interface BatchPurchaseReceipt {
  batch_id: number;
  transaction_id: string;
  hashscan_url: string | null;
  sandbox: boolean;
  licenses: Array<{
    model_id: number; kind: string; cert_id: string; serial: number;
    max_units: number | null; remaining_units: number | null; share_card_url?: string;
    verify_url: string; files: Array<{ kind: string; url: string; expires_at?: string | null }>;
    print_feedback?: PrintFeedbackCapability;
    model_updates?: ModelUpdatesCapability;
  }>;
}

export interface PrintFeedbackCapability {
  url: string;
  receipt_token: string;
}

export interface ModelUpdatesCapability {
  url: string;
  download_url: string;
  receipt_token: string;
}

export interface ModelVersionReceipt {
  cert_id: string;
  version: number;
  file_kind: string;
  file_hash: string;
  original_certificate_hash: string;
  changelog?: string | null;
  changelog_hash?: string | null;
  published_at?: string | null;
  hcs_topic_id?: string | null;
  hcs_sequence_number?: number | null;
  hcs_transaction_id?: string | null;
  hcs_mirror_url?: string | null;
  download_url: string;
}

export interface PrintReportReceipt {
  cert_id: string;
  successful_prints: number;
}

export interface PaymentQuote {
  modelId: number;
  license: string;
  resourceUrl: string;
  paymentRequired: Record<string, unknown> & { accepts?: Array<Record<string, unknown>> };
  accepted: Record<string, unknown> & { asset: string; amount: string; payTo: string };
  sandbox: boolean;
  responseHeaders: Record<string, string>;
}

export interface PurchaseReceipt {
  files: Array<{ kind: string; url: string; expires_at?: string | null; sandbox?: boolean }>;
  license: { cert_id: string; serial: number; kind: string; max_units?: number | null; remaining_units?: number | null };
  verify_url: string;
  share_card_url?: string;
  transaction_id: string;
  hashscan_url: string | null;
  print_feedback?: PrintFeedbackCapability;
  model_updates?: ModelUpdatesCapability;
  sandbox?: boolean;
  warning?: string;
  sandbox_url?: string;
  [key: string]: unknown;
}

export interface CertificateProof {
  status: string;
  certificate?: Record<string, unknown>;
  hcs?: Record<string, unknown>;
  match: boolean | null;
  onchain?: Record<string, unknown>;
  consensus_timestamp?: string;
  note?: string;
  [key: string]: unknown;
}

export type LicenseUse = "personal_print" | "commercial_print" | "resell_files" |
  "share_files" | "personal_remix" | "commercial_remix" | "transfer_license" | "sublicense";

export interface LicenseDecision {
  cert_id: string;
  use: LicenseUse | string;
  qty: number;
  allowed: boolean;
  reason_code: string;
  reason: string;
  permissions?: Record<string, unknown> | null;
  terms?: Record<string, unknown>;
  [key: string]: unknown;
}

export class PrintwrightError extends Error {
  status?: number;
  body?: unknown;
}

export class PrintwrightClient {
  constructor(options?: PrintwrightClientOptions);
  search(options: SearchOptions): Promise<SearchResponse>;
  get(modelId: number): Promise<ModelDetails>;
  quote(options: QuoteOptions): Promise<PaymentQuote>;
  buy(options: PurchaseOptions): Promise<PurchaseReceipt>;
  quoteBatch(options: { items: BatchItem[]; asset?: Asset; webhook?: BatchWebhook }): Promise<BatchPaymentQuote>;
  buyBatch(options: { items?: BatchItem[]; asset?: Asset; webhook?: BatchWebhook; quote?: BatchPaymentQuote }): Promise<BatchPurchaseReceipt>;
  can(options: { certId: string; use: LicenseUse | string; qty?: number }): Promise<LicenseDecision>;
  reportPrint(options: { certId: string; receiptToken: string }): Promise<PrintReportReceipt>;
  latestVersion(options: { certId: string; receiptToken: string }): Promise<ModelVersionReceipt>;
  verify(certId: string): Promise<CertificateProof>;
}

export const assets: Readonly<Record<Network, Readonly<{ usdc: string; hbar: string }>>>;
