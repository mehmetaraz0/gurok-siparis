-- ============================================================
--  GUROK SİPARİŞ — Supabase kurulumu
--  Supabase panelinde:  SQL Editor  →  New query  →  bu dosyayı yapıştır  →  Run
--
--  ÖNEMLİ: Aşağıdaki 'BURAYA_SIFRE_YAZ' yerine kendi depo şifreni yaz.
-- ============================================================

create extension if not exists pgcrypto with schema extensions;

-- ---------- Tablolar ----------

create table if not exists public.siparisler (
  id                uuid primary key default gen_random_uuid(),
  tarih             date not null,
  outlet_kod        text not null,
  outlet_ad         text not null,
  kalemler          jsonb not null,
  gonderilme_saati  timestamptz not null default now(),
  unique (tarih, outlet_kod)          -- gün + outlet tekil: yeni gönderim eskisinin üzerine yazar
);

create index if not exists siparisler_tarih_idx on public.siparisler (tarih);

create table if not exists public.ayarlar (
  anahtar text primary key,
  deger   text not null
);

-- ---------- Kilit ----------
-- RLS açık ve HİÇBİR policy yok. Yani anon (tarayıcıdaki key) bu tablolara
-- doğrudan erişemez: ne okuyabilir, ne yazabilir. Tüm erişim aşağıdaki
-- SECURITY DEFINER fonksiyonlarından geçer.

alter table public.siparisler enable row level security;
alter table public.ayarlar    enable row level security;

revoke all on public.siparisler from anon, authenticated;
revoke all on public.ayarlar    from anon, authenticated;

-- ---------- Depo şifresi ----------
-- bcrypt ile saklanır; düz metin hiçbir yerde durmaz.
-- Şifreyi sonra değiştirmek için bu satırı yeni şifreyle tekrar çalıştırman yeterli.

insert into public.ayarlar (anahtar, deger)
values ('depo_sifre', extensions.crypt('BURAYA_SIFRE_YAZ', extensions.gen_salt('bf')))
on conflict (anahtar) do update set deger = excluded.deger;


-- ============================================================
--  1) BAR → sipariş gönderir
-- ============================================================

create or replace function public.siparis_gonder(
  p_outlet_kod text,
  p_outlet_ad  text,
  p_kalemler   jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_tarih date := (now() at time zone 'Europe/Istanbul')::date;
  v_saat  timestamptz;
begin
  if p_outlet_kod is null or p_outlet_kod !~ '^CSM[0-9]{3}$' then
    raise exception 'Gecersiz outlet kodu';
  end if;

  if jsonb_typeof(p_kalemler) <> 'array' or jsonb_array_length(p_kalemler) = 0 then
    raise exception 'Kalem listesi bos';
  end if;

  if jsonb_array_length(p_kalemler) > 5000 then
    raise exception 'Kalem listesi cok buyuk';
  end if;

  insert into siparisler (tarih, outlet_kod, outlet_ad, kalemler)
  values (v_tarih, p_outlet_kod, left(p_outlet_ad, 120), p_kalemler)
  on conflict (tarih, outlet_kod) do update
    set kalemler         = excluded.kalemler,
        outlet_ad        = excluded.outlet_ad,
        gonderilme_saati = now()
  returning gonderilme_saati into v_saat;

  return jsonb_build_object(
    'ok',   true,
    'saat', to_char(v_saat at time zone 'Europe/Istanbul', 'HH24:MI'),
    'ts',   (extract(epoch from v_saat) * 1000)::bigint
  );
end $$;


-- ============================================================
--  2) BAR → kendi bugünkü siparişini geri yükler
--     (sadece istenen outlet'in o günkü kaydını döner)
-- ============================================================

create or replace function public.siparis_getir(p_outlet_kod text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare r record;
begin
  select kalemler, gonderilme_saati into r
    from siparisler
   where tarih = (now() at time zone 'Europe/Istanbul')::date
     and outlet_kod = p_outlet_kod;

  if not found then
    return null;
  end if;

  return jsonb_build_object(
    'kalemler', r.kalemler,
    'saat',     to_char(r.gonderilme_saati at time zone 'Europe/Istanbul', 'HH24:MI'),
    'ts',       (extract(epoch from r.gonderilme_saati) * 1000)::bigint
  );
end $$;


-- ============================================================
--  3) DEPO → şifre doğruysa o günün tüm siparişlerini döner
-- ============================================================

create or replace function public.depo_liste(p_sifre text, p_tarih date default null)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_tarih date := coalesce(p_tarih, (now() at time zone 'Europe/Istanbul')::date);
begin
  if not exists (
    select 1 from ayarlar
     where anahtar = 'depo_sifre'
       and deger = extensions.crypt(coalesce(p_sifre, ''), deger)
  ) then
    raise exception 'Sifre hatali';
  end if;

  return coalesce((
    select jsonb_agg(
             jsonb_build_object(
               'outlet_kod',       outlet_kod,
               'outlet_ad',        outlet_ad,
               'kalemler',         kalemler,
               'gonderilme_saati', gonderilme_saati
             ) order by gonderilme_saati
           )
      from siparisler
     where tarih = v_tarih
  ), '[]'::jsonb);
end $$;


-- ---------- İzinler ----------
-- Tarayıcıdaki anon key SADECE bu üç fonksiyonu çağırabilir, başka hiçbir şeyi.

revoke all on function public.siparis_gonder(text, text, jsonb) from public;
revoke all on function public.siparis_getir(text)               from public;
revoke all on function public.depo_liste(text, date)            from public;

grant execute on function public.siparis_gonder(text, text, jsonb) to anon;
grant execute on function public.siparis_getir(text)               to anon;
grant execute on function public.depo_liste(text, date)            to anon;
