-- ============================================================
--  GUROK SİPARİŞ — Güncelleme 10
--  Ürün başına MİNİMUM STOK (taban stok). Depo bir siparişi onaylayınca
--  stok bu tabanın altına inecekse UYARIR (ama isterse onaylayabilir).
--  Min stok, sipariş miktarı alt sınırından (MİN) ayrı bir değerdir.
--
--  Supabase panelinde:  SQL Editor → New query → yapıştır → Run
-- ============================================================

-- urun_min tablosuna min_stok eklenir; artık min_miktar da opsiyonel.
alter table public.urun_min alter column min_miktar drop not null;
alter table public.urun_min drop constraint if exists urun_min_min_miktar_check;
alter table public.urun_min add constraint urun_min_min_miktar_chk
  check (min_miktar is null or min_miktar > 0);
alter table public.urun_min add column if not exists min_stok numeric;
alter table public.urun_min add constraint urun_min_min_stok_chk
  check (min_stok is null or min_stok >= 0);


-- ============================================================
--  katalog_getir — 'min' (sipariş) ve 'minstok' (taban stok)
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


-- ============================================================
--  ADMIN → min sipariş / min stok ayarla
--  (satır her ikisi de boşalınca silinir)
-- ============================================================

create or replace function public.urun_min_ayarla(p_sifre text, p_kod text, p_min numeric)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not admin_dogru(p_sifre) then raise exception 'Sifre hatali'; end if;
  if coalesce(p_kod,'') !~ '^[A-Z]{3}[0-9]{8}$' then raise exception 'Gecersiz kod'; end if;

  insert into urun_min (kod, min_miktar) values (p_kod, nullif(p_min,0))
  on conflict (kod) do update set min_miktar = nullif(p_min,0);
  delete from urun_min where kod = p_kod and min_miktar is null and min_stok is null;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.urun_minstok_ayarla(p_sifre text, p_kod text, p_minstok numeric)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not admin_dogru(p_sifre) then raise exception 'Sifre hatali'; end if;
  if coalesce(p_kod,'') !~ '^[A-Z]{3}[0-9]{8}$' then raise exception 'Gecersiz kod'; end if;
  if p_minstok is not null and p_minstok < 0 then raise exception 'Negatif olamaz'; end if;

  insert into urun_min (kod, min_stok) values (p_kod, p_minstok)
  on conflict (kod) do update set min_stok = p_minstok;
  delete from urun_min where kod = p_kod and min_miktar is null and min_stok is null;
  return jsonb_build_object('ok', true);
end $$;


-- ============================================================
--  DEPO → onay öncesi taban stok kontrolü
--  Onaylanınca stoğu min_stok altına inecek kalemleri döner.
-- ============================================================

create or replace function public.onay_stok_kontrol(p_sifre text, p_siparis_no text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not exists (select 1 from ayarlar where anahtar='depo_sifre'
                 and deger = extensions.crypt(coalesce(p_sifre,''), deger)) then
    raise exception 'Sifre hatali';
  end if;

  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'kod', s.kod, 'ad', s.ad,
             'mevcut', st.miktar, 'dusecek', s.mik,
             'sonra', st.miktar - s.mik, 'min_stok', um.min_stok))
    from (
      select el->>'k' as kod, el->>'a' as ad,
             coalesce((el->>'o')::numeric, (el->>'m')::numeric) as mik
        from siparisler ss, jsonb_array_elements(ss.kalemler) el
       where ss.siparis_no = p_siparis_no
    ) s
    join stok st     on st.kod = s.kod
    join urun_min um on um.kod = s.kod
    where um.min_stok is not null and s.mik > 0
      and (st.miktar - s.mik) < um.min_stok
  ), '[]'::jsonb);
end $$;


-- ---------- İzinler ----------
revoke all on function public.urun_minstok_ayarla(text, text, numeric) from public;
revoke all on function public.onay_stok_kontrol(text, text)            from public;
grant execute on function public.urun_minstok_ayarla(text, text, numeric) to anon;
grant execute on function public.onay_stok_kontrol(text, text)            to anon;
