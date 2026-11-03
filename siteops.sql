-- MJ GreenGuard platform — site operations add-on (3 Nov 2026)
-- Adds tables only. Nothing existing is dropped, altered destructively or deleted.
-- Run once in Supabase → SQL Editor. Safe to run again (every statement is "if not exists").

-- who is this login on the crew list (each person links themselves once)
create table if not exists crew_links (
  user_id uuid primary key,
  org_id uuid not null references orgs on delete cascade,
  crew_id uuid not null references crew on delete cascade,
  created_at timestamptz default now());
alter table crew_links enable row level security;
drop policy if exists own_link on crew_links;
create policy own_link on crew_links for all
  using (org_id = my_org() and (user_id = auth.uid() or sees_money()))
  with check (org_id = my_org() and (user_id = auth.uid() or sees_money()));

-- crew names without rates, for people who do not see money
create or replace view crew_public as
  select id, org_id, name, role, active from crew where org_id = my_org();
grant select on crew_public to authenticated;

-- day roster: who is on which job, with what plant
create table if not exists rosters (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references orgs on delete cascade,
  job_id uuid not null references jobs on delete cascade,
  roster_date date not null,
  crew_ids uuid[] default '{}',
  plant text, note text,
  kind text default 'work',          -- work | maint
  created_at timestamptz default now());
alter table rosters enable row level security;
drop policy if exists org_read on rosters;
create policy org_read on rosters for select using (org_id = my_org());
drop policy if exists money_write on rosters;
create policy money_write on rosters for all
  using (org_id = my_org() and sees_money())
  with check (org_id = my_org() and sees_money());

-- clock in / clock out with GPS
create table if not exists shifts (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references orgs on delete cascade,
  job_id uuid not null references jobs on delete cascade,
  crew_id uuid references crew on delete set null,
  user_id uuid,
  started_at timestamptz not null default now(),
  ended_at timestamptz,
  break_min int default 0,
  hours numeric(6,2),
  start_lat double precision, start_lng double precision, start_acc double precision,
  end_lat double precision, end_lng double precision, end_acc double precision,
  note text,
  applied boolean default false,     -- pulled into the weekly timesheet
  created_at timestamptz default now());
alter table shifts enable row level security;
drop policy if exists org_read on shifts;
create policy org_read on shifts for select using (org_id = my_org());
drop policy if exists own_or_money on shifts;
create policy own_or_money on shifts for all
  using (org_id = my_org() and (user_id = auth.uid() or sees_money()))
  with check (org_id = my_org() and (user_id = auth.uid() or sees_money()));

-- site diary, one entry per job per day
create table if not exists site_diary (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references orgs on delete cascade,
  job_id uuid not null references jobs on delete cascade,
  diary_date date not null default current_date,
  weather text, on_site text, work text, deliveries text, issues text,
  created_by uuid,
  created_at timestamptz default now());
alter table site_diary enable row level security;
drop policy if exists org_read on site_diary;
create policy org_read on site_diary for select using (org_id = my_org());
drop policy if exists org_insert on site_diary;
create policy org_insert on site_diary for insert with check (org_id = my_org());
drop policy if exists own_or_money_update on site_diary;
create policy own_or_money_update on site_diary for update
  using (org_id = my_org() and (created_by = auth.uid() or sees_money()));
drop policy if exists money_delete on site_diary;
create policy money_delete on site_diary for delete using (org_id = my_org() and sees_money());

-- safety records: SWMS, toolbox talks, inductions, inspections, incidents
create table if not exists safety_records (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references orgs on delete cascade,
  job_id uuid not null references jobs on delete cascade,
  kind text not null default 'Toolbox talk',
  rec_date date not null default current_date,
  title text, note text, signed text,
  created_by uuid,
  created_at timestamptz default now());
alter table safety_records enable row level security;
drop policy if exists org_read on safety_records;
create policy org_read on safety_records for select using (org_id = my_org());
drop policy if exists org_insert on safety_records;
create policy org_insert on safety_records for insert with check (org_id = my_org());
drop policy if exists own_or_money_update on safety_records;
create policy own_or_money_update on safety_records for update
  using (org_id = my_org() and (created_by = auth.uid() or sees_money()));
drop policy if exists money_delete on safety_records;
create policy money_delete on safety_records for delete using (org_id = my_org() and sees_money());

-- photos on diary entries, safety records and clock-ins (stored in the site-files bucket)
create table if not exists site_files (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references orgs on delete cascade,
  job_id uuid references jobs on delete cascade,
  diary_id uuid references site_diary on delete cascade,
  safety_id uuid references safety_records on delete cascade,
  shift_id uuid references shifts on delete cascade,
  path text not null,
  uploaded_by uuid,
  created_at timestamptz default now());
alter table site_files enable row level security;
drop policy if exists org_read on site_files;
create policy org_read on site_files for select using (org_id = my_org());
drop policy if exists org_insert on site_files;
create policy org_insert on site_files for insert with check (org_id = my_org());
drop policy if exists money_delete on site_files;
create policy money_delete on site_files for delete using (org_id = my_org() and sees_money());

-- material and plant take-off vs ordered
create table if not exists materials (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references orgs on delete cascade,
  job_id uuid not null references jobs on delete cascade,
  kind text default 'Material',       -- Material | Plant
  area text, name text not null, size text, unit text,
  takeoff numeric(14,3) default 0,
  waste_pct numeric(6,2) default 5,
  note text,
  scope_item_id uuid references scope_items on delete set null,
  created_at timestamptz default now());
alter table materials enable row level security;
drop policy if exists money_only on materials;
create policy money_only on materials for all
  using (org_id = my_org() and sees_money())
  with check (org_id = my_org() and sees_money());

-- purchase orders; lines are kept on the order as JSON [{desc,qty,unit,rate,material_id}]
create table if not exists purchase_orders (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references orgs on delete cascade,
  job_id uuid not null references jobs on delete cascade,
  po_no text, supplier text not null, area text,
  order_date date default current_date,
  delivery_date date,
  status text default 'Ordered',      -- Ordered | Delivered | Cancelled
  items jsonb default '[]',
  total numeric(14,2) default 0,
  note text,
  delivered_on date,
  cost_id uuid,                        -- the cost row written when delivered
  created_at timestamptz default now());
alter table purchase_orders enable row level security;
drop policy if exists money_only on purchase_orders;
create policy money_only on purchase_orders for all
  using (org_id = my_org() and sees_money())
  with check (org_id = my_org() and sees_money());

-- job extras: site location, retention / defects period, maintenance plan
alter table jobs add column if not exists site_address text;
alter table jobs add column if not exists site_lat double precision;
alter table jobs add column if not exists site_lng double precision;
alter table jobs add column if not exists pc_date date;
alter table jobs add column if not exists dlp_weeks int default 52;
alter table jobs add column if not exists retention_pct numeric(5,2) default 5;
alter table jobs add column if not exists retention_cap_pct numeric(5,2) default 5;
alter table jobs add column if not exists ret_release1 numeric(14,2) default 0;
alter table jobs add column if not exists ret_release1_on date;
alter table jobs add column if not exists ret_release2 numeric(14,2) default 0;
alter table jobs add column if not exists ret_release2_on date;
alter table jobs add column if not exists ret_note text;
alter table jobs add column if not exists maint_start date;
alter table jobs add column if not exists maint_weeks int;
alter table jobs add column if not exists maint_freq text;
alter table jobs add column if not exists maint_scope text;
alter table jobs add column if not exists site_notes text;

-- retention held per claim (entered when the claim is certified)
alter table claims add column if not exists retention numeric(14,2) default 0;

notify pgrst, 'reload schema';

-- ---------------------------------------------------------------------
-- Data moved across from the GreenGuard Jobs artifact (3 Nov 2026)
-- Everything is "insert if not already there" by name, so it is safe to re-run.
-- ---------------------------------------------------------------------

-- company details used on the report headers
alter table orgs add column if not exists legal_name text;
alter table orgs add column if not exists abn text;
alter table orgs add column if not exists licence text;
alter table orgs add column if not exists address text;
alter table orgs add column if not exists phone text;
alter table orgs add column if not exists email text;
update orgs set
  legal_name = coalesce(legal_name, 'Match International Pty Ltd (ACN 664 904 885)'),
  address    = coalesce(address, 'Office 14, 5/22 Magnolia Drive, Brookwater QLD 4300')
where id = 'd8d20518-9dc7-4372-92a8-9eb0e2f5f4d8';

-- crew and internal cost rates (hourly); existing people are left exactly as they are
insert into crew (org_id, name, role, basis, rate, category, area, active)
select 'd8d20518-9dc7-4372-92a8-9eb0e2f5f4d8', v.n, v.r, 'Hourly', v.rate, v.cat, 'Stage 1', true
from (values
  ('Matt',               'Director / Estimator', 100, 'Labour'),
  ('Site Foreman (ABN)', 'Foreman',               80, 'Subcontractor'),
  ('Operator',           'Operator',              55, 'Labour'),
  ('Labourer 1',         'Labourer',              45, 'Labour'),
  ('Labourer 2',         'Labourer',              45, 'Labour')
) as v(n, r, rate, cat)
where not exists (select 1 from crew c where c.org_id = 'd8d20518-9dc7-4372-92a8-9eb0e2f5f4d8' and lower(c.name) = lower(v.n));

-- tenders being priced → Leads tab (status Quoting)
insert into leads (org_id, title, source, est_value, status, notes)
select 'd8d20518-9dc7-4372-92a8-9eb0e2f5f4d8', v.t, v.s, 0, 'Quoting', v.nt
from (values
  ('12 Business St, Yatala – Mica Properties warehouses',       'Mica Properties',        'LCP-1 / LCP-2 concept plan (Mark Baldock)'),
  ('Hollows Road, Flagstone – BluePoint mixed use',              '',                       'AGLA 26.103 – Landscape Works DLP + Streetscape/bio-basin'),
  ('330 Jackson Rd, Sunnybank Hills – TriCare aged care',        'TriCare',                'LAUD ink 2505-033'),
  ('11 McIlwraith St, Moffat Beach – unit development',          'Mick and Dulce Pty Ltd', 'The Landscape Group D25052'),
  ('Lot 70 Crestmead Logistics Estate, 261 Park Ridge Rd',       'Mackay Dreaver',         'The Landscape Group D24059 intent plan'),
  ('St Aidan''s Junior Play Space Stage 2',                      '',                       'VEE Design BOQ rev A'),
  ('St Ann''s School Redbank Plains Stage 5 (Shaun St)',         '',                       'Therefor Group 17-0574-05, packages A & C'),
  ('Toowoomba West Special School Stages 1 & 2 (D&C)',           '',                       'Jeremy Ferrier PN34-167334, 26 Gladstone St Newtown'),
  ('Heit Family Park, Willowbank – bioretention basin',          '',                       'INFO5160 / VP524608'),
  ('St Bonaventure''s College Flagstone Stage 2',                '',                       'CUSP 25076 – sportsfield turf, planting, drainage')
) as v(t, s, nt)
where not exists (select 1 from leads l where l.org_id = 'd8d20518-9dc7-4372-92a8-9eb0e2f5f4d8' and lower(l.title) = lower(v.t));

-- supplier buy rates → Price list (cost only; margin stays at your default)
insert into price_items (org_id, name, unit, cost, margin_pct, supplier, category, active)
select 'd8d20518-9dc7-4372-92a8-9eb0e2f5f4d8', v.n, v.u, v.c, 20, v.s, v.cat, true
from (values
  ('Soils, mulch, gravel – check current price', 'm3',   0, 'Centenary Landscaping Supplies', 'Materials'),
  ('Plants, tubestock, trees – check current price', 'ea', 0, 'Plantmark',                   'Plants')
) as v(n, u, c, s, cat)
where not exists (select 1 from price_items p where p.org_id = 'd8d20518-9dc7-4372-92a8-9eb0e2f5f4d8' and lower(p.supplier) = lower(v.s));

notify pgrst, 'reload schema';
