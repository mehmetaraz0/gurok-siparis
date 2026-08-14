-- ============================================================
--  GUROK SİPARİŞ — Güncelleme 02
--  Kalem envanteri: tarih aralığında ürün çıkış kaydı
--
--  Supabase panelinde:  SQL Editor → New query → yapıştır → Run
--  Önceki dosyaları tekrar çalıştırmana gerek yok; şifren korunur.
-- ============================================================

-- Tarih aralığı sorguları için indeks zaten var (siparisler_tarih_idx),
-- envanter de onu kullanır.

-- ============================================================
--  DEPO → tarih aralığındaki tüm siparişler (envanter kaynağı)
--
--  Talepler ekranı tek gün çalışmaya devam eder (depo_liste).
--  Bu fonksiyon yalnızca envanter içindir.
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

  -- Tarayıcıya aşırı veri gitmesin
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

revoke all on function public.depo_envanter(text, date, date) from public;
grant execute on function public.depo_envanter(text, date, date) to anon;
