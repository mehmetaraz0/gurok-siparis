-- ============================================================
--  GUROK SİPARİŞ — Güncelleme 11
--  Taban stok artık UYARI değil, KESİN ENGEL: depo bir siparişi onaylayınca
--  stok min_stok altına inecekse onay REDDEDİLİR (sunucuda zorlanır).
--
--  Supabase panelinde:  SQL Editor → New query → yapıştır → Run
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
  v_engel text;
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

  -- talep -> onaylandi : ÖNCE taban stok engeli, sonra düş
  if p_durum = 'onaylandi' and v_eski = 'talep' then

    -- Stoğu taban altına inecek kalem varsa onay REDDEDİLİR.
    select string_agg(s.ad || ' (' || st.miktar || '->' || (st.miktar - s.mik)
                      || ', min ' || um.min_stok || ')', ', ')
      into v_engel
      from (
        select el->>'k' as kod, el->>'a' as ad,
               coalesce((el->>'o')::numeric, (el->>'m')::numeric) as mik
          from siparisler ss, jsonb_array_elements(ss.kalemler) el
         where ss.siparis_no = p_siparis_no
      ) s
      join stok st     on st.kod = s.kod
      join urun_min um on um.kod = s.kod
     where um.min_stok is not null and s.mik > 0
       and (st.miktar - s.mik) < um.min_stok;

    if v_engel is not null then
      raise exception 'Taban stok engeli: %', v_engel;
    end if;

    -- Engel yoksa stoktan düş
    update stok s set miktar = s.miktar - x.mik, guncelleme = now()
      from (
        select el->>'k' as kod, coalesce((el->>'o')::numeric, (el->>'m')::numeric) as mik
          from siparisler ss, jsonb_array_elements(ss.kalemler) el
         where ss.siparis_no = p_siparis_no
      ) x
     where s.kod = x.kod and x.mik > 0;

  -- onaylandi -> talep : geri ekle (kilit açma)
  elsif p_durum = 'talep' and v_eski = 'onaylandi' then
    update stok s set miktar = s.miktar + x.mik, guncelleme = now()
      from (
        select el->>'k' as kod, coalesce((el->>'o')::numeric, (el->>'m')::numeric) as mik
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
