export type JsonObject = Record<string, unknown>;

export type WhatsAppRuntime = {
  id: string;
  admin_user_id: string;
  store_id: string;
  user_id?: string;
  user_role?: string;
  name: string;
  phone_number_id: string;
  business_account_id: string;
  display_phone_number?: string;
  app_id?: string;
  graph_api_version: string;
  webhook_url?: string;
  status: string;
  secrets: {
    access_token: string;
    app_secret: string;
    verify_token: string;
  };
};

export type QueueJob = {
  id: string;
  admin_user_id: string;
  store_id: string;
  connection_id: string;
  message_id?: string | null;
  campaign_id?: string | null;
  campaign_recipient_id?: string | null;
  idempotency_key: string;
  payload: JsonObject;
  attempt_count: number;
  max_attempts: number;
  messages_per_second?: number;
  reserved_dispatch_at?: string | null;
  dispatch_at?: string | null;
};

export type MetaErrorPayload = {
  error?: {
    message?: string;
    type?: string;
    code?: number;
    error_subcode?: number;
    fbtrace_id?: string;
    error_data?: JsonObject;
  };
};

export type NormalizedWebhookMessage = {
  provider_message_id: string;
  type: string;
  text?: string;
  sent_at: string;
  reply_to_provider_message_id?: string;
  media?: JsonObject;
  raw: JsonObject;
};

export type NormalizedWebhookStatus = {
  provider_message_id: string;
  status: string;
  timestamp: string;
  recipient_id?: string;
  biz_opaque_callback_data?: string;
  conversation?: JsonObject;
  pricing?: JsonObject;
  error_code?: string;
  error_message?: string;
  raw: JsonObject;
};
