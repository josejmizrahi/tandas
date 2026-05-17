-- Mig 00228: grant `expenseSubmit` to the default founder role.
BEGIN;

alter table public.groups
  alter column roles set default jsonb_build_object(
    'founder', jsonb_build_object(
      'system', true,
      'permissions', jsonb_build_array(
        'modifyGovernance',
        'modifyRules',
        'modifyMembers',
        'assignRoles',
        'removeMember',
        'voidFine',
        'closeAppeal',
        'createVotes',
        'transferRight',
        'delegateRight',
        'revokeRight',
        'suspendRight',
        'exerciseRight',
        'expenseSubmit'
      )
    ),
    'member', jsonb_build_object(
      'system', true,
      'permissions', jsonb_build_array(
        'createVotes',
        'castVote'
      )
    )
  );

update public.groups g
   set roles = jsonb_set(
     g.roles,
     '{founder,permissions}',
     (
       select jsonb_agg(distinct p order by p)
         from jsonb_array_elements_text(
           coalesce(g.roles->'founder'->'permissions', '[]'::jsonb)
           || jsonb_build_array('expenseSubmit')
         ) as t(p)
     )
   )
 where g.roles ? 'founder'
   and g.roles->'founder' ? 'permissions';

do $$
declare
  v_count int;
begin
  select count(*) into v_count
    from public.groups
   where roles->'founder'->'permissions' ? 'expenseSubmit';
  raise notice 'mig 00228: % groups now grant founder.expenseSubmit', v_count;
end;
$$;

COMMIT;
