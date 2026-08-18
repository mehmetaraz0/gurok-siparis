-- ============================================================
--  GUROK SİPARİŞ — TEK KURULUM DOSYASI (birleşik + sağlamlaştırılmış)
--
--  Bu dosya, kurulum + guncelleme-01..14'ün TAMAMINI ve güvenlik
--  sertleştirmesini tek, İDEMPOTENT betikte toplar. Sıfırdan kuran biri
--  yalnızca bunu çalıştırır. MEVCUT bir veritabanında çalıştırmak da
--  güvenlidir: veriler, şifreler ve PIN'ler KORUNUR.
--
--  Supabase panelinde:  SQL Editor → New query → yapıştır → Run
--
--  SIFIRDAN KURULUMDA: aşağıdaki BURAYA_DEPO_SIFRE / BURAYA_ADMIN_SIFRE
--  yerlerini değiştir (mevcut kurulumda dokunma — eskiler korunur).
-- ============================================================

create extension if not exists pgcrypto with schema extensions;

-- ================= TABLOLAR =================

create table if not exists public.siparisler (
  id                uuid primary key default gen_random_uuid(),
  tarih             date not null,
  outlet_kod        text not null,
  outlet_ad         text not null,
  kalemler          jsonb not null,
  gonderilme_saati  timestamptz not null default now(),
  siparis_no        text,
  durum             text not null default 'talep',
  onay_saati        timestamptz,
  bolum             text,
  istemci_id        text
);
-- Mevcut tabloya eksik sütunları ekle (eski kurulumdan geliyorsa)
alter table public.siparisler add column if not exists siparis_no text;
alter table public.siparisler add column if not exists durum      text not null default 'talep';
alter table public.siparisler add column if not exists onay_saati timestamptz;
alter table public.siparisler add column if not exists bolum      text;
alter table public.siparisler add column if not exists istemci_id text;
-- Eski "gün+outlet tekil" kısıtı kalktı (bir outlet günde çok sipariş verebilir)
alter table public.siparisler drop constraint if exists siparisler_tarih_outlet_kod_key;
alter table public.siparisler drop constraint if exists siparisler_durum_chk;
alter table public.siparisler add constraint siparisler_durum_chk check (durum in ('talep','onaylandi'));
create index if not exists siparisler_tarih_idx on public.siparisler (tarih);
create unique index if not exists siparisler_no_idx on public.siparisler (siparis_no);
create unique index if not exists siparisler_istemci_idx
  on public.siparisler (istemci_id) where istemci_id is not null;

create table if not exists public.ayarlar (
  anahtar text primary key,
  deger   text not null
);

-- Outlet allowlist (sahte outlet engellenir)
create table if not exists public.outletler (
  kod text primary key,
  ad  text not null,
  tur text not null default 'bar',   -- 'bar' | 'mutfak'
  pin text                            -- (eski tek-PIN sütunu; artık outlet_pin tablosu kullanılıyor)
);

-- Outlet başına 10'a kadar PIN — her biri farklı kişi/gönderen.
-- etiket = depoda görünen "gönderen" kodu (ör. kişi adı ya da 1..10).
create table if not exists public.outlet_pin (
  id         uuid primary key default gen_random_uuid(),
  outlet_kod text not null,
  etiket     text not null,
  pin        text not null,           -- bcrypt hash
  unique (outlet_kod, etiket)
);
create index if not exists outlet_pin_kod_idx on public.outlet_pin (outlet_kod);

-- Siparişe gönderen kimliği (hangi PIN/kişi) yazılır
alter table public.siparisler add column if not exists gonderen text;

-- Eski tek-PIN'leri çoklu tabloya taşı (etiket = '1')
insert into public.outlet_pin (outlet_kod, etiket, pin)
select kod, '1', pin from public.outletler where pin is not null
on conflict (outlet_kod, etiket) do nothing;

-- Kaptanlar: bara bağlı DEĞİL, kişi bazlı kimlik. Kaptan kendi PIN'iyle girer,
-- sipariş vereceği barı seçer. 'ad' depoda 'gönderen' olarak görünür.
create table if not exists public.kaptan (
  kod   text primary key,
  ad    text not null,
  pin   text not null,               -- bcrypt hash
  aktif boolean not null default true
);

create table if not exists public.stok (
  kod        text primary key,
  ad         text,
  birim      text,
  miktar     numeric not null default 0,
  guncelleme timestamptz not null default now()
);

create table if not exists public.katalog (
  liste text not null,
  kod   text not null,
  ad    text not null,
  birim text not null default 'ad',
  grup  text,
  sira  int  not null default 0,
  primary key (liste, kod)
);
create index if not exists katalog_liste_idx on public.katalog (liste, sira);

create table if not exists public.urun_min (
  kod        text primary key,
  min_miktar numeric,
  min_stok   numeric
);
alter table public.urun_min add column if not exists min_miktar numeric;
alter table public.urun_min add column if not exists min_stok   numeric;
alter table public.urun_min alter column min_miktar drop not null;
alter table public.urun_min drop constraint if exists urun_min_min_miktar_check;
alter table public.urun_min drop constraint if exists urun_min_min_miktar_chk;
alter table public.urun_min drop constraint if exists urun_min_min_stok_chk;
alter table public.urun_min add constraint urun_min_min_miktar_chk check (min_miktar is null or min_miktar > 0);
alter table public.urun_min add constraint urun_min_min_stok_chk   check (min_stok   is null or min_stok   >= 0);

-- ================= KİLİT (RLS) =================
-- Hepsinde RLS açık, HİÇBİR policy yok → anon key ile hiçbir tabloya
-- doğrudan erişilemez. Tüm erişim SECURITY DEFINER fonksiyonlarından geçer.
alter table public.siparisler enable row level security;
alter table public.ayarlar    enable row level security;
alter table public.outletler  enable row level security;
alter table public.outlet_pin enable row level security;
alter table public.stok       enable row level security;
alter table public.katalog    enable row level security;
alter table public.urun_min   enable row level security;
alter table public.kaptan     enable row level security;
revoke all on public.siparisler from anon, authenticated;
revoke all on public.ayarlar    from anon, authenticated;
revoke all on public.outletler  from anon, authenticated;
revoke all on public.outlet_pin from anon, authenticated;
revoke all on public.stok       from anon, authenticated;
revoke all on public.katalog    from anon, authenticated;
revoke all on public.urun_min   from anon, authenticated;
revoke all on public.kaptan     from anon, authenticated;

-- ================= ŞİFRELER (mevcut olan KORUNUR) =================
insert into public.ayarlar (anahtar, deger)
values ('depo_sifre', extensions.crypt('BURAYA_DEPO_SIFRE', extensions.gen_salt('bf')))
on conflict (anahtar) do nothing;

insert into public.ayarlar (anahtar, deger)
values ('admin_sifre', extensions.crypt('BURAYA_ADMIN_SIFRE', extensions.gen_salt('bf')))
on conflict (anahtar) do nothing;

-- ================= OUTLET TOHUMU (PIN'ler KORUNUR) =================
insert into public.outletler (kod, ad, tur) values
  ('CSM201', 'ALIBEY RESTAURANT', 'bar'),
  ('CSM202', 'PARK RESTAURANT', 'bar'),
  ('CSM204', 'SAHIL RESTAURANT', 'bar'),
  ('CSM205', 'AQUA RESTAURANT', 'bar'),
  ('CSM206', 'KIYI RESTAURANT', 'bar'),
  ('CSM301', 'TURK KAHVESI', 'bar'),
  ('CSM302', 'CARDAK', 'bar'),
  ('CSM303', 'TALVAR', 'bar'),
  ('CSM304', 'POOL', 'bar'),
  ('CSM305', 'ALI''S PUB', 'bar'),
  ('CSM306', 'TENIS BAR', 'bar'),
  ('CSM307', 'KONAK', 'bar'),
  ('CSM308', 'KARAGOZ', 'bar'),
  ('CSM310', 'ILICA BAR', 'bar'),
  ('CSM311', 'HARLEK', 'bar'),
  ('CSM312', 'HISAR', 'bar'),
  ('CSM313', 'YONCALI', 'bar'),
  ('CSM314', 'FRIG BEACH BAR', 'bar'),
  ('CSM315', 'PAVILLION BAR', 'bar'),
  ('CSM316', 'LOBBY BAR', 'bar'),
  ('CSM317', 'PARK TURK KAHVESI', 'bar'),
  ('CSM318', 'SARAP VE BIRA EVI', 'bar'),
  ('CMM201', 'ANAMUTFAK', 'mutfak'),
  ('CMM204', 'PARK MUTFAK', 'mutfak'),
  ('CMM202', 'AQUA MUTFAK', 'mutfak')
on conflict (kod) do update set ad = excluded.ad, tur = excluded.tur;


-- ================= YARDIMCILAR =================
create or replace function public.admin_dogru(p_sifre text)
returns boolean language sql security definer set search_path = public, extensions as $$
  select exists (select 1 from ayarlar where anahtar='admin_sifre'
                 and deger = extensions.crypt(coalesce(p_sifre,''), deger));
$$;

create or replace function public.depo_dogru(p_sifre text)
returns boolean language sql security definer set search_path = public, extensions as $$
  select exists (select 1 from ayarlar where anahtar='depo_sifre'
                 and deger = extensions.crypt(coalesce(p_sifre,''), deger));
$$;


-- ================= HERKESE AÇIK =================

-- Bar/mutfak girişi: outlet var mı + PIN doğru mu (PIN yoksa serbest).
-- Outlet'in birden çok PIN'i olabilir; girilen PIN hangisine uyuyorsa
-- o kişinin etiketi 'gonderen' olarak döner.
create or replace function public.outlet_giris(p_kod text, p_pin text default null)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v_ad text; v_var int; v_gonderen text;
begin
  select ad into v_ad from outletler where kod = p_kod;
  if not found then raise exception 'Gecersiz kod'; end if;

  select count(*) into v_var from outlet_pin where outlet_kod = p_kod;
  if v_var > 0 then
    select etiket into v_gonderen from outlet_pin
     where outlet_kod = p_kod and pin = extensions.crypt(coalesce(p_pin,''), pin) limit 1;
    if v_gonderen is null then raise exception 'PIN gerekli'; end if;
  end if;

  return jsonb_build_object('ok', true, 'kod', p_kod, 'ad', v_ad,
    'pinli', v_var > 0, 'gonderen', v_gonderen);
end $$;

-- Bir listenin ürünleri (min + minstok ile)
create or replace function public.katalog_getir(p_liste text)
returns jsonb language sql security definer set search_path = public as $$
  select coalesce(jsonb_agg(
           jsonb_build_object('k', k.kod, 'a', k.ad, 'b', k.birim, 'g', k.grup,
                              'sira', k.sira, 'min', m.min_miktar, 'minstok', m.min_stok)
           order by k.sira), '[]'::jsonb)
    from katalog k left join urun_min m on m.kod = k.kod
   where k.liste = p_liste;
$$;

-- Stoğu 0/negatif olan kodlar (bar/mutfak bunları gizler)
create or replace function public.stok_gizli_kodlar()
returns jsonb language sql security definer set search_path = public as $$
  select coalesce(jsonb_agg(kod), '[]'::jsonb) from stok where miktar <= 0;
$$;

-- BAR/MUTFAK → sipariş gönder (SAĞLAMLAŞTIRILMIŞ KÖPRÜ)
--  • outlet allowlist  • PIN (varsa)  • ad'ı SUNUCU belirler
--  • kalem kodu (seed'liyse) listede olmalı  • günlük hız sınırı
drop function if exists public.siparis_gonder(text, text, jsonb);
drop function if exists public.siparis_gonder(text, text, jsonb, text);
drop function if exists public.siparis_gonder(text, text, jsonb, text, text);
drop function if exists public.siparis_gonder(text, text, jsonb, text, text, text);

create or replace function public.siparis_gonder(
  p_outlet_kod  text,
  p_outlet_ad   text,               -- YOK SAYILIR (sunucu outletler'den alır)
  p_kalemler    jsonb,
  p_bolum       text default null,
  p_istemci_id  text default null,
  p_pin         text default null,
  p_kaptan_kod  text default null,  -- bar: kaptan kimliği
  p_kaptan_pin  text default null
)
returns jsonb
language plpgsql security definer set search_path = public, extensions
as $$
declare
  v_tarih date := (now() at time zone 'Europe/Istanbul')::date;
  v_no text; v_saat timestamptz; v_sira int; v_deneme int := 0;
  v_el jsonb; v_m numeric; v_ad text; v_liste text; v_gunluk int;
  v_pinvar int; v_gonderen text; v_tur text;
  v_iid text := nullif(left(coalesce(p_istemci_id, ''), 64), '');
  rec record;
begin
  -- 1) Outlet gerçek mi + kimlik. Bar => kaptan zorunlu; mutfak => outlet_pin (eski).
  --    ad'ı ve gonderen'i SUNUCU belirler.
  select ad, tur into v_ad, v_tur from outletler where kod = p_outlet_kod;
  if v_ad is null then raise exception 'Gecersiz outlet'; end if;

  if v_tur = 'bar' then
    -- Kaptan bazlı kimlik: geçerli + aktif kaptan PIN'i şart. gonderen = kaptan adı.
    select ad into v_gonderen from kaptan
     where kod = p_kaptan_kod and aktif
       and pin = extensions.crypt(coalesce(p_kaptan_pin,''), pin);
    if v_gonderen is null then raise exception 'Kaptan girisi gerekli'; end if;
  else
    -- Mutfak (ve diğer): outlet_pin akışı — DEĞİŞMEDİ.
    select count(*) into v_pinvar from outlet_pin where outlet_kod = p_outlet_kod;
    if v_pinvar > 0 then
      select etiket into v_gonderen from outlet_pin
       where outlet_kod = p_outlet_kod and pin = extensions.crypt(coalesce(p_pin,''), pin) limit 1;
      if v_gonderen is null then raise exception 'PIN hatali'; end if;
    end if;
  end if;

  -- 2) Kalem listesi biçimi
  if jsonb_typeof(p_kalemler) <> 'array' or jsonb_array_length(p_kalemler) = 0 then
    raise exception 'Kalem listesi bos';
  end if;
  if jsonb_array_length(p_kalemler) > 5000 then raise exception 'Kalem listesi cok buyuk'; end if;

  -- 3) Her kalem: biçim + kod deseni + alanlar + miktar
  for v_el in select * from jsonb_array_elements(p_kalemler) loop
    if jsonb_typeof(v_el) <> 'object' then raise exception 'Gecersiz kalem bicimi'; end if;
    if coalesce(v_el->>'k','') !~ '^[A-Z]{3}[0-9]{8}$' then raise exception 'Gecersiz kalem kodu'; end if;
    if coalesce(v_el->>'a','') = '' or length(v_el->>'a') > 120
       or coalesce(v_el->>'b','') = '' or length(v_el->>'b') > 20 then
      raise exception 'Gecersiz kalem alani';
    end if;
    if (v_el->>'m') is null or (v_el->>'m') !~ '^\d+$' then raise exception 'Gecersiz miktar'; end if;
    v_m := (v_el->>'m')::numeric;
    if v_m <= 0 or v_m > 100000 then raise exception 'Miktar araligi disinda'; end if;
  end loop;

  -- 4) Kalem kodları o listenin katalogunda olmalı (liste seed'liyse zorlanır;
  --    değilse gömülü listeyle çalışan bara izin verilir).
  v_liste := case when coalesce(p_bolum,'') <> '' then p_outlet_kod || '|' || p_bolum else p_outlet_kod end;
  if exists (select 1 from katalog where liste = v_liste) then
    if exists (
      select 1 from jsonb_array_elements(p_kalemler) el
       where not exists (select 1 from katalog k where k.liste = v_liste and k.kod = el->>'k')
    ) then raise exception 'Katalog disi kalem'; end if;
  end if;

  -- 5) Günlük hız sınırı (flood engeli): outlet başına 200
  select count(*) into v_gunluk from siparisler where tarih = v_tarih and outlet_kod = p_outlet_kod;
  if v_gunluk >= 200 then raise exception 'Gunluk siparis siniri asildi'; end if;

  -- 6) İdempotency: aynı istemci kimliği varsa var olanı döndür
  if v_iid is not null then
    select siparis_no, gonderilme_saati, jsonb_array_length(kalemler) into rec
      from siparisler where istemci_id = v_iid;
    if found then
      return jsonb_build_object('ok', true, 'tekrar', true, 'siparis_no', rec.siparis_no,
        'saat', to_char(rec.gonderilme_saati at time zone 'Europe/Istanbul','HH24:MI'),
        'kalem', rec.jsonb_array_length);
    end if;
  end if;

  -- 7) Numara üret (max+1) + yaz (outlet_ad = SUNUCU değeri)
  loop
    v_deneme := v_deneme + 1;
    select coalesce(max(split_part(siparis_no,'-',3)::int),0)+1 into v_sira
      from siparisler where tarih = v_tarih;
    v_no := 'SIP-' || to_char(v_tarih,'YYYYMMDD') || '-' || lpad(v_sira::text,3,'0');
    begin
      insert into siparisler (tarih, outlet_kod, outlet_ad, kalemler, siparis_no, durum, bolum, istemci_id, gonderen)
      values (v_tarih, p_outlet_kod, left(v_ad,120), p_kalemler, v_no, 'talep',
              nullif(left(coalesce(p_bolum,''),40),''), v_iid, v_gonderen)
      returning gonderilme_saati into v_saat;
      exit;
    exception when unique_violation then
      if v_iid is not null then
        select siparis_no, gonderilme_saati, jsonb_array_length(kalemler) into rec
          from siparisler where istemci_id = v_iid;
        if found then
          return jsonb_build_object('ok', true, 'tekrar', true, 'siparis_no', rec.siparis_no,
            'saat', to_char(rec.gonderilme_saati at time zone 'Europe/Istanbul','HH24:MI'),
            'kalem', rec.jsonb_array_length);
        end if;
      end if;
      if v_deneme >= 15 then raise exception 'Siparis numarasi uretilemedi, tekrar deneyin'; end if;
    end;
  end loop;

  return jsonb_build_object('ok', true, 'siparis_no', v_no,
    'saat', to_char(v_saat at time zone 'Europe/Istanbul','HH24:MI'),
    'kalem', jsonb_array_length(p_kalemler));
end $$;

-- Kaldırılan eski fonksiyon
drop function if exists public.siparis_getir(text);


-- ================= DEPO (şifre ister) =================

create or replace function public.depo_liste(p_sifre text, p_tarih date default null)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v_tarih date := coalesce(p_tarih, (now() at time zone 'Europe/Istanbul')::date);
begin
  if not depo_dogru(p_sifre) then raise exception 'Sifre hatali'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'siparis_no', siparis_no, 'outlet_kod', outlet_kod, 'outlet_ad', outlet_ad,
             'bolum', bolum, 'gonderen', gonderen, 'kalemler', kalemler,
             'gonderilme_saati', gonderilme_saati, 'durum', durum, 'onay_saati', onay_saati)
             order by gonderilme_saati desc)
      from siparisler where tarih = v_tarih), '[]'::jsonb);
end $$;

create or replace function public.depo_envanter(p_sifre text, p_bas date, p_bit date)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  v_bas date := coalesce(p_bas, (now() at time zone 'Europe/Istanbul')::date);
  v_bit date := coalesce(p_bit, (now() at time zone 'Europe/Istanbul')::date);
begin
  if not depo_dogru(p_sifre) then raise exception 'Sifre hatali'; end if;
  if v_bit < v_bas then raise exception 'Bitis tarihi baslangictan once olamaz'; end if;
  if v_bit - v_bas > 92 then raise exception 'En fazla 92 gunluk aralik sorgulanabilir'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'siparis_no', siparis_no, 'tarih', tarih, 'outlet_kod', outlet_kod,
             'outlet_ad', outlet_ad, 'bolum', bolum, 'gonderen', gonderen, 'kalemler', kalemler,
             'gonderilme_saati', gonderilme_saati, 'durum', durum, 'onay_saati', onay_saati)
             order by gonderilme_saati)
      from siparisler where tarih between v_bas and v_bit), '[]'::jsonb);
end $$;

create or replace function public.depo_kalem_guncelle(p_sifre text, p_siparis_no text, p_kalem_kod text, p_onay int)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v_durum text;
begin
  if not depo_dogru(p_sifre) then raise exception 'Sifre hatali'; end if;
  if p_onay is null or p_onay < 0 or p_onay > 100000 then raise exception 'Gecersiz miktar'; end if;
  select durum into v_durum from siparisler where siparis_no = p_siparis_no;
  if not found then raise exception 'Siparis bulunamadi'; end if;
  if v_durum = 'onaylandi' then raise exception 'Siparis kilitli, once kilidi acin'; end if;
  update siparisler set kalemler = (
      select jsonb_agg(case when el->>'k' = p_kalem_kod
                            then el || jsonb_build_object('o', p_onay) else el end order by ord)
        from jsonb_array_elements(kalemler) with ordinality as t(el, ord))
   where siparis_no = p_siparis_no;
  return jsonb_build_object('ok', true);
end $$;

-- Onayda TABAN STOK KESİN ENGEL + stok düş / kilit açınca geri ekle
create or replace function public.depo_durum_degistir(p_sifre text, p_siparis_no text, p_durum text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v_saat timestamptz; v_eski text; v_engel text;
begin
  if not depo_dogru(p_sifre) then raise exception 'Sifre hatali'; end if;
  if p_durum not in ('talep','onaylandi') then raise exception 'Gecersiz durum'; end if;
  select durum into v_eski from siparisler where siparis_no = p_siparis_no;
  if not found then raise exception 'Siparis bulunamadi'; end if;

  if p_durum = 'onaylandi' and v_eski = 'talep' then
    select string_agg(s.ad || ' (' || st.miktar || '->' || (st.miktar - s.mik)
                      || ', min ' || um.min_stok || ')', ', ') into v_engel
      from (select el->>'k' kod, el->>'a' ad,
                   coalesce((el->>'o')::numeric,(el->>'m')::numeric) mik
              from siparisler ss, jsonb_array_elements(ss.kalemler) el
             where ss.siparis_no = p_siparis_no) s
      join stok st on st.kod = s.kod
      join urun_min um on um.kod = s.kod
     where um.min_stok is not null and s.mik > 0 and (st.miktar - s.mik) < um.min_stok;
    if v_engel is not null then raise exception 'Taban stok engeli: %', v_engel; end if;

    update stok s set miktar = s.miktar - x.mik, guncelleme = now()
      from (select el->>'k' kod, coalesce((el->>'o')::numeric,(el->>'m')::numeric) mik
              from siparisler ss, jsonb_array_elements(ss.kalemler) el
             where ss.siparis_no = p_siparis_no) x
     where s.kod = x.kod and x.mik > 0;
  elsif p_durum = 'talep' and v_eski = 'onaylandi' then
    update stok s set miktar = s.miktar + x.mik, guncelleme = now()
      from (select el->>'k' kod, coalesce((el->>'o')::numeric,(el->>'m')::numeric) mik
              from siparisler ss, jsonb_array_elements(ss.kalemler) el
             where ss.siparis_no = p_siparis_no) x
     where s.kod = x.kod and x.mik > 0;
  end if;

  update siparisler set durum = p_durum,
         onay_saati = case when p_durum='onaylandi' then now() else null end
   where siparis_no = p_siparis_no returning onay_saati into v_saat;
  return jsonb_build_object('ok', true, 'durum', p_durum,
    'saat', case when v_saat is null then null
                 else to_char(v_saat at time zone 'Europe/Istanbul','HH24:MI') end);
end $$;

create or replace function public.onay_stok_kontrol(p_sifre text, p_siparis_no text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
  if not depo_dogru(p_sifre) then raise exception 'Sifre hatali'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('kod', s.kod, 'ad', s.ad, 'mevcut', st.miktar,
             'dusecek', s.mik, 'sonra', st.miktar - s.mik, 'min_stok', um.min_stok))
    from (select el->>'k' kod, el->>'a' ad,
                 coalesce((el->>'o')::numeric,(el->>'m')::numeric) mik
            from siparisler ss, jsonb_array_elements(ss.kalemler) el
           where ss.siparis_no = p_siparis_no) s
    join stok st on st.kod = s.kod
    join urun_min um on um.kod = s.kod
    where um.min_stok is not null and s.mik > 0 and (st.miktar - s.mik) < um.min_stok
  ), '[]'::jsonb);
end $$;

-- ================= STOK YÜKLEME KAYDI (mükerrer engel + geri alma) =================
-- Mal kabul TOPLAYARAK çalışır; aynı KUM dosyası ikinci kez yüklenirse gelen
-- miktarlar sessizce ikiye katlanıyordu (ağ koparınca "Uygula"ya tekrar basmak
-- da aynı sonucu veriyordu). Artık her yükleme, İÇERİK PARMAK İZİYLE kaydedilir:
-- imza = sha256("kod:miktar;kod:miktar;..." kod sırasında). Parmak izi SUNUCUDA
-- hesaplanır — istemciye güvenilmez, eski istemciler de otomatik korunur.
-- Aynı imza ikinci kez gelirse REDDEDİLİR; bilerek geçmek için p_zorla => true.
--
-- Her kayıt uygulanan miktarları VE yükleme öncesi stok değerlerini tutar:
--   kalemler = [{k: kod, a: ad, b: birim, m: uygulanan, e: önceki stok (null = ürün yoktu)}]
-- Böylece yanlış yükleme geri alınabilir (bkz. stok_yukleme_geri_al).

create table if not exists public.stok_yukleme (
  id              uuid primary key default gen_random_uuid(),
  tarih           date not null default (now() at time zone 'Europe/Istanbul')::date,
  mod             text not null,
  imza            text not null,
  kalem_sayisi    int  not null default 0,
  toplam          numeric not null default 0,
  kalemler        jsonb not null default '[]'::jsonb,
  zorlandi        boolean not null default false,
  geri_alindi     boolean not null default false,
  geri_alma_saati timestamptz,
  olusturma       timestamptz not null default now()
);
alter table public.stok_yukleme drop constraint if exists stok_yukleme_mod_chk;
alter table public.stok_yukleme add constraint stok_yukleme_mod_chk check (mod in ('baseline','malkabul'));
create index if not exists stok_yukleme_zaman_idx on public.stok_yukleme (olusturma desc);
-- Bir imza aynı anda yalnızca bir GEÇERLİ yüklemede olabilir. Geri alınanlar ve
-- bilerek zorlananlar dışarıda kalır (yarış durumuna karşı ikinci kemer).
create unique index if not exists stok_yukleme_imza_idx
  on public.stok_yukleme (imza) where (not geri_alindi and not zorlandi);

alter table public.stok_yukleme enable row level security;
revoke all on public.stok_yukleme from anon, authenticated;


-- STOK yükleme / listeleme / temizleme
-- Eski iki parametreli sürümler kaldırılır; yeni sürümde p_zorla VARSAYILANLI,
-- yani {p_sifre, p_kalemler} ile çağıran eski istemci de çalışmaya devam eder.
drop function if exists public.stok_baseline(text, jsonb);
drop function if exists public.stok_malkabul(text, jsonb);

create or replace function public.stok_baseline(p_sifre text, p_kalemler jsonb, p_zorla boolean default false)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  v_kalemler jsonb; v_imza text; v_adet int; v_toplam numeric;
  v_eski timestamptz; v_eskimod text; v_mukerrer boolean := false;
begin
  if not depo_dogru(p_sifre) then raise exception 'Sifre hatali'; end if;
  if jsonb_typeof(p_kalemler) <> 'array' then raise exception 'Gecersiz veri'; end if;

  -- Dosyada aynı kod birden çok kez geçebilir (çok sayfalı Excel). Baseline bir
  -- ANLIK GÖRÜNTÜ olduğu için tek kayda indirilir (en büyük değer alınır).
  -- Eskiden bu, "ON CONFLICT ... cannot affect row a second time" ile patlıyordu.
  with ham as (
    select el->>'k' kod, left(el->>'a',120) ad, left(coalesce(el->>'b','ad'),20) birim,
           (el->>'m')::numeric miktar
      from jsonb_array_elements(p_kalemler) el
     where el->>'k' ~ '^[A-Z]{3}[0-9]{8}$' and (el->>'m') ~ '^-?[0-9]+(\.[0-9]+)?$'),
  veri as (select kod, max(ad) ad, max(birim) birim, max(miktar) miktar from ham group by kod)
  select coalesce(jsonb_agg(jsonb_build_object(
           'k', v.kod, 'a', v.ad, 'b', v.birim, 'm', v.miktar, 'e', s.miktar) order by v.kod), '[]'::jsonb)
    into v_kalemler
    from veri v left join stok s on s.kod = v.kod;

  v_adet := jsonb_array_length(v_kalemler);
  if v_adet = 0 then raise exception 'Uygulanabilir kalem yok'; end if;

  select encode(extensions.digest(
           string_agg((el->>'k') || ':' || (el->>'m'), ';' order by el->>'k'), 'sha256'), 'hex'),
         coalesce(sum((el->>'m')::numeric), 0)
    into v_imza, v_toplam
    from jsonb_array_elements(v_kalemler) el;

  select olusturma, mod into v_eski, v_eskimod
    from stok_yukleme where imza = v_imza and not geri_alindi
   order by olusturma desc limit 1;
  if found then
    v_mukerrer := true;
    if not coalesce(p_zorla, false) then
      raise exception 'Bu dosya zaten yuklendi: % (%). Yine de uygulamak icin "yine de uygula" isaretleyin.',
        to_char(v_eski at time zone 'Europe/Istanbul', 'DD.MM.YYYY HH24:MI'), v_eskimod;
    end if;
  end if;

  insert into stok (kod, ad, birim, miktar, guncelleme)
  select el->>'k', el->>'a', el->>'b', (el->>'m')::numeric, now()
    from jsonb_array_elements(v_kalemler) el
  on conflict (kod) do update set miktar=excluded.miktar, ad=excluded.ad,
    birim=excluded.birim, guncelleme=now();

  insert into stok_yukleme (mod, imza, kalem_sayisi, toplam, kalemler, zorlandi)
  values ('baseline', v_imza, v_adet, v_toplam, v_kalemler, v_mukerrer);

  return jsonb_build_object('ok', true, 'adet', v_adet, 'toplam', v_toplam, 'zorlandi', v_mukerrer);
end $$;

create or replace function public.stok_malkabul(p_sifre text, p_kalemler jsonb, p_zorla boolean default false)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  v_kalemler jsonb; v_imza text; v_adet int; v_toplam numeric;
  v_eski timestamptz; v_eskimod text; v_mukerrer boolean := false;
begin
  if not depo_dogru(p_sifre) then raise exception 'Sifre hatali'; end if;
  if jsonb_typeof(p_kalemler) <> 'array' then raise exception 'Gecersiz veri'; end if;

  -- Mal kabulde aynı kod birden çok satırda gelebilir → TOPLANIR (gerçekten iki
  -- kalem girişi olabilir). Tek satıra indirmek ON CONFLICT çakışmasını da önler.
  with ham as (
    select el->>'k' kod, left(el->>'a',120) ad, left(coalesce(el->>'b','ad'),20) birim,
           (el->>'m')::numeric miktar
      from jsonb_array_elements(p_kalemler) el
     where el->>'k' ~ '^[A-Z]{3}[0-9]{8}$' and (el->>'m') ~ '^[0-9]+(\.[0-9]+)?$'
       and (el->>'m')::numeric > 0),
  veri as (select kod, max(ad) ad, max(birim) birim, sum(miktar) miktar from ham group by kod)
  select coalesce(jsonb_agg(jsonb_build_object(
           'k', v.kod, 'a', v.ad, 'b', v.birim, 'm', v.miktar, 'e', s.miktar) order by v.kod), '[]'::jsonb)
    into v_kalemler
    from veri v left join stok s on s.kod = v.kod;

  v_adet := jsonb_array_length(v_kalemler);
  if v_adet = 0 then raise exception 'Uygulanabilir kalem yok (gelen miktari 0 olan dosya)'; end if;

  select encode(extensions.digest(
           string_agg((el->>'k') || ':' || (el->>'m'), ';' order by el->>'k'), 'sha256'), 'hex'),
         coalesce(sum((el->>'m')::numeric), 0)
    into v_imza, v_toplam
    from jsonb_array_elements(v_kalemler) el;

  select olusturma, mod into v_eski, v_eskimod
    from stok_yukleme where imza = v_imza and not geri_alindi
   order by olusturma desc limit 1;
  if found then
    v_mukerrer := true;
    if not coalesce(p_zorla, false) then
      raise exception 'Bu dosya zaten yuklendi: % (%). Yine de uygulamak icin "yine de uygula" isaretleyin.',
        to_char(v_eski at time zone 'Europe/Istanbul', 'DD.MM.YYYY HH24:MI'), v_eskimod;
    end if;
  end if;

  insert into stok (kod, ad, birim, miktar, guncelleme)
  select el->>'k', el->>'a', el->>'b', (el->>'m')::numeric, now()
    from jsonb_array_elements(v_kalemler) el
  on conflict (kod) do update set miktar=stok.miktar+excluded.miktar, guncelleme=now();

  insert into stok_yukleme (mod, imza, kalem_sayisi, toplam, kalemler, zorlandi)
  values ('malkabul', v_imza, v_adet, v_toplam, v_kalemler, v_mukerrer);

  return jsonb_build_object('ok', true, 'adet', v_adet, 'toplam', v_toplam, 'zorlandi', v_mukerrer);
end $$;

-- Son yüklemeler (kalemler dönmez — liste hafif kalsın)
create or replace function public.stok_yukleme_liste(p_sifre text, p_adet int default 30)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
  if not depo_dogru(p_sifre) then raise exception 'Sifre hatali'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', t.id, 'tarih', t.tarih, 'mod', t.mod, 'kalem_sayisi', t.kalem_sayisi,
             'toplam', t.toplam, 'zorlandi', t.zorlandi, 'geri_alindi', t.geri_alindi,
             'geri_alma_saati', t.geri_alma_saati, 'olusturma', t.olusturma,
             'imza', left(t.imza, 10)) order by t.olusturma desc)
      from (select * from stok_yukleme order by olusturma desc
             limit least(coalesce(p_adet, 30), 200)) t), '[]'::jsonb);
end $$;

-- Bir yüklemeyi geri al.
--  • mal kabul → eklenen miktar geri ÇIKARILIR (aradaki sipariş onayları korunur)
--  • baseline  → yükleme ÖNCESİ değerlere dönülür (o yüklemeden sonraki
--                onay düşümleri de geri gelir; bu yüzden istemci uyarı gösterir)
-- Yalnızca EN YENİ geçerli yükleme geri alınabilir: daha yeni bir yükleme
-- araya girmişse eski kaydın "önceki değer"leri artık doğru değildir.
create or replace function public.stok_yukleme_geri_al(p_sifre text, p_id uuid)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v_mod text; v_kalemler jsonb; v_zaman timestamptz; v_geri boolean; v_adet int;
begin
  if not depo_dogru(p_sifre) then raise exception 'Sifre hatali'; end if;
  select mod, kalemler, olusturma, geri_alindi
    into v_mod, v_kalemler, v_zaman, v_geri
    from stok_yukleme where id = p_id;
  if not found then raise exception 'Yukleme kaydi bulunamadi'; end if;
  if v_geri then raise exception 'Bu yukleme zaten geri alindi'; end if;
  if exists (select 1 from stok_yukleme
              where olusturma > v_zaman and not geri_alindi) then
    raise exception 'Once bundan sonraki yuklemeleri geri alin (en yeniden eskiye dogru)';
  end if;

  if v_mod = 'malkabul' then
    update stok s set miktar = s.miktar - (el->>'m')::numeric, guncelleme = now()
      from jsonb_array_elements(v_kalemler) el
     where s.kod = el->>'k';
  else
    update stok s set miktar = (el->>'e')::numeric, guncelleme = now()
      from jsonb_array_elements(v_kalemler) el
     where s.kod = el->>'k' and (el->>'e') is not null;
  end if;

  -- Bu yüklemeyle İLK KEZ oluşmuş kayıtlar tamamen silinir
  delete from stok where kod in (
    select el->>'k' from jsonb_array_elements(v_kalemler) el where (el->>'e') is null);

  update stok_yukleme set geri_alindi = true, geri_alma_saati = now() where id = p_id;
  v_adet := jsonb_array_length(v_kalemler);
  return jsonb_build_object('ok', true, 'adet', v_adet, 'mod', v_mod);
end $$;

create or replace function public.stok_liste(p_sifre text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
  if not depo_dogru(p_sifre) then raise exception 'Sifre hatali'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('kod',kod,'ad',ad,'birim',birim,
    'miktar',miktar,'guncelleme',guncelleme) order by kod) from stok), '[]'::jsonb);
end $$;

-- Katalog dışı stok temizle (yiyecek/içecek YIY/ICA/ICB KORUNUR)
create or replace function public.stok_katalog_disi_sil(p_sifre text, p_kodlar jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v_silinen int;
begin
  if not depo_dogru(p_sifre) then raise exception 'Sifre hatali'; end if;
  if jsonb_typeof(p_kodlar) <> 'array' or jsonb_array_length(p_kodlar) = 0 then
    raise exception 'Katalog listesi bos'; end if;
  with sil as (
    delete from stok where kod not in (select jsonb_array_elements_text(p_kodlar))
      and kod !~ '^(YIY|ICA|ICB)[0-9]' returning 1)
  select count(*) into v_silinen from sil;
  return jsonb_build_object('ok', true, 'silinen', v_silinen);
end $$;

create or replace function public.stok_temizle(p_sifre text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v_silinen int;
begin
  if not depo_dogru(p_sifre) then raise exception 'Sifre hatali'; end if;
  with sil as (delete from stok returning 1) select count(*) into v_silinen from sil;
  return jsonb_build_object('ok', true, 'silinen', v_silinen);
end $$;


-- ================= ADMIN (yönetici şifresi ister) =================

create or replace function public.katalog_giris(p_sifre text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
  if not admin_dogru(p_sifre) then raise exception 'Sifre hatali'; end if;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.katalog_seed(p_sifre text, p_liste text, p_kalemler jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v_adet int;
begin
  if not admin_dogru(p_sifre) then raise exception 'Sifre hatali'; end if;
  if coalesce(p_liste,'') = '' then raise exception 'Liste bos'; end if;
  if jsonb_typeof(p_kalemler) <> 'array' then raise exception 'Gecersiz veri'; end if;
  delete from katalog where liste = p_liste;
  with veri as (
    select el->>'k' kod, left(el->>'a',120) ad, left(coalesce(el->>'b','ad'),20) birim,
           left(coalesce(el->>'g',''),60) grup, coalesce((el->>'sira')::int,0) sira
      from jsonb_array_elements(p_kalemler) el
     where el->>'k' ~ '^[A-Z]{3}[0-9]{8}$' and coalesce(el->>'a','') <> ''),
  yaz as (
    insert into katalog (liste, kod, ad, birim, grup, sira)
    select p_liste, kod, ad, birim, nullif(grup,''), sira from veri
    on conflict (liste, kod) do update set ad=excluded.ad, birim=excluded.birim,
      grup=excluded.grup, sira=excluded.sira returning 1)
  select count(*) into v_adet from yaz;
  return jsonb_build_object('ok', true, 'adet', v_adet);
end $$;

create or replace function public.katalog_ekle(p_sifre text, p_liste text, p_kod text, p_ad text, p_birim text, p_grup text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v_sira int;
begin
  if not admin_dogru(p_sifre) then raise exception 'Sifre hatali'; end if;
  if coalesce(p_kod,'') !~ '^[A-Z]{3}[0-9]{8}$' then raise exception 'Gecersiz kod (ornek: ICA02000001)'; end if;
  if coalesce(p_ad,'') = '' then raise exception 'Ad bos olamaz'; end if;
  select coalesce(max(sira),0)+1 into v_sira from katalog where liste = p_liste;
  insert into katalog (liste, kod, ad, birim, grup, sira)
  values (p_liste, p_kod, left(p_ad,120), left(coalesce(p_birim,'ad'),20),
          nullif(left(coalesce(p_grup,''),60),''), v_sira)
  on conflict (liste, kod) do update set ad=excluded.ad, birim=excluded.birim, grup=excluded.grup;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.katalog_cikar(p_sifre text, p_liste text, p_kod text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
  if not admin_dogru(p_sifre) then raise exception 'Sifre hatali'; end if;
  delete from katalog where liste = p_liste and kod = p_kod;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.katalog_duzelt(p_sifre text, p_liste text, p_kod text, p_ad text, p_birim text, p_grup text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
  if not admin_dogru(p_sifre) then raise exception 'Sifre hatali'; end if;
  if coalesce(p_ad,'') = '' then raise exception 'Ad bos olamaz'; end if;
  update katalog set ad=left(p_ad,120), birim=left(coalesce(p_birim,'ad'),20),
    grup=nullif(left(coalesce(p_grup,''),60),'') where liste=p_liste and kod=p_kod;
  if not found then raise exception 'Urun bulunamadi'; end if;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.katalog_sira(p_sifre text, p_liste text, p_kodlar jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
  if not admin_dogru(p_sifre) then raise exception 'Sifre hatali'; end if;
  update katalog k set sira = x.ord
    from (select value kod, ordinality ord from jsonb_array_elements_text(p_kodlar) with ordinality) x
   where k.liste = p_liste and k.kod = x.kod;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.urun_min_ayarla(p_sifre text, p_kod text, p_min numeric)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
  if not admin_dogru(p_sifre) then raise exception 'Sifre hatali'; end if;
  if coalesce(p_kod,'') !~ '^[A-Z]{3}[0-9]{8}$' then raise exception 'Gecersiz kod'; end if;
  insert into urun_min (kod, min_miktar) values (p_kod, nullif(p_min,0))
  on conflict (kod) do update set min_miktar = nullif(p_min,0);
  delete from urun_min where kod = p_kod and min_miktar is null and min_stok is null;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.urun_minstok_ayarla(p_sifre text, p_kod text, p_minstok numeric)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
  if not admin_dogru(p_sifre) then raise exception 'Sifre hatali'; end if;
  if coalesce(p_kod,'') !~ '^[A-Z]{3}[0-9]{8}$' then raise exception 'Gecersiz kod'; end if;
  if p_minstok is not null and p_minstok < 0 then raise exception 'Negatif olamaz'; end if;
  insert into urun_min (kod, min_stok) values (p_kod, p_minstok)
  on conflict (kod) do update set min_stok = p_minstok;
  delete from urun_min where kod = p_kod and min_miktar is null and min_stok is null;
  return jsonb_build_object('ok', true);
end $$;

-- Outlet listesi + her outlet'in PIN sayısı (admin genel görünüm)
create or replace function public.outlet_liste(p_sifre text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
  if not admin_dogru(p_sifre) then raise exception 'Sifre hatali'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
    'kod', o.kod, 'ad', o.ad, 'tur', o.tur,
    'pin_sayisi', (select count(*) from outlet_pin p where p.outlet_kod = o.kod)) order by o.kod)
    from outletler o), '[]'::jsonb);
end $$;

-- Bir outlet'in PIN'leri (etiketler; hash dönmez)
create or replace function public.outlet_pin_liste(p_sifre text, p_kod text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
  if not admin_dogru(p_sifre) then raise exception 'Sifre hatali'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', id, 'etiket', etiket) order by etiket)
    from outlet_pin where outlet_kod = p_kod), '[]'::jsonb);
end $$;

-- PIN ekle (outlet başına en fazla 10; etiket = gönderen kimliği)
create or replace function public.outlet_pin_ekle(p_sifre text, p_kod text, p_etiket text, p_pin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v_adet int;
begin
  if not admin_dogru(p_sifre) then raise exception 'Sifre hatali'; end if;
  if not exists (select 1 from outletler where kod = p_kod) then raise exception 'Outlet yok'; end if;
  if coalesce(p_etiket,'') = '' then raise exception 'Etiket (gonderen) bos olamaz'; end if;
  if p_pin !~ '^[0-9]{3,12}$' then raise exception 'PIN 3-12 haneli sayi olmali'; end if;
  select count(*) into v_adet from outlet_pin where outlet_kod = p_kod;
  if v_adet >= 10 then raise exception 'Bu outlet icin en fazla 10 PIN'; end if;
  insert into outlet_pin (outlet_kod, etiket, pin)
  values (p_kod, left(p_etiket,40), extensions.crypt(p_pin, extensions.gen_salt('bf')))
  on conflict (outlet_kod, etiket) do update set pin = excluded.pin;
  return jsonb_build_object('ok', true);
end $$;

-- PIN sil (id ile)
create or replace function public.outlet_pin_sil(p_sifre text, p_id uuid)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
  if not admin_dogru(p_sifre) then raise exception 'Sifre hatali'; end if;
  delete from outlet_pin where id = p_id;
  return jsonb_build_object('ok', true);
end $$;

-- ===== KAPTAN =====
-- Giriş ekranı için aktif kaptan adları (şifresiz; PIN dönmez)
create or replace function public.kaptan_liste_ac()
returns jsonb language sql security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('kod', kod, 'ad', ad) order by ad), '[]'::jsonb)
    from kaptan where aktif;
$$;

-- Kaptan girişi: kod + PIN doğrula
create or replace function public.kaptan_giris(p_kod text, p_pin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v_ad text;
begin
  select ad into v_ad from kaptan
   where kod = p_kod and aktif and pin = extensions.crypt(coalesce(p_pin,''), pin);
  if v_ad is null then raise exception 'Kaptan kodu veya PIN hatali'; end if;
  return jsonb_build_object('ok', true, 'kod', p_kod, 'ad', v_ad);
end $$;

-- Admin: kaptan listesi (PIN yok)
create or replace function public.kaptan_liste(p_sifre text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
  if not admin_dogru(p_sifre) then raise exception 'Sifre hatali'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('kod', kod, 'ad', ad, 'aktif', aktif) order by ad)
    from kaptan), '[]'::jsonb);
end $$;

-- Admin: kaptan ekle/güncelle
create or replace function public.kaptan_ekle(p_sifre text, p_kod text, p_ad text, p_pin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
  if not admin_dogru(p_sifre) then raise exception 'Sifre hatali'; end if;
  if coalesce(p_kod,'') !~ '^[A-Za-z0-9]{1,10}$' then raise exception 'Kod 1-10 harf/rakam olmali'; end if;
  if coalesce(p_ad,'') = '' then raise exception 'Ad bos olamaz'; end if;
  if coalesce(p_pin,'') !~ '^[0-9]{3,12}$' then raise exception 'PIN 3-12 haneli sayi olmali'; end if;
  insert into kaptan (kod, ad, pin, aktif)
  values (p_kod, left(p_ad,60), extensions.crypt(p_pin, extensions.gen_salt('bf')), true)
  on conflict (kod) do update set ad = excluded.ad, pin = excluded.pin, aktif = true;
  return jsonb_build_object('ok', true);
end $$;

-- Admin: kaptan sil
create or replace function public.kaptan_sil(p_sifre text, p_kod text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
  if not admin_dogru(p_sifre) then raise exception 'Sifre hatali'; end if;
  delete from kaptan where kod = p_kod;
  return jsonb_build_object('ok', true);
end $$;


-- ================= İZİNLER (anon yalnızca fonksiyonları çağırır) =================
revoke all on all functions in schema public from public;

grant execute on function public.outlet_giris(text, text)                             to anon;
grant execute on function public.katalog_getir(text)                                  to anon;
grant execute on function public.stok_gizli_kodlar()                                  to anon;
grant execute on function public.siparis_gonder(text, text, jsonb, text, text, text, text, text) to anon;
grant execute on function public.kaptan_liste_ac()                                    to anon;
grant execute on function public.kaptan_giris(text, text)                             to anon;
grant execute on function public.kaptan_liste(text)                                   to anon;
grant execute on function public.kaptan_ekle(text, text, text, text)                  to anon;
grant execute on function public.kaptan_sil(text, text)                               to anon;
grant execute on function public.depo_liste(text, date)                               to anon;
grant execute on function public.depo_envanter(text, date, date)                      to anon;
grant execute on function public.depo_kalem_guncelle(text, text, text, int)           to anon;
grant execute on function public.depo_durum_degistir(text, text, text)                to anon;
grant execute on function public.onay_stok_kontrol(text, text)                        to anon;
grant execute on function public.stok_baseline(text, jsonb, boolean)                  to anon;
grant execute on function public.stok_malkabul(text, jsonb, boolean)                  to anon;
grant execute on function public.stok_yukleme_liste(text, int)                        to anon;
grant execute on function public.stok_yukleme_geri_al(text, uuid)                     to anon;
grant execute on function public.stok_liste(text)                                     to anon;
grant execute on function public.stok_katalog_disi_sil(text, jsonb)                   to anon;
grant execute on function public.stok_temizle(text)                                   to anon;
grant execute on function public.katalog_giris(text)                                  to anon;
grant execute on function public.katalog_seed(text, text, jsonb)                      to anon;
grant execute on function public.katalog_ekle(text, text, text, text, text, text)     to anon;
grant execute on function public.katalog_cikar(text, text, text)                      to anon;
grant execute on function public.katalog_duzelt(text, text, text, text, text, text)   to anon;
grant execute on function public.katalog_sira(text, text, jsonb)                      to anon;
grant execute on function public.urun_min_ayarla(text, text, numeric)                 to anon;
grant execute on function public.urun_minstok_ayarla(text, text, numeric)             to anon;
grant execute on function public.outlet_liste(text)                                   to anon;
grant execute on function public.outlet_pin_liste(text, text)                         to anon;
grant execute on function public.outlet_pin_ekle(text, text, text, text)              to anon;
grant execute on function public.outlet_pin_sil(text, uuid)                           to anon;
