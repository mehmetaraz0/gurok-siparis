-- ============================================================
--  GUROK SİPARİŞ — Güncelleme 01
--  Sipariş numarası + günde birden çok sipariş + depo düzeltme/onay
--
--  Supabase panelinde:  SQL Editor → New query → yapıştır → Run
--  kurulum.sql'i TEKRAR ÇALIŞTIRMA — şifren bu dosyada korunuyor.
-- ============================================================

-- ---------- Tablo değişiklikleri ----------

alter table public.siparisler add column if not exists siparis_no  text;
alter table public.siparisler add column if not exists durum       text not null default 'talep';
alter table public.siparisler add column if not exists onay_saati  timestamptz;

-- Gün + outlet tekilliği kalkıyor: bir bar günde birden çok sipariş gönderebilir.
alter table public.siparisler drop constraint if exists siparisler_tarih_outlet_kod_key;

-- Eski kayıtlara (varsa) numara üret.
-- row_number() doğrudan UPDATE ... SET içinde kullanılamaz (42P20),
-- bu yüzden numaralar önce alt sorguda üretilip id üzerinden eşleştiriliyor.
update public.siparisler s
   set siparis_no = n.yeni_no
  from (
    select id,
           'SIP-' || to_char(tarih, 'YYYYMMDD') || '-'
        || lpad(row_number() over (partition by tarih order by gonderilme_saati)::text, 3, '0')
             as yeni_no
      from public.siparisler
     where siparis_no is null
  ) n
 where s.id = n.id;

create unique index if not exists siparisler_no_idx on public.siparisler (siparis_no);

alter table public.siparisler
  drop constraint if exists siparisler_durum_chk,
  add  constraint siparisler_durum_chk check (durum in ('talep', 'onaylandi'));


-- ============================================================
--  1) BAR → sipariş gönderir (her gönderim YENİ bir sipariş)
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
  v_no    text;
  v_saat  timestamptz;
  v_deneme int := 0;
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

  -- Numara: SIP-YYYYMMDD-NNN, gün içinde sıralı.
  -- İki bar aynı anda gönderirse tekil index çakışır; birkaç kez yeniden dener.
  loop
    v_deneme := v_deneme + 1;

    select 'SIP-' || to_char(v_tarih, 'YYYYMMDD') || '-'
           || lpad((count(*) + 1)::text, 3, '0')
      into v_no
      from siparisler
     where tarih = v_tarih;

    begin
      insert into siparisler (tarih, outlet_kod, outlet_ad, kalemler, siparis_no, durum)
      values (v_tarih, p_outlet_kod, left(p_outlet_ad, 120), p_kalemler, v_no, 'talep')
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
--  2) DEPO → günün tüm siparişlerini döner
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
--  3) DEPO → bir kalemin onaylanan miktarını düzeltir
--     p_onay = 0  →  o ürün verilmedi, Excel'e girmez
-- ============================================================

create or replace function public.depo_kalem_guncelle(
  p_sifre      text,
  p_siparis_no text,
  p_kalem_kod  text,
  p_onay       int
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare v_durum text;
begin
  if not exists (
    select 1 from ayarlar
     where anahtar = 'depo_sifre'
       and deger = extensions.crypt(coalesce(p_sifre, ''), deger)
  ) then
    raise exception 'Sifre hatali';
  end if;

  if p_onay is null or p_onay < 0 then
    raise exception 'Miktar negatif olamaz';
  end if;

  select durum into v_durum from siparisler where siparis_no = p_siparis_no;
  if not found then raise exception 'Siparis bulunamadi'; end if;
  if v_durum = 'onaylandi' then raise exception 'Siparis kilitli, once kilidi acin'; end if;

  -- with ordinality + order by: kalem sırası korunur.
  -- Sıra önemli, çünkü Excel satırları bu sırayla yazılıyor.
  update siparisler
     set kalemler = (
           select jsonb_agg(
                    case when el->>'k' = p_kalem_kod
                         then el || jsonb_build_object('o', p_onay)
                         else el end
                    order by ord
                  )
             from jsonb_array_elements(kalemler) with ordinality as t(el, ord)
         )
   where siparis_no = p_siparis_no;

  return jsonb_build_object('ok', true);
end $$;


-- ============================================================
--  4) DEPO → siparişi onaylar / kilidi açar
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
declare v_saat timestamptz;
begin
  if not exists (
    select 1 from ayarlar
     where anahtar = 'depo_sifre'
       and deger = extensions.crypt(coalesce(p_sifre, ''), deger)
  ) then
    raise exception 'Sifre hatali';
  end if;

  if p_durum not in ('talep', 'onaylandi') then
    raise exception 'Gecersiz durum';
  end if;

  update siparisler
     set durum      = p_durum,
         onay_saati = case when p_durum = 'onaylandi' then now() else null end
   where siparis_no = p_siparis_no
  returning onay_saati into v_saat;

  if not found then raise exception 'Siparis bulunamadi'; end if;

  return jsonb_build_object(
    'ok',    true,
    'durum', p_durum,
    'saat',  case when v_saat is null then null
                  else to_char(v_saat at time zone 'Europe/Istanbul', 'HH24:MI') end
  );
end $$;


-- ---------- İzinler ----------

revoke all on function public.siparis_gonder(text, text, jsonb)              from public;
revoke all on function public.depo_liste(text, date)                         from public;
revoke all on function public.depo_kalem_guncelle(text, text, text, int)     from public;
revoke all on function public.depo_durum_degistir(text, text, text)          from public;

grant execute on function public.siparis_gonder(text, text, jsonb)           to anon;
grant execute on function public.depo_liste(text, date)                      to anon;
grant execute on function public.depo_kalem_guncelle(text, text, text, int)  to anon;
grant execute on function public.depo_durum_degistir(text, text, text)       to anon;

-- Bar artık gönderdikten sonra ekranını sıfırlıyor; bu fonksiyona gerek kalmadı.
drop function if exists public.siparis_getir(text);
