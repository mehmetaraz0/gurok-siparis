-- ============================================================
--  GUROK SİPARİŞ — Güncelleme 04  (GÜVENLİK / GİRDİ DOĞRULAMA)
--
--  siparis_gonder gelen kalem listesini yeterince denetlemiyordu:
--  negatif miktar (m:-99), sıfır miktar ve miktarsız kalem kabul ediliyordu.
--  Bunlar envanteri ve Excel çıktısını bozar. Sıkı doğrulama eklenir.
--
--  Ayrıca test sırasında oluşmuş çöp kayıtlar temizlenir.
--
--  Supabase panelinde:  SQL Editor → New query → yapıştır → Run
--  Şifren ve gerçek veriler korunur.
-- ============================================================

-- ---------- Test/çöp kayıtları temizle ----------
-- Negatif veya geçersiz miktar içeren, ya da TEST kodlu kalemler.
delete from public.siparisler s
 where exists (
   select 1 from jsonb_array_elements(s.kalemler) el
    where (el->>'m') is null
       or (el->>'m') !~ '^-?\d+$'
       or (el->>'m')::int <= 0
       or el->>'k' = 'TEST'
 );


-- ============================================================
--  siparis_gonder — sıkı kalem doğrulaması
-- ============================================================

drop function if exists public.siparis_gonder(text, text, jsonb);
drop function if exists public.siparis_gonder(text, text, jsonb, text);

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
  v_el    jsonb;
  v_m     numeric;
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

  -- HER kalem denetlenir: nesne olmalı, k/a/b dolu, m pozitif tam sayı.
  for v_el in select * from jsonb_array_elements(p_kalemler)
  loop
    if jsonb_typeof(v_el) <> 'object' then
      raise exception 'Gecersiz kalem bicimi';
    end if;

    if coalesce(v_el->>'k','') = '' or length(v_el->>'k') > 40
       or coalesce(v_el->>'a','') = '' or length(v_el->>'a') > 120
       or coalesce(v_el->>'b','') = '' or length(v_el->>'b') > 20 then
      raise exception 'Gecersiz kalem alani';
    end if;

    -- Miktar: var olmalı, sayı olmalı, tam sayı olmalı, 0 < m <= 100000
    if (v_el->>'m') is null or (v_el->>'m') !~ '^\d+$' then
      raise exception 'Gecersiz miktar';
    end if;
    v_m := (v_el->>'m')::numeric;
    if v_m <= 0 or v_m > 100000 then
      raise exception 'Miktar araligi disinda';
    end if;
  end loop;

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

revoke all on function public.siparis_gonder(text, text, jsonb, text) from public;
grant execute on function public.siparis_gonder(text, text, jsonb, text) to anon;


-- ============================================================
--  depo_kalem_guncelle — onay miktarı için üst sınır
--  (0 = verilmedi hâlâ geçerli; negatif zaten reddediliyordu)
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

  if p_onay is null or p_onay < 0 or p_onay > 100000 then
    raise exception 'Gecersiz miktar';
  end if;

  select durum into v_durum from siparisler where siparis_no = p_siparis_no;
  if not found then raise exception 'Siparis bulunamadi'; end if;
  if v_durum = 'onaylandi' then raise exception 'Siparis kilitli, once kilidi acin'; end if;

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

revoke all on function public.depo_kalem_guncelle(text, text, text, int) from public;
grant execute on function public.depo_kalem_guncelle(text, text, text, int) to anon;
