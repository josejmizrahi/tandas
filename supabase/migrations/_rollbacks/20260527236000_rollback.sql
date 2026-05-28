-- Rollback for 20260527236000_register_my_notification_token.sql

drop function if exists public.register_my_notification_token(text, text);
