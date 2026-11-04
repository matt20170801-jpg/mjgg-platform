-- Crew self-registration (4 Nov 2026). Run once in Supabase → SQL Editor.
-- A new sign-up with the right join code gets a profile as "crew" automatically.
-- Email confirmation: Supabase → Authentication → Providers → Email → turn OFF "Confirm email"
-- so crew can sign in straight away (or leave it on and they click the email link first).

alter table orgs add column if not exists join_code text;
update orgs set join_code = coalesce(join_code, 'GREENGUARD') where id = 'd8d20518-9dc7-4372-92a8-9eb0e2f5f4d8';

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
declare o uuid; code text; nm text;
begin
  code := coalesce(new.raw_user_meta_data->>'join_code','');
  nm   := coalesce(new.raw_user_meta_data->>'full_name', split_part(new.email,'@',1));
  select id into o from orgs where upper(join_code) = upper(code) limit 1;
  if o is null then return new; end if;          -- wrong or missing code: no profile, app shows a message
  insert into profiles (id, org_id, role, full_name)
  values (new.id, o, 'crew', nm)
  on conflict (id) do nothing;
  insert into crew (org_id, name, role, basis, rate, category, area, active)
  select o, nm, 'Labourer', 'Hourly', 0, 'Labour', 'Stage 1', true
  where not exists (select 1 from crew c where c.org_id = o and lower(c.name) = lower(nm));
  insert into crew_links (user_id, org_id, crew_id)
  select new.id, o, c.id from crew c where c.org_id = o and lower(c.name) = lower(nm) limit 1
  on conflict (user_id) do nothing;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- let the app read the join code only to check it client-side is NOT needed; the trigger checks it.
notify pgrst, 'reload schema';
