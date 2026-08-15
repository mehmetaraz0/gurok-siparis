-- ============================================================
--  GUROK SİPARİŞ — Güncelleme 09
--  Ürün başına MİNİMUM sipariş miktarı (koda göre, TÜM listelerde geçerli).
--  Admin belirler; bar/mutfak bu miktarın altında girerse gönderemez.
--
--  Supabase panelinde:  SQL Editor → New query → yapıştır → Run
-- ============================================================

-- Minimum, ürün KODUNA bağlıdır (listeye değil) → tek yerde tutulur.
create table if not exists public.urun_min (
  kod        text primary key,
  min_miktar numeric not null check (min_miktar > 0)
);

alter table public.urun_min enable row level security;
revoke all on public.urun_min from anon, authenticated;


-- ============================================================
--  katalog_getir — her ürüne 'min' alanı eklenir (global minimum)
-- ============================================================

create or replace function public.katalog_getir(p_liste text)
returns jsonb
language sql
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(
           jsonb_build_object('k', k.kod, 'a', k.ad, 'b', k.birim,
                              'g', k.grup, 'sira', k.sira, 'min', m.min_miktar)
           order by k.sira), '[]'::jsonb)
    from katalog k
    left join urun_min m on m.kod = k.kod
   where k.liste = p_liste;
$$;


-- ============================================================
--  ADMIN → ürünün minimumunu ayarla (0/boş = minimum kaldır)
--  Koda göre yazıldığı için tüm listelerde geçerli olur.
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

  if p_min is null or p_min <= 0 then
    delete from urun_min where kod = p_kod;
  else
    insert into urun_min (kod, min_miktar) values (p_kod, p_min)
    on conflict (kod) do update set min_miktar = excluded.min_miktar;
  end if;

  return jsonb_build_object('ok', true);
end $$;


-- ---------- İzinler ----------
revoke all on function public.urun_min_ayarla(text, text, numeric) from public;
grant execute on function public.urun_min_ayarla(text, text, numeric) to anon;
-- katalog_getir izni önceki sürümde anon'a verilmişti; imza değişmedi.
