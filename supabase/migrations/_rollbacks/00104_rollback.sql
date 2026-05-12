-- Rollback for 00104 — drops the polymorphic resources_view.

drop view if exists public.resources_view;
