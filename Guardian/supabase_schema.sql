-- Enable PostGIS for location queries
create extension if not exists postgis;

-- 1. PROFILES
create table public.profiles (
  id uuid references auth.users not null primary key,
  phone text,
  full_name text,
  avatar_url text,
  push_token text,
  updated_at timestamp with time zone default timezone('utc'::text, now())
);
alter table public.profiles enable row level security;

create policy "Public profiles are viewable by everyone." on public.profiles
  for select using (true);

create policy "Users can insert their own profile." on public.profiles
  for insert with check (auth.uid() = id);

create policy "Users can update own profile." on public.profiles
  for update using (auth.uid() = id);

-- 2. GROUPS
create table public.groups (
  id uuid default uuid_generate_v4() primary key,
  name text not null,
  join_code text unique not null,
  created_by uuid references public.profiles(id),
  created_at timestamp with time zone default timezone('utc'::text, now())
);
alter table public.groups enable row level security;

-- 3. GROUP MEMBERS
create table public.group_members (
  id uuid default uuid_generate_v4() primary key,
  group_id uuid references public.groups(id) on delete cascade,
  user_id uuid references public.profiles(id) on delete cascade,
  role text default 'member', -- 'admin', 'member'
  joined_at timestamp with time zone default timezone('utc'::text, now()),
  unique(group_id, user_id)
);
alter table public.group_members enable row level security;

-- Policy: Members can see other members in their groups
create policy "Members can view group members" on public.group_members
  for select using (
    auth.uid() in (
      select user_id from public.group_members where group_id = group_members.group_id
    )
  );

-- 4. LOCATIONS (History & Current)
create table public.locations (
  id uuid default uuid_generate_v4() primary key,
  user_id uuid references public.profiles(id) not null,
  lat float not null,
  long float not null,
  speed float,
  heading float,
  battery_level float,
  timestamp timestamp with time zone default timezone('utc'::text, now())
);
alter table public.locations enable row level security;

-- Index for geospatial queries (optional but good for future)
create index locations_geo_index on public.locations using gist (st_setsrid(st_makepoint(long, lat), 4326));

-- Policy: Users can see locations of people in their groups
create policy "Group members can see locations" on public.locations
  for select using (
    auth.uid() in (
      select user_id from public.group_members where group_id in (
        select group_id from public.group_members where user_id = locations.user_id
      )
    )
  );

create policy "Users can insert their own location" on public.locations
  for insert with check (auth.uid() = user_id);

-- 5. ALERTS (Emergency)
create table public.alerts (
  id uuid default uuid_generate_v4() primary key,
  user_id uuid references public.profiles(id) not null,
  group_id uuid references public.groups(id), -- Optional: specific group or all groups?
  type text default 'emergency',
  status text default 'active', -- 'active', 'resolved'
  agora_channel_token text,
  created_at timestamp with time zone default timezone('utc'::text, now())
);
alter table public.alerts enable row level security;

create policy "Anyone in group can see alerts" on public.alerts
  for select using (
    auth.uid() in (
      select user_id from public.group_members where group_id = alerts.group_id
      -- OR logic for 'all friends' if strictly peer-to-peer
    )
  );

create policy "Users can create alerts" on public.alerts
  for insert with check (auth.uid() = user_id);
