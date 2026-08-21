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
  -- 1) Outlet gerçek mi + kimlik. TÜM birimler (bar + mutfak) kişi bazlı giriş ister.
  --    ad'ı ve gonderen'i SUNUCU belirler.
  select ad into v_ad from outletler where kod = p_outlet_kod;
  if v_ad is null then raise exception 'Gecersiz outlet'; end if;

  -- Kişi (kaptan/personel) kimliği: geçerli + aktif kaptan PIN'i şart (kasa farketmez).
  select ad into v_gonderen from kaptan
   where lower(kod) = lower(coalesce(p_kaptan_kod,'')) and aktif
     and pin = extensions.crypt(coalesce(p_kaptan_pin,''), pin);
  if v_gonderen is null then raise exception 'Kullanici girisi gerekli'; end if;

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
