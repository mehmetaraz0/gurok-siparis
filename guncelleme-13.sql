-- ============================================================
--  GUROK SİPARİŞ — Güncelleme 13
--  Stok, sipariş katalogundan geniştir: yiyecek/içecek (YIY/ICA/ICB)
--  kalemleri, sipariş edilmese bile stokta İZLENİR ve depo STOK ekranında
--  görünür. "Katalog dışını temizle" artık bunları SİLMEZ — sadece gıda
--  dışı (GNL aktivite vb.) katalog dışı kayıtları siler.
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

  -- Katalogda OLMAYAN ve yiyecek/içecek de OLMAYAN (GNL aktivite vb.) kayıtları sil.
  with sil as (
    delete from stok
     where kod not in (select jsonb_array_elements_text(p_kodlar))
       and kod !~ '^(YIY|ICA|ICB)[0-9]'
    returning 1
  )
  select count(*) into v_silinen from sil;

  return jsonb_build_object('ok', true, 'silinen', v_silinen);
end $$;

revoke all on function public.stok_katalog_disi_sil(text, jsonb) from public;
grant execute on function public.stok_katalog_disi_sil(text, jsonb) to anon;
