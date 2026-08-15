-- ============================================================
--  GUROK SİPARİŞ — Güncelleme 12  (BİRLEŞİK min / taban stok / engel)
--
--  09, 10, 11 dosyaları farklı sırayla çalıştırıldığında tutarsızlık
--  oluşuyordu (min_stok sütunu / katalog_getir sürümü). Bu dosya o üç
--  katmanı TEK, İDEMPOTENT bir betikte toplar. Önceki durum ne olursa
--  olsun bir kez çalıştırınca her şey doğru olur.
--
--  Ön koşul: kurulum.sql, guncelleme-06 (stok), guncelleme-08 (katalog)
--  uygulanmış olmalı. (stok, katalog, ayarlar, admin_dogru gerekir.)
--
--  Supabase panelinde:  SQL Editor → New query → yapıştır → Run
-- ============================================================

-- ---------- urun_min tablosu (min sipariş + min stok) ----------
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
alter table public.urun_min enable row level security;
revoke all on public.urun_min from anon, authenticated;


-- ---------- katalog_getir: min + minstok ----------
create or replace function public.katalog_getir(p_liste text)
returns jsonb language sql security definer set search_path = public as $$
  select coalesce(jsonb_agg(
           jsonb_build_object('k', k.kod, 'a', k.ad, 'b', k.birim, 'g', k.grup,
                              'sira', k.sira, 'min', m.min_miktar, 'minstok', m.min_stok)
           order by k.sira), '[]'::jsonb)
    from katalog k
    left join urun_min m on m.kod = k.kod
   where k.liste = p_liste;
$$;


-- ---------- min sipariş / min stok ayarla (admin) ----------
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


-- ---------- depo: onay öncesi taban stok kontrolü (bilgi) ----------
create or replace function public.onay_stok_kontrol(p_sifre text, p_siparis_no text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
  if not exists (select 1 from ayarlar where anahtar='depo_sifre'
                 and deger = extensions.crypt(coalesce(p_sifre,''), deger)) then
    raise exception 'Sifre hatali';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'kod', s.kod, 'ad', s.ad, 'mevcut', st.miktar, 'dusecek', s.mik,
             'sonra', st.miktar - s.mik, 'min_stok', um.min_stok))
    from (
      select el->>'k' as kod, el->>'a' as ad,
             coalesce((el->>'o')::numeric, (el->>'m')::numeric) as mik
        from siparisler ss, jsonb_array_elements(ss.kalemler) el
       where ss.siparis_no = p_siparis_no
    ) s
    join stok st     on st.kod = s.kod
    join urun_min um on um.kod = s.kod
    where um.min_stok is not null and s.mik > 0 and (st.miktar - s.mik) < um.min_stok
  ), '[]'::jsonb);
end $$;


-- ---------- depo: durum değiştir — taban stok KESİN ENGEL + stok düş/geri ekle ----------
create or replace function public.depo_durum_degistir(p_sifre text, p_siparis_no text, p_durum text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v_saat timestamptz; v_eski text; v_engel text;
begin
  if not exists (select 1 from ayarlar where anahtar='depo_sifre'
                 and deger = extensions.crypt(coalesce(p_sifre,''), deger)) then
    raise exception 'Sifre hatali';
  end if;
  if p_durum not in ('talep','onaylandi') then raise exception 'Gecersiz durum'; end if;

  select durum into v_eski from siparisler where siparis_no = p_siparis_no;
  if not found then raise exception 'Siparis bulunamadi'; end if;

  if p_durum = 'onaylandi' and v_eski = 'talep' then
    -- Taban stok engeli
    select string_agg(s.ad || ' (' || st.miktar || '->' || (st.miktar - s.mik)
                      || ', min ' || um.min_stok || ')', ', ')
      into v_engel
      from (select el->>'k' as kod, el->>'a' as ad,
                   coalesce((el->>'o')::numeric,(el->>'m')::numeric) as mik
              from siparisler ss, jsonb_array_elements(ss.kalemler) el
             where ss.siparis_no = p_siparis_no) s
      join stok st on st.kod = s.kod
      join urun_min um on um.kod = s.kod
     where um.min_stok is not null and s.mik > 0 and (st.miktar - s.mik) < um.min_stok;
    if v_engel is not null then raise exception 'Taban stok engeli: %', v_engel; end if;

    update stok s set miktar = s.miktar - x.mik, guncelleme = now()
      from (select el->>'k' as kod, coalesce((el->>'o')::numeric,(el->>'m')::numeric) as mik
              from siparisler ss, jsonb_array_elements(ss.kalemler) el
             where ss.siparis_no = p_siparis_no) x
     where s.kod = x.kod and x.mik > 0;

  elsif p_durum = 'talep' and v_eski = 'onaylandi' then
    update stok s set miktar = s.miktar + x.mik, guncelleme = now()
      from (select el->>'k' as kod, coalesce((el->>'o')::numeric,(el->>'m')::numeric) as mik
              from siparisler ss, jsonb_array_elements(ss.kalemler) el
             where ss.siparis_no = p_siparis_no) x
     where s.kod = x.kod and x.mik > 0;
  end if;

  update siparisler set durum = p_durum,
         onay_saati = case when p_durum='onaylandi' then now() else null end
   where siparis_no = p_siparis_no
  returning onay_saati into v_saat;

  return jsonb_build_object('ok', true, 'durum', p_durum,
    'saat', case when v_saat is null then null
                 else to_char(v_saat at time zone 'Europe/Istanbul','HH24:MI') end);
end $$;


-- ---------- İzinler ----------
revoke all on function public.katalog_getir(text)                         from public;
revoke all on function public.urun_min_ayarla(text, text, numeric)        from public;
revoke all on function public.urun_minstok_ayarla(text, text, numeric)    from public;
revoke all on function public.onay_stok_kontrol(text, text)               from public;
revoke all on function public.depo_durum_degistir(text, text, text)       from public;

grant execute on function public.katalog_getir(text)                      to anon;
grant execute on function public.urun_min_ayarla(text, text, numeric)     to anon;
grant execute on function public.urun_minstok_ayarla(text, text, numeric) to anon;
grant execute on function public.onay_stok_kontrol(text, text)            to anon;
grant execute on function public.depo_durum_degistir(text, text, text)    to anon;
