begin;

alter function app_private.rpc_list_leads_v2(text) volatile;
alter function app_private.rpc_list_prospection_bonus_purchases(text, date, date, uuid) volatile;

commit;
