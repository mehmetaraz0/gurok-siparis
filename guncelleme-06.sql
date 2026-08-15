-- ============================================================
--  GUROK SİPARİŞ — Güncelleme 06  (STOK MODÜLÜ)
--
--  Stok sistemde tutulur:
--   • Baseline yükleme (KUM raporu → Kalan)  = stoğu mutlak değere eşitler
--   • Mal kabul yükleme (gelen)              = mevcut stoğa ekler
--   • Sipariş onayı                          = onaylanan miktar stoktan düşer
--     (kilit açılınca geri eklenir)
--   • Stoğu 0/negatif olan ürün bar/mutfak listesinde gizlenir
--
--  Supabase panelinde:  SQL Editor → New query → yapıştır → Run
-- ============================================================

create table if not exists public.stok (
  kod        text primary key,
  ad         text,
  birim      text,
  miktar     numeric not null default 0,
  guncelleme timestamptz not null default now()
);

alter table public.stok enable row level security;
revoke all on public.stok from anon, authenticated;


-- ============================================================
--  DEPO → baseline (KUM Kalan'a eşitle)
--  p_kalemler: [{k, a, b, m}]  (m = Kalan)
-- ============================================================

create or replace function public.stok_baseline(p_sifre text, p_kalemler jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare v_adet int;
begin
  if not exists (select 1 from ayarlar where anahtar='depo_sifre'
                 and deger = extensions.crypt(coalesce(p_sifre,''), deger)) then
    raise exception 'Sifre hatali';
  end if;
  if jsonb_typeof(p_kalemler) <> 'array' then raise exception 'Gecersiz veri'; end if;

  with veri as (
    select el->>'k' as kod, left(el->>'a',120) as ad, left(coalesce(el->>'b','ad'),20) as birim,
           (el->>'m')::numeric as miktar
      from jsonb_array_elements(p_kalemler) el
     where el->>'k' ~ '^[A-Z]{3}[0-9]{8}$'
       and (el->>'m') ~ '^-?[0-9]+(\.[0-9]+)?$'
  ),
  yaz as (
    insert into stok (kod, ad, birim, miktar, guncelleme)
    select kod, ad, birim, miktar, now() from veri
    on conflict (kod) do update
      set miktar = excluded.miktar, ad = excluded.ad,
          birim = excluded.birim, guncelleme = now()
    returning 1
  )
  select count(*) into v_adet from yaz;

  return jsonb_build_object('ok', true, 'adet', v_adet);
end $$;


-- ============================================================
--  DEPO → mal kabul (gelen miktarı ekle)
--  p_kalemler: [{k, a, b, m}]  (m = gelen; yalnızca >0 işlenir)
-- ============================================================

create or replace function public.stok_malkabul(p_sifre text, p_kalemler jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare v_adet int;
begin
  if not exists (select 1 from ayarlar where anahtar='depo_sifre'
                 and deger = extensions.crypt(coalesce(p_sifre,''), deger)) then
    raise exception 'Sifre hatali';
  end if;
  if jsonb_typeof(p_kalemler) <> 'array' then raise exception 'Gecersiz veri'; end if;

  with veri as (
    select el->>'k' as kod, left(el->>'a',120) as ad, left(coalesce(el->>'b','ad'),20) as birim,
           (el->>'m')::numeric as miktar
      from jsonb_array_elements(p_kalemler) el
     where el->>'k' ~ '^[A-Z]{3}[0-9]{8}$'
       and (el->>'m') ~ '^[0-9]+(\.[0-9]+)?$'
       and (el->>'m')::numeric > 0
  ),
  yaz as (
    insert into stok (kod, ad, birim, miktar, guncelleme)
    select kod, ad, birim, miktar, now() from veri
    on conflict (kod) do update
      set miktar = stok.miktar + excluded.miktar, guncelleme = now()
    returning 1
  )
  select count(*) into v_adet from yaz;

  return jsonb_build_object('ok', true, 'adet', v_adet);
end $$;


-- ============================================================
--  DEPO → stok listesi (sayılar; şifre ister)
-- ============================================================

create or replace function public.stok_liste(p_sifre text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not exists (select 1 from ayarlar where anahtar='depo_sifre'
                 and deger = extensions.crypt(coalesce(p_sifre,''), deger)) then
    raise exception 'Sifre hatali';
  end if;

  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'kod', kod, 'ad', ad, 'birim', birim,
             'miktar', miktar, 'guncelleme', guncelleme) order by kod)
      from stok), '[]'::jsonb);
end $$;


-- ============================================================
--  HERKESE AÇIK → yalnızca stoğu 0/negatif olan kodlar
--  Bar/mutfak bu kodları listelerinden gizler. Sayı sızmaz, sadece kod.
-- ============================================================

create or replace function public.stok_gizli_kodlar()
returns jsonb
language sql
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(kod), '[]'::jsonb) from stok where miktar <= 0;
$$;


-- ============================================================
--  depo_durum_degistir — onayda stok düş, kilit açılınca geri ekle
-- ============================================================

create or replace function public.depo_durum_degistir(
  p_sifre      text,
  p_siparis_no text,
  p_durum      text
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_saat  timestamptz;
  v_eski  text;
begin
  if not exists (select 1 from ayarlar where anahtar='depo_sifre'
                 and deger = extensions.crypt(coalesce(p_sifre,''), deger)) then
    raise exception 'Sifre hatali';
  end if;

  if p_durum not in ('talep', 'onaylandi') then
    raise exception 'Gecersiz durum';
  end if;

  select durum into v_eski from siparisler where siparis_no = p_siparis_no;
  if not found then raise exception 'Siparis bulunamadi'; end if;

  -- talep -> onaylandi : stoktan düş
  if p_durum = 'onaylandi' and v_eski = 'talep' then
    update stok s set miktar = s.miktar - x.mik, guncelleme = now()
      from (
        select el->>'k' as kod,
               coalesce((el->>'o')::numeric, (el->>'m')::numeric) as mik
          from siparisler ss, jsonb_array_elements(ss.kalemler) el
         where ss.siparis_no = p_siparis_no
      ) x
     where s.kod = x.kod and x.mik > 0;

  -- onaylandi -> talep : geri ekle (kilit açma)
  elsif p_durum = 'talep' and v_eski = 'onaylandi' then
    update stok s set miktar = s.miktar + x.mik, guncelleme = now()
      from (
        select el->>'k' as kod,
               coalesce((el->>'o')::numeric, (el->>'m')::numeric) as mik
          from siparisler ss, jsonb_array_elements(ss.kalemler) el
         where ss.siparis_no = p_siparis_no
      ) x
     where s.kod = x.kod and x.mik > 0;
  end if;

  update siparisler
     set durum = p_durum,
         onay_saati = case when p_durum='onaylandi' then now() else null end
   where siparis_no = p_siparis_no
  returning onay_saati into v_saat;

  return jsonb_build_object('ok', true, 'durum', p_durum,
    'saat', case when v_saat is null then null
                 else to_char(v_saat at time zone 'Europe/Istanbul', 'HH24:MI') end);
end $$;


-- ---------- İzinler ----------

revoke all on function public.stok_baseline(text, jsonb)         from public;
revoke all on function public.stok_malkabul(text, jsonb)         from public;
revoke all on function public.stok_liste(text)                   from public;
revoke all on function public.stok_gizli_kodlar()                from public;
revoke all on function public.depo_durum_degistir(text, text, text) from public;

grant execute on function public.stok_baseline(text, jsonb)         to anon;
grant execute on function public.stok_malkabul(text, jsonb)         to anon;
grant execute on function public.stok_liste(text)                   to anon;
grant execute on function public.stok_gizli_kodlar()                to anon;
grant execute on function public.depo_durum_degistir(text, text, text) to anon;
