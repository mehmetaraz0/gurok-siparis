-- ============================================================
--  GUROK SİPARİŞ — Güncelleme 03
--  Mutfak siparişleri: CMM depo kodları + bölüm (kahvaltı/sıcak/soğuk/pastane)
--
--  Supabase panelinde:  SQL Editor → New query → yapıştır → Run
--  Önceki dosyaları tekrar çalıştırmana gerek yok; şifren ve veriler korunur.
-- ============================================================

-- Bir sipariş artık bir bölüme ait olabilir (ANAMUTFAK → KAHVALTI gibi).
-- Barlarda bölüm yoktur, null kalır.
alter table public.siparisler add column if not exists bolum text;


-- ============================================================
--  BAR / MUTFAK → sipariş gönderir
--
--  Değişiklik: outlet kodu artık CSM (bar) veya CMM (mutfak) olabilir,
--  ve isteğe bağlı bir bölüm bilgisi taşır.
-- ============================================================

-- Eski 3 parametreli sürüm kaldırılıyor; aksi halde iki imza yan yana kalır
-- ve PostgREST hangisini çağıracağını şaşırır.
drop function if exists public.siparis_gonder(text, text, jsonb);

create or replace function public.siparis_gonder(
  p_outlet_kod text,
  p_outlet_ad  text,
  p_kalemler   jsonb,
  p_bolum      text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_tarih date := (now() at time zone 'Europe/Istanbul')::date;
  v_no    text;
  v_saat  timestamptz;
  v_deneme int := 0;
begin
  -- CSM201 (bar) veya CMM201 (mutfak)
  if p_outlet_kod is null or p_outlet_kod !~ '^C[SM]M[0-9]{3}$' then
    raise exception 'Gecersiz outlet kodu';
  end if;

  if jsonb_typeof(p_kalemler) <> 'array' or jsonb_array_length(p_kalemler) = 0 then
    raise exception 'Kalem listesi bos';
  end if;

  if jsonb_array_length(p_kalemler) > 5000 then
    raise exception 'Kalem listesi cok buyuk';
  end if;

  loop
    v_deneme := v_deneme + 1;

    select 'SIP-' || to_char(v_tarih, 'YYYYMMDD') || '-'
           || lpad((count(*) + 1)::text, 3, '0')
      into v_no
      from siparisler
     where tarih = v_tarih;

    begin
      insert into siparisler (tarih, outlet_kod, outlet_ad, kalemler, siparis_no, durum, bolum)
      values (v_tarih, p_outlet_kod, left(p_outlet_ad, 120), p_kalemler, v_no, 'talep',
              nullif(left(coalesce(p_bolum, ''), 40), ''))
      returning gonderilme_saati into v_saat;
      exit;
    exception when unique_violation then
      if v_deneme >= 10 then
        raise exception 'Siparis numarasi uretilemedi, tekrar deneyin';
      end if;
    end;
  end loop;

  return jsonb_build_object(
    'ok',         true,
    'siparis_no', v_no,
    'saat',       to_char(v_saat at time zone 'Europe/Istanbul', 'HH24:MI'),
    'kalem',      jsonb_array_length(p_kalemler)
  );
end $$;


-- ============================================================
--  DEPO → günün siparişleri (bölüm bilgisi eklendi)
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
               'siparis_no',       siparis_no,
               'outlet_kod',       outlet_kod,
               'outlet_ad',        outlet_ad,
               'bolum',            bolum,
               'kalemler',         kalemler,
               'gonderilme_saati', gonderilme_saati,
               'durum',            durum,
               'onay_saati',       onay_saati
             ) order by gonderilme_saati desc
           )
      from siparisler
     where tarih = v_tarih
  ), '[]'::jsonb);
end $$;


-- ============================================================
--  DEPO → envanter (bölüm bilgisi eklendi)
-- ============================================================

create or replace function public.depo_envanter(
  p_sifre text,
  p_bas   date,
  p_bit   date
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_bas date := coalesce(p_bas, (now() at time zone 'Europe/Istanbul')::date);
  v_bit date := coalesce(p_bit, (now() at time zone 'Europe/Istanbul')::date);
begin
  if not exists (
    select 1 from ayarlar
     where anahtar = 'depo_sifre'
       and deger = extensions.crypt(coalesce(p_sifre, ''), deger)
  ) then
    raise exception 'Sifre hatali';
  end if;

  if v_bit < v_bas then
    raise exception 'Bitis tarihi baslangictan once olamaz';
  end if;

  if v_bit - v_bas > 92 then
    raise exception 'En fazla 92 gunluk aralik sorgulanabilir';
  end if;

  return coalesce((
    select jsonb_agg(
             jsonb_build_object(
               'siparis_no',       siparis_no,
               'tarih',            tarih,
               'outlet_kod',       outlet_kod,
               'outlet_ad',        outlet_ad,
               'bolum',            bolum,
               'kalemler',         kalemler,
               'gonderilme_saati', gonderilme_saati,
               'durum',            durum,
               'onay_saati',       onay_saati
             ) order by gonderilme_saati
           )
      from siparisler
     where tarih between v_bas and v_bit
  ), '[]'::jsonb);
end $$;


-- ---------- İzinler ----------

revoke all on function public.siparis_gonder(text, text, jsonb, text) from public;
revoke all on function public.depo_liste(text, date)                  from public;
revoke all on function public.depo_envanter(text, date, date)         from public;

grant execute on function public.siparis_gonder(text, text, jsonb, text) to anon;
grant execute on function public.depo_liste(text, date)                  to anon;
grant execute on function public.depo_envanter(text, date, date)         to anon;
