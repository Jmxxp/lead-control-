begin;

alter function app_private.rpc_get_attendance_analysis_v1(text, uuid, text, text, uuid, text, text, date, date)
  volatile;

alter function public.lc_get_attendance_analysis_v1(text, uuid, text, text, uuid, text, text, date, date)
  volatile;

notify pgrst, 'reload schema';

commit;
