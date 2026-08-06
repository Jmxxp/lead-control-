export type JsonObject = Record<string, unknown>;

export type MarketingProvider = "meta" | "google";

export type MarketingConnectionRuntime = {
  id: string;
  admin_user_id: string;
  store_id: string;
  provider: MarketingProvider;
  name: string;
  status: string;
  account_external_id: string;
  account_name?: string | null;
  api_version: string;
  token_expires_at?: string | null;
  public_config: JsonObject;
  secrets: JsonObject;
};

export type MarketingMetric = {
  metric_date: string;
  provider: MarketingProvider;
  account_external_id: string;
  campaign_external_id?: string;
  campaign_name?: string;
  adset_external_id?: string;
  adset_name?: string;
  ad_external_id?: string;
  ad_name?: string;
  creative_external_id?: string;
  currency?: string;
  spend?: number;
  impressions?: number;
  reach?: number;
  clicks?: number;
  platform_leads?: number;
  platform_conversions?: number;
  conversion_value?: number;
  raw_metrics?: JsonObject;
};

export type MarketingSyncJob = {
  id: string;
  connection_id: string;
  admin_user_id: string;
  store_id: string;
  provider: MarketingProvider;
  start_date: string;
  end_date: string;
  attempt_count: number;
  max_attempts: number;
  sync_run_id: string;
};

export type MarketingConversionJob = {
  id: string;
  connection_id: string;
  admin_user_id: string;
  store_id: string;
  provider: MarketingProvider;
  lead_id: string;
  event_name: string;
  event_at: string;
  event_id: string;
  attempt_count: number;
  max_attempts: number;
  payload: JsonObject;
};

export type MarketingConversionDiagnosticJob = {
  id: string;
  connection_id: string;
  admin_user_id: string;
  store_id: string;
  provider: "google";
  event_id: string;
  request_id: string;
  diagnostic_attempt_count: number;
  submitted_at: string;
};

export type ProviderRequestErrorDetails = {
  status?: number;
  provider_code?: string;
  provider_subcode?: string;
  response?: unknown;
};
