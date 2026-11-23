-- =====================================================================
--  RIY@ KLOSET: DATABASE SETUP
--  Run this ONCE in Supabase → SQL Editor → New query → paste → Run.
--  Safe to re-run: it won't duplicate tables or delete data.
--
--  Creates:
--    admins     who can manage the shop
--    products   the stock (new clothes, bags, shoes, phones)
--    settings   shop details (WhatsApp, MoMo, hours, delivery fees)
--    profiles   customer accounts (name, phone, area)
--    orders     orders + pickup bookings
--    storage    "product-images" bucket for photos
--  plus Row Level Security so visitors can only READ what they should.
-- =====================================================================


-- ---------------------------------------------------------------------
-- ADMINS
-- ---------------------------------------------------------------------
create table if not exists public.admins (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);
alter table public.admins enable row level security;
drop policy if exists "admins: see own row" on public.admins;
create policy "admins: see own row" on public.admins for select using (user_id = auth.uid());

create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.admins where user_id = auth.uid());
$$;

-- keeps updated_at fresh
create or replace function public.touch_updated_at()
returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end $$;

-- ---------------------------------------------------------------------
-- PRODUCTS
-- ---------------------------------------------------------------------
create table if not exists public.products (
  id           uuid primary key default gen_random_uuid(),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  category     text not null check (category in ('men','women','bags','shoes','phones')),
  name         text not null check (char_length(name) between 2 and 120),
  price        numeric(10,2) not null check (price >= 0),
  old_price    numeric(10,2) check (old_price is null or old_price >= 0),
  condition    text not null default 'New' check (condition in ('New','Like New','Very Good','Good','UK Used','Refurbished')),
  sizes        text[] not null default '{}',
  stock        int not null default 1 check (stock >= 0),
  fresh        boolean not null default false,
  description  text not null default '' check (char_length(description) <= 1000),
  measurements text not null default '' check (char_length(measurements) <= 200),
  images       text[] not null default '{}',
  status       text not null default 'active' check (status in ('active','sold','hidden')),
  -- phones only
  brand   text, storage text, ram text, colour text,
  battery int check (battery is null or battery between 0 and 100),
  in_box  text
);
create index if not exists products_status_created on public.products (status, created_at desc);
drop trigger if exists products_touch on public.products;
create trigger products_touch before update on public.products for each row execute function public.touch_updated_at();

alter table public.products enable row level security;
drop policy if exists "products: public reads active" on public.products;
drop policy if exists "products: admin insert" on public.products;
drop policy if exists "products: admin update" on public.products;
drop policy if exists "products: admin delete" on public.products;
create policy "products: public reads active" on public.products for select using (status = 'active' or public.is_admin());
create policy "products: admin insert" on public.products for insert with check (public.is_admin());
create policy "products: admin update" on public.products for update using (public.is_admin()) with check (public.is_admin());
create policy "products: admin delete" on public.products for delete using (public.is_admin());

-- ---------------------------------------------------------------------
-- SETTINGS (one row, id = 1)
-- ---------------------------------------------------------------------
create table if not exists public.settings (
  id         int primary key default 1 check (id = 1),
  data       jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);
drop trigger if exists settings_touch on public.settings;
create trigger settings_touch before update on public.settings for each row execute function public.touch_updated_at();
alter table public.settings enable row level security;
drop policy if exists "settings: public read" on public.settings;
drop policy if exists "settings: admin insert" on public.settings;
drop policy if exists "settings: admin update" on public.settings;
create policy "settings: public read" on public.settings for select using (true);
create policy "settings: admin insert" on public.settings for insert with check (public.is_admin());
create policy "settings: admin update" on public.settings for update using (public.is_admin()) with check (public.is_admin());
insert into public.settings (id, data)
values (1, '{"city":"Accra","whatsapp":"233207411266","phone":"+233 20 741 1266","phone2":"+233 26 977 0536","address":"Accra Newtown, 37 Station, Accra, Ghana"}'::jsonb)
on conflict (id) do nothing;

-- ---------------------------------------------------------------------
-- CUSTOMER PROFILES (created automatically when someone signs up)
-- ---------------------------------------------------------------------
create table if not exists public.profiles (
  id         uuid primary key references auth.users(id) on delete cascade,
  full_name  text not null default '' check (char_length(full_name) <= 80),
  phone      text not null default '' check (char_length(phone) <= 20),
  area       text not null default '' check (char_length(area) <= 120),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
drop trigger if exists profiles_touch on public.profiles;
create trigger profiles_touch before update on public.profiles for each row execute function public.touch_updated_at();
alter table public.profiles enable row level security;
drop policy if exists "profiles: own read" on public.profiles;
drop policy if exists "profiles: own insert" on public.profiles;
drop policy if exists "profiles: own update" on public.profiles;
create policy "profiles: own read"   on public.profiles for select using (id = auth.uid() or public.is_admin());
create policy "profiles: own insert" on public.profiles for insert with check (id = auth.uid());
create policy "profiles: own update" on public.profiles for update using (id = auth.uid()) with check (id = auth.uid());

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, full_name, phone)
  values (new.id,
          left(coalesce(new.raw_user_meta_data->>'full_name', ''), 80),
          left(coalesce(new.raw_user_meta_data->>'phone', ''), 20))
  on conflict (id) do nothing;
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users for each row execute function public.handle_new_user();

-- ---------------------------------------------------------------------
-- ORDERS (incl. pickup bookings)
-- ---------------------------------------------------------------------
create table if not exists public.orders (
  id            uuid primary key default gen_random_uuid(),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  ref           text not null check (char_length(ref) <= 20),
  user_id       uuid references auth.users(id) on delete set null,
  customer_name text not null default '' check (char_length(customer_name) <= 80),
  phone         text not null default '' check (char_length(phone) <= 20),
  area          text not null default '' check (char_length(area) <= 120),
  delivery      text not null check (delivery in ('pickup','accra','nation')),
  pickup_at     timestamptz,
  items         jsonb not null check (jsonb_typeof(items) = 'array' and jsonb_array_length(items) between 1 and 30),
  total         numeric(10,2) not null check (total >= 0),
  payment       text not null default 'momo' check (payment in ('momo','cash')),
  status        text not null default 'new' check (status in ('new','confirmed','ready','collected','cancelled'))
);
create index if not exists orders_created on public.orders (created_at desc);
create index if not exists orders_pickup on public.orders (pickup_at) where delivery = 'pickup';
create index if not exists orders_user on public.orders (user_id);
drop trigger if exists orders_touch on public.orders;
create trigger orders_touch before update on public.orders for each row execute function public.touch_updated_at();

alter table public.orders enable row level security;
drop policy if exists "orders: customer creates own" on public.orders;
drop policy if exists "orders: read own or admin" on public.orders;
drop policy if exists "orders: admin update" on public.orders;
drop policy if exists "orders: admin delete" on public.orders;
create policy "orders: customer creates own" on public.orders for insert to authenticated
  with check (user_id = auth.uid() and status = 'new');
create policy "orders: read own or admin" on public.orders for select using (user_id = auth.uid() or public.is_admin());
create policy "orders: admin update" on public.orders for update using (public.is_admin()) with check (public.is_admin());
create policy "orders: admin delete" on public.orders for delete using (public.is_admin());

-- ---------------------------------------------------------------------
-- DELETE MY ACCOUNT (called from "My account" → Delete account)
-- Removes the login + profile; keeps past orders for the shop's records
-- with the customer's name and phone wiped.
-- ---------------------------------------------------------------------
create or replace function public.delete_my_account()
returns void language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception 'Not signed in'; end if;
  if exists (select 1 from public.admins where user_id = uid) then
    raise exception 'Admin accounts cannot be deleted from the shop page';
  end if;
  update public.orders
     set customer_name = '(deleted account)', phone = '', area = '', user_id = null
   where user_id = uid;
  delete from auth.users where id = uid;   -- profile is removed by ON DELETE CASCADE
end $$;
revoke all on function public.delete_my_account() from public, anon;
grant execute on function public.delete_my_account() to authenticated;

-- ---------------------------------------------------------------------
-- PHOTO STORAGE
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('product-images', 'product-images', true, 5242880, array['image/webp','image/jpeg','image/png'])
on conflict (id) do nothing;

drop policy if exists "product-images: public read" on storage.objects;
drop policy if exists "product-images: admin upload" on storage.objects;
drop policy if exists "product-images: admin update" on storage.objects;
drop policy if exists "product-images: admin delete" on storage.objects;
create policy "product-images: public read" on storage.objects for select using (bucket_id = 'product-images');
create policy "product-images: admin upload" on storage.objects for insert to authenticated
  with check (bucket_id = 'product-images' and public.is_admin());
create policy "product-images: admin update" on storage.objects for update to authenticated
  using (bucket_id = 'product-images' and public.is_admin());
create policy "product-images: admin delete" on storage.objects for delete to authenticated
  using (bucket_id = 'product-images' and public.is_admin());

-- ---------------------------------------------------------------------
-- TABLE ACCESS for the website (newer Supabase projects don't grant this
-- automatically). Row Level Security above still decides what each
-- person can actually see or change.
-- ---------------------------------------------------------------------
grant usage on schema public to anon, authenticated;
grant select on public.products, public.settings to anon, authenticated;
grant insert, update, delete on public.products, public.settings to authenticated;
grant select, insert, update on public.profiles to authenticated;
grant select, insert, update, delete on public.orders to authenticated;
grant select on public.admins to authenticated;
grant execute on function public.is_admin() to anon, authenticated;
grant execute on function public.delete_my_account() to authenticated;

-- =====================================================================
--  LAST STEP (after the owner has created her login, see README step 4):
--
--  insert into public.admins (user_id)
--  select id from auth.users where email = 'HER-EMAIL@example.com';
-- =====================================================================
