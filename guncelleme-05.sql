-- ============================================================
--  GUROK SİPARİŞ — Güncelleme 05  (kod incelemesi düzeltmeleri)
--
--  Üç düzeltme:
--   C1 (kaynak savunması) — kalem kodu artık katalog desenine zorlanır
--                           (^[A-Z]{3}[0-9]{8}$). Tarayıcı tarafındaki XSS
--                           deliğinin kaynağı böylece de kapanır.
--   I2 (mükerrer sipariş)  — istemci kimliğiyle idempotent gönderim. Ağ
--                           koptuğunda tekrar gönderim ikinci sipariş üretmez.
--   M1 (numara boşluğu)    — sıra numarası count(*)+1 yerine max+1; silme
--                           sonrası çakışıp kilitlenmez.
--
--  Supabase panelinde:  SQL Editor → New query → yapıştır → Run
--  Şifren ve gerçek veriler korunur.
-- ============================================================

-- İdempotency için istemci kimliği. Boş (null) olabilir; dolu olanlar tekil.
alter table public.siparisler add column if not exists istemci_id text;
create unique index if not exists siparisler_istemci_idx
  on public.siparisler (istemci_id) where istemci_id is not null;


drop function if exists public.siparis_gonder(text, text, jsonb);
drop function if exists public.siparis_gonder(text, text, jsonb, text);
drop function if exists public.siparis_gonder(text, text, jsonb, text, text);

create or replace function public.siparis_gonder(
  p_outlet_kod  text,
  p_outlet_ad   text,
  p_kalemler    jsonb,
  p_bolum       text default null,
  p_istemci_id  text default null
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
  v_kalem int;
  v_sira  int;
  v_deneme int := 0;
  v_el    jsonb;
  v_m     numeric;
  v_iid   text := nullif(left(coalesce(p_istemci_id, ''), 64), '');
  rec     record;
begin
  if p_outlet_kod is null or p_outlet_kod !~ '^C[SM]M[0-9]{3}$' then
    raise exception 'Gecersiz outlet kodu';
  end if;

  if jsonb_typeof(p_kalemler) <> 'array' or jsonb_array_length(p_kalemler) = 0 then
    raise exception 'Kalem listesi bos';
  end if;

  if jsonb_array_length(p_kalemler) > 5000 then
    raise exception 'Kalem listesi cok buyuk';
  end if;

  -- Her kalem denetlenir. Kod artık katalog desenine zorlanır: bu hem veri
  -- bütünlüğü, hem de kodun ekranda tehlikeli bir yere sızmasına karşı savunma.
  for v_el in select * from jsonb_array_elements(p_kalemler)
  loop
    if jsonb_typeof(v_el) <> 'object' then
      raise exception 'Gecersiz kalem bicimi';
    end if;

    if coalesce(v_el->>'k','') !~ '^[A-Z]{3}[0-9]{8}$' then
      raise exception 'Gecersiz kalem kodu';
    end if;

    if coalesce(v_el->>'a','') = '' or length(v_el->>'a') > 120
       or coalesce(v_el->>'b','') = '' or length(v_el->>'b') > 20 then
      raise exception 'Gecersiz kalem alani';
    end if;

    if (v_el->>'m') is null or (v_el->>'m') !~ '^\d+$' then
      raise exception 'Gecersiz miktar';
    end if;
    v_m := (v_el->>'m')::numeric;
    if v_m <= 0 or v_m > 100000 then
      raise exception 'Miktar araligi disinda';
    end if;
  end loop;

  -- İdempotency: aynı istemci kimliği daha önce yazdıysa yeni sipariş açma,
  -- var olanı döndür. (Ağ koptu, cevap kayboldu, kullanıcı tekrar bastı.)
  if v_iid is not null then
    select siparis_no, gonderilme_saati, jsonb_array_length(kalemler)
      into rec
      from siparisler where istemci_id = v_iid;
    if found then
      return jsonb_build_object('ok', true, 'tekrar', true,
        'siparis_no', rec.siparis_no,
        'saat', to_char(rec.gonderilme_saati at time zone 'Europe/Istanbul', 'HH24:MI'),
        'kalem', rec.jsonb_array_length);
    end if;
  end if;

  loop
    v_deneme := v_deneme + 1;

    -- max+1: silme boşluklarında bile kullanılmamış numara üretir.
    select coalesce(max(split_part(siparis_no, '-', 3)::int), 0) + 1
      into v_sira
      from siparisler
     where tarih = v_tarih;

    v_no := 'SIP-' || to_char(v_tarih, 'YYYYMMDD') || '-' || lpad(v_sira::text, 3, '0');

    begin
      insert into siparisler (tarih, outlet_kod, outlet_ad, kalemler, siparis_no, durum, bolum, istemci_id)
      values (v_tarih, p_outlet_kod, left(p_outlet_ad, 120), p_kalemler, v_no, 'talep',
              nullif(left(coalesce(p_bolum, ''), 40), ''), v_iid)
      returning gonderilme_saati into v_saat;
      exit;
    exception when unique_violation then
      -- İstemci kimliği çakıştıysa: eşzamanlı ikinci istek yazmış, onu döndür.
      if v_iid is not null then
        select siparis_no, gonderilme_saati, jsonb_array_length(kalemler)
          into rec from siparisler where istemci_id = v_iid;
        if found then
          return jsonb_build_object('ok', true, 'tekrar', true,
            'siparis_no', rec.siparis_no,
            'saat', to_char(rec.gonderilme_saati at time zone 'Europe/Istanbul', 'HH24:MI'),
            'kalem', rec.jsonb_array_length);
        end if;
      end if;
      -- Değilse: numara çakışması, yeniden dene.
      if v_deneme >= 15 then
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

revoke all on function public.siparis_gonder(text, text, jsonb, text, text) from public;
grant execute on function public.siparis_gonder(text, text, jsonb, text, text) to anon;
