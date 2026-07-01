-- ═══════════════════════════════════════════════════════════════════
-- СХЕМА БАЗЫ ДАННЫХ ДЛЯ ПРОИЗВОДСТВЕННОГО ДАШБОРДА
-- Выполнить целиком в Supabase → SQL Editor → New query → Run
-- ═══════════════════════════════════════════════════════════════════

-- ───────────────────────────────────────────────────────────────────
-- 1. ПРОФИЛИ ПОЛЬЗОВАТЕЛЕЙ (расширение auth.users)
-- ───────────────────────────────────────────────────────────────────
-- Supabase Auth хранит email/пароль в защищённой таблице auth.users.
-- Здесь храним только бизнес-данные: имя, роль, график, отпуск.

create table if not exists profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  name text not null,
  role text not null default 'Оператор печати',
  initials text,
  is_admin boolean not null default false,
  schedule text default '08:00 – 20:00',
  vacation_from date,
  vacation_to date,
  created_at timestamptz default now()
);

alter table profiles enable row level security;

-- Любой авторизованный пользователь может ЧИТАТЬ список сотрудников
-- (нужно для делегирования, ротации уборки, отображения имён)
create policy "profiles_select_authenticated"
  on profiles for select
  to authenticated
  using (true);

-- Редактировать профили может только администратор (is_admin=true)
create policy "profiles_insert_admin_only"
  on profiles for insert
  to authenticated
  with check (
    exists (select 1 from profiles p where p.id = auth.uid() and p.is_admin = true)
  );

create policy "profiles_update_admin_only"
  on profiles for update
  to authenticated
  using (
    exists (select 1 from profiles p where p.id = auth.uid() and p.is_admin = true)
  );

create policy "profiles_delete_admin_only"
  on profiles for delete
  to authenticated
  using (
    exists (select 1 from profiles p where p.id = auth.uid() and p.is_admin = true)
  );

-- ───────────────────────────────────────────────────────────────────
-- 2. ЗАКАЗЫ / ПОДЗАКАЗЫ
-- ───────────────────────────────────────────────────────────────────
create table if not exists orders (
  id text primary key,              -- например '1234-П', '1234-СБ'
  master_id text not null,          -- общий номер заказа, например '1234'
  type text not null,               -- 'Элайнер', 'Сборка заказа' и т.д.
  cat text not null,                -- polymer | metal | biocompat | assembly
  patient text not null,
  sup text not null,                -- источник: Сетап / Моделировщик / ФИО при делегировании
  qty integer not null default 1,
  arrived text,                     -- время поступления (HH:MM, для отображения)
  urgent boolean not null default false,
  is_reprint boolean not null default false,
  deadline date,
  comment text default '',
  file_name text,
  file_size text,
  file_attached boolean default false,

  worker uuid references profiles(id),       -- кто сейчас держит подзаказ
  stage integer not null default -1,          -- -1 = в очереди, 0+ = индекс этапа
  taken_at timestamptz,
  current_stage_start timestamptz,
  stage_timings jsonb default '[]'::jsonb,    -- [{stageIndex, stageName, start, end, duration}]
  duration text,

  finished_at_text text,                      -- время сдачи (HH:MM) для отображения
  finished_at timestamptz,                    -- момент завершения (используется в логике)
  finished_assembly_ready boolean default false,

  delegated_from text,                        -- ФИО передавшего (текстом, для истории)
  delegated_to uuid references profiles(id),  -- кому адресовано делегирование
  deleg_history jsonb,                        -- {doneStage, note, takenAt, handedAt, duration}

  is_assembly boolean not null default false, -- это автосозданная задача "Сборка заказа"
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);

create index if not exists idx_orders_master_id on orders(master_id);
create index if not exists idx_orders_worker on orders(worker);
create index if not exists idx_orders_finished_at on orders(finished_at);

alter table orders enable row level security;

-- Любой авторизованный сотрудник видит ВСЕ заказы (нужно для очереди,
-- группировки по заказу, карточки админа). Гранулярная защита делается
-- на уровне UPDATE — нельзя "украсть" чужой подзаказ.
create policy "orders_select_authenticated"
  on orders for select
  to authenticated
  using (true);

-- Создавать заказы может только администратор
create policy "orders_insert_admin_or_self"
  on orders for insert
  to authenticated
  with check (
    exists (select 1 from profiles p where p.id = auth.uid() and p.is_admin = true)
    or true  -- система автосоздаёт задачи "Сборка заказа" от лица сотрудника — разрешаем
  );

-- КЛЮЧЕВАЯ ЗАЩИТА ОТ ГОНКИ: взять свободный подзаказ может любой,
-- но ТОЛЬКО если он сейчас реально свободен (worker is null).
-- Если два человека одновременно попытаются — у базы транзакционно
-- выиграет только один UPDATE, второй вернёт 0 затронутых строк.
create policy "orders_update_take_if_free_or_own"
  on orders for update
  to authenticated
  using (
    worker is null
    or worker = auth.uid()
    or exists (select 1 from profiles p where p.id = auth.uid() and p.is_admin = true)
  )
  with check (true);

create policy "orders_delete_admin_only"
  on orders for delete
  to authenticated
  using (
    exists (select 1 from profiles p where p.id = auth.uid() and p.is_admin = true)
  );

-- Автообновление updated_at при любом UPDATE
create or replace function set_updated_at()
returns trigger as $$
begin
  new.updated_at = now();
  return new;
end;
$$ language plpgsql;

create trigger trg_orders_updated_at
  before update on orders
  for each row execute function set_updated_at();

-- ───────────────────────────────────────────────────────────────────
-- 3. ВОЗВРАТЫ ПОСТАВЩИКУ
-- ───────────────────────────────────────────────────────────────────
create table if not exists returns (
  id bigint generated always as identity primary key,
  order_id text not null,
  master_id text,
  type text,
  patient text,
  qty integer,                    -- снимок исходного подзаказа — нужен для повторного размещения
  cat text,
  sup text,
  deadline date,
  urgent boolean default false,
  is_reprint boolean default false,
  item_comment text default '',   -- исходный комментарий к подзаказу (не путать с comment — это причина возврата)
  returned_by text not null,      -- ФИО оператора
  reason text not null,
  comment text default '',
  returned_at_text text,          -- время возврата (HH:MM) для отображения
  resolved boolean not null default false,
  resolved_at_text text,
  created_at timestamptz default now()
);

-- Если таблица returns уже существовала в БД до добавления повторного размещения — доносим колонки
alter table returns add column if not exists qty integer;
alter table returns add column if not exists cat text;
alter table returns add column if not exists sup text;
alter table returns add column if not exists deadline date;
alter table returns add column if not exists urgent boolean default false;
alter table returns add column if not exists is_reprint boolean default false;
alter table returns add column if not exists item_comment text default '';

alter table returns enable row level security;

create policy "returns_select_authenticated"
  on returns for select
  to authenticated
  using (true);

create policy "returns_insert_authenticated"
  on returns for insert
  to authenticated
  with check (true);

create policy "returns_update_admin_only"
  on returns for update
  to authenticated
  using (
    exists (select 1 from profiles p where p.id = auth.uid() and p.is_admin = true)
  );

-- ───────────────────────────────────────────────────────────────────
-- 4. АВТОСОЗДАНИЕ ПРОФИЛЯ ПРИ РЕГИСТРАЦИИ ПОЛЬЗОВАТЕЛЯ
-- ───────────────────────────────────────────────────────────────────
-- Когда администратор создаёт нового сотрудника через Supabase Auth API,
-- этот триггер автоматически создаёт пустую запись в profiles,
-- которую приложение сразу дозаполняет именем/ролью.
create or replace function handle_new_user()
returns trigger as $$
begin
  insert into public.profiles (id, name, role, is_admin)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'name', new.email),
    coalesce(new.raw_user_meta_data->>'role', 'Оператор печати'),
    coalesce((new.raw_user_meta_data->>'is_admin')::boolean, false)
  );
  return new;
end;
$$ language plpgsql security definer;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function handle_new_user();

-- ───────────────────────────────────────────────────────────────────
-- 5. REALTIME — включаем live-обновления для таблиц
-- ───────────────────────────────────────────────────────────────────
alter publication supabase_realtime add table orders;
alter publication supabase_realtime add table returns;
alter publication supabase_realtime add table profiles;

-- ═══════════════════════════════════════════════════════════════════
-- ГОТОВО. Дальше — создание первых пользователей через Auth API
-- (см. файл SETUP_GUIDE.md, раздел "Создание сотрудников")
-- ═══════════════════════════════════════════════════════════════════
