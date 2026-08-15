-- ============================================================
--  GUROK SİPARİŞ — Güncelleme 12
--  katalog_getir'in KESİN sürümü: hem 'min' (sipariş) hem 'minstok'
--  (taban stok) alanlarını döndürür. Önceki dosyalar farklı sırayla
--  çalıştırıldığında minstok alanı kaybolabiliyordu; bu dosya en yüksek
--  numaralı olduğu için en son çalıştırılınca doğru sürümü sabitler.
--
--  Supabase panelinde:  SQL Editor → New query → yapıştır → Run
-- ============================================================

create or replace function public.katalog_getir(p_liste text)
returns jsonb
language sql
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(
           jsonb_build_object('k', k.kod, 'a', k.ad, 'b', k.birim, 'g', k.grup,
                              'sira', k.sira, 'min', m.min_miktar, 'minstok', m.min_stok)
           order by k.sira), '[]'::jsonb)
    from katalog k
    left join urun_min m on m.kod = k.kod
   where k.liste = p_liste;
$$;
