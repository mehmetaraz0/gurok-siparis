-- ============================================================
--  GUROK SİPARİŞ — Güncelleme 07
--  Stok yalnızca sipariş katalogundaki ürünler için tutulsun.
--  Bu fonksiyon, katalog DIŞI stok kayıtlarını (GNL01 aktivite,
--  GNL05 çevre vb.) siler. Katalog listesi istemciden gelir.
--
--  Supabase panelinde:  SQL Editor → New query → yapıştır → Run
-- ============================================================

create or replace function public.stok_katalog_disi_sil(p_sifre text, p_kodlar jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare v_silinen int;
begin
  if not exists (select 1 from ayarlar where anahtar='depo_sifre'
                 and deger = extensions.crypt(coalesce(p_sifre,''), deger)) then
    raise exception 'Sifre hatali';
  end if;

  if jsonb_typeof(p_kodlar) <> 'array' or jsonb_array_length(p_kodlar) = 0 then
    raise exception 'Katalog listesi bos';
  end if;

  with sil as (
    delete from stok
     where kod not in (select jsonb_array_elements_text(p_kodlar))
    returning 1
  )
  select count(*) into v_silinen from sil;

  return jsonb_build_object('ok', true, 'silinen', v_silinen);
end $$;

revoke all on function public.stok_katalog_disi_sil(text, jsonb) from public;
grant execute on function public.stok_katalog_disi_sil(text, jsonb) to anon;
