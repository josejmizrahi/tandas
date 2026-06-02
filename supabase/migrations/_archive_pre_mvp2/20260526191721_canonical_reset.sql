-- CanonicalReset.sql — nuke public schema before applying canonical
drop schema if exists public cascade;
create schema public;

grant usage on schema public to anon, authenticated, service_role;
grant all   on schema public to postgres, service_role;

alter default privileges in schema public
  grant all on tables    to postgres, service_role;
alter default privileges in schema public
  grant all on functions to postgres, service_role;
alter default privileges in schema public
  grant all on sequences to postgres, service_role;
alter default privileges in schema public
  grant all on types     to postgres, service_role;

alter default privileges in schema public
  grant select on tables to anon, authenticated;
