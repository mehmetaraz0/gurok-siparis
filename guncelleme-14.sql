-- ============================================================
--  GUROK SİPARİŞ — Güncelleme 14
--  Depo STOK ekranına "Tüm stoğu temizle" — stok tablosunu tamamen boşaltır
--  (yeniden baseline yüklemeden önce temiz sayfa için). Depo şifresi ister.
--
--  Supabase panelinde:  SQL Editor → New query → yapıştır → Run
-- ============================================================

create or replace function public.stok_temizle(p_sifre text)
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

  with sil as (delete from stok returning 1)
  select count(*) into v_silinen from sil;

  return jsonb_build_object('ok', true, 'silinen', v_silinen);
end $$;

revoke all on function public.stok_temizle(text) from public;
grant execute on function public.stok_temizle(text) to anon;
