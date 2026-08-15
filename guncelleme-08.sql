-- ============================================================
--  GUROK SİPARİŞ — Güncelleme 08  (DÜZENLENEBİLİR KATALOG)
--
--  Bar/mutfak ürün listeleri artık Supabase'de tutulur ve admin
--  şifresiyle düzenlenebilir. Bar/mutfak listesini buluttan çeker;
--  bulut boşsa/ulaşılamazsa gömülü veri.js listesine düşer.
--
--  ÖNEMLİ: Aşağıdaki BURAYA_ADMIN_SIFRE_YAZ yerine yönetici şifresini yaz.
--  (Depo şifresinden farklı olsun.)
--
--  Supabase panelinde:  SQL Editor → New query → yapıştır → Run
-- ============================================================

create table if not exists public.katalog (
  liste text not null,          -- bar: "CSM315" · mutfak: "CMM201|KAHVALTI"
  kod   text not null,
  ad    text not null,
  birim text not null default 'ad',
  grup  text,
  sira  int  not null default 0,
  primary key (liste, kod)
);
create index if not exists katalog_liste_idx on public.katalog (liste, sira);

alter table public.katalog enable row level security;
revoke all on public.katalog from anon, authenticated;

-- Yönetici şifresi (bcrypt)
insert into public.ayarlar (anahtar, deger)
values ('admin_sifre', extensions.crypt('BURAYA_ADMIN_SIFRE_YAZ', extensions.gen_salt('bf')))
on conflict (anahtar) do update set deger = excluded.deger;

-- Ortak admin şifre kontrolü
create or replace function public.admin_dogru(p_sifre text)
returns boolean
language sql
security definer
set search_path = public, extensions
as $$
  select exists (select 1 from ayarlar where anahtar='admin_sifre'
                 and deger = extensions.crypt(coalesce(p_sifre,''), deger));
$$;


-- ============================================================
--  HERKESE AÇIK → bir listenin ürünleri (bar/mutfak yükler)
-- ============================================================

create or replace function public.katalog_getir(p_liste text)
returns jsonb
language sql
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(
           jsonb_build_object('k', kod, 'a', ad, 'b', birim, 'g', grup, 'sira', sira)
           order by sira), '[]'::jsonb)
    from katalog where liste = p_liste;
$$;


-- ============================================================
--  ADMIN → şifre kontrolü (giriş)
-- ============================================================

create or replace function public.katalog_giris(p_sifre text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not admin_dogru(p_sifre) then raise exception 'Sifre hatali'; end if;
  return jsonb_build_object('ok', true);
end $$;


-- ============================================================
--  ADMIN → tüm listeyi yaz (tohumlama / toplu değiştirme)
--  p_kalemler: [{k,a,b,g,sira}]
-- ============================================================

create or replace function public.katalog_seed(p_sifre text, p_liste text, p_kalemler jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare v_adet int;
begin
  if not admin_dogru(p_sifre) then raise exception 'Sifre hatali'; end if;
  if p_liste is null or p_liste = '' then raise exception 'Liste bos'; end if;
  if jsonb_typeof(p_kalemler) <> 'array' then raise exception 'Gecersiz veri'; end if;

  delete from katalog where liste = p_liste;

  with veri as (
    select el->>'k' as kod, left(el->>'a',120) as ad,
           left(coalesce(el->>'b','ad'),20) as birim,
           left(coalesce(el->>'g',''),60) as grup,
           coalesce((el->>'sira')::int, 0) as sira
      from jsonb_array_elements(p_kalemler) el
     where el->>'k' ~ '^[A-Z]{3}[0-9]{8}$' and coalesce(el->>'a','') <> ''
  ),
  yaz as (
    insert into katalog (liste, kod, ad, birim, grup, sira)
    select p_liste, kod, ad, birim, nullif(grup,''), sira from veri
    on conflict (liste, kod) do update
      set ad=excluded.ad, birim=excluded.birim, grup=excluded.grup, sira=excluded.sira
    returning 1
  )
  select count(*) into v_adet from yaz;

  return jsonb_build_object('ok', true, 'adet', v_adet);
end $$;


-- ============================================================
--  ADMIN → ürün ekle / çıkar / düzelt / sırala
-- ============================================================

create or replace function public.katalog_ekle(
  p_sifre text, p_liste text, p_kod text, p_ad text, p_birim text, p_grup text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare v_sira int;
begin
  if not admin_dogru(p_sifre) then raise exception 'Sifre hatali'; end if;
  if coalesce(p_kod,'') !~ '^[A-Z]{3}[0-9]{8}$' then raise exception 'Gecersiz kod (ornek: ICA02000001)'; end if;
  if coalesce(p_ad,'') = '' then raise exception 'Ad bos olamaz'; end if;

  select coalesce(max(sira),0)+1 into v_sira from katalog where liste = p_liste;
  insert into katalog (liste, kod, ad, birim, grup, sira)
  values (p_liste, p_kod, left(p_ad,120), left(coalesce(p_birim,'ad'),20),
          nullif(left(coalesce(p_grup,''),60),''), v_sira)
  on conflict (liste, kod) do update
    set ad=excluded.ad, birim=excluded.birim, grup=excluded.grup;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.katalog_cikar(p_sifre text, p_liste text, p_kod text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not admin_dogru(p_sifre) then raise exception 'Sifre hatali'; end if;
  delete from katalog where liste = p_liste and kod = p_kod;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.katalog_duzelt(
  p_sifre text, p_liste text, p_kod text, p_ad text, p_birim text, p_grup text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not admin_dogru(p_sifre) then raise exception 'Sifre hatali'; end if;
  if coalesce(p_ad,'') = '' then raise exception 'Ad bos olamaz'; end if;
  update katalog
     set ad = left(p_ad,120), birim = left(coalesce(p_birim,'ad'),20),
         grup = nullif(left(coalesce(p_grup,''),60),'')
   where liste = p_liste and kod = p_kod;
  if not found then raise exception 'Urun bulunamadi'; end if;
  return jsonb_build_object('ok', true);
end $$;

-- p_kodlar: yeni sıradaki kod dizisi
create or replace function public.katalog_sira(p_sifre text, p_liste text, p_kodlar jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not admin_dogru(p_sifre) then raise exception 'Sifre hatali'; end if;
  update katalog k set sira = x.ord
    from (select value as kod, ordinality as ord
            from jsonb_array_elements_text(p_kodlar) with ordinality) x
   where k.liste = p_liste and k.kod = x.kod;
  return jsonb_build_object('ok', true);
end $$;


-- ---------- İzinler ----------
revoke all on function public.katalog_getir(text)                         from public;
revoke all on function public.katalog_giris(text)                         from public;
revoke all on function public.katalog_seed(text, text, jsonb)             from public;
revoke all on function public.katalog_ekle(text, text, text, text, text, text) from public;
revoke all on function public.katalog_cikar(text, text, text)             from public;
revoke all on function public.katalog_duzelt(text, text, text, text, text, text) from public;
revoke all on function public.katalog_sira(text, text, jsonb)             from public;

grant execute on function public.katalog_getir(text)                         to anon;
grant execute on function public.katalog_giris(text)                         to anon;
grant execute on function public.katalog_seed(text, text, jsonb)             to anon;
grant execute on function public.katalog_ekle(text, text, text, text, text, text) to anon;
grant execute on function public.katalog_cikar(text, text, text)             to anon;
grant execute on function public.katalog_duzelt(text, text, text, text, text, text) to anon;
grant execute on function public.katalog_sira(text, text, jsonb)             to anon;
