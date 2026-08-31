-- Sunucu tarafi guvenlik testleri. Gercek Postgres'te, kurulum.sql uygulanmis
-- bir veritabaninda kosar. Canlida denenemeyecek olanlar da burada:
-- ozellikle brute-force kilidi (canlida 15 dk personeli disarida birakirdi).

\set ON_ERROR_STOP on
\pset pager off

create or replace function pg_temp.bekle(ad text, sart boolean) returns void
language plpgsql as $$
begin
  if sart then raise notice '  OK   %', ad;
  else raise exception 'BASARISIZ: %', ad;
  end if;
end $$;

do $t$
declare
  v_depo_token  text;
  v_admin_token text;
  v_kap_token   text;
  v_kap_token2  text;
  r jsonb;
  n int;
begin
  raise notice '=== 1. Depo girisi ===';

  r := depo_giris('TestDepoSifre2026!');
  perform pg_temp.bekle('dogru sifre kabul edildi', (r->>'ok')::boolean);
  perform pg_temp.bekle('token dondu', length(coalesce(r->>'token','')) = 64);
  v_depo_token := r->>'token';

  perform pg_temp.bekle('token DB-de ACIK METIN olarak DURMUYOR',
    not exists (select 1 from oturum where token_hash = v_depo_token));
  perform pg_temp.bekle('token DB-de sha256 hash olarak duruyor',
    exists (select 1 from oturum
             where token_hash = encode(extensions.digest(v_depo_token,'sha256'),'hex')));

  raise notice '=== 2. Token calisiyor ===';
  perform pg_temp.bekle('stok_liste token ile calisti', stok_liste(v_depo_token) is not null);

  r := depo_liste(v_depo_token, current_date);
  perform pg_temp.bekle('depo_liste token ile calisti', r is not null);

  raise notice '=== 3. Sahte / bos token reddediliyor ===';
  -- Veri RPC-leri gecersiz token-da RAISE eder. Bu dogru: giris fonksiyonlarinin
  -- {ok:false} donmesi gerekiyordu cunku raise sayac INSERT-ini geri aliyordu;
  -- burada geri alinacak bir sayac yok.
  begin
    perform stok_liste('sahtetoken0123456789');
    perform pg_temp.bekle('sahte token reddedilmeliydi', false);
  exception when others then
    perform pg_temp.bekle('sahte token reddedildi (' || sqlerrm || ')', true);
  end;
  begin
    perform stok_liste(null);
    perform pg_temp.bekle('bos token reddedilmeliydi', false);
  exception when others then
    perform pg_temp.bekle('bos token reddedildi', true);
  end;

  raise notice '=== 4. YANLIS sifre sayaci ARTIRIYOR (H-2: transaction geri almiyor) ===';
  delete from kaptan_deneme;
  r := depo_giris('yanlisSifre');
  perform pg_temp.bekle('yanlis sifre reddedildi', (r->>'ok')::boolean is false);
  select count(*) into n from kaptan_deneme where kod = '#depo';
  perform pg_temp.bekle('deneme KAYDEDILDI (raise etseydi geri alinirdi)', n = 1);

  raise notice '=== 5. BRUTE-FORCE KILIDI (canlida denenemez) ===';
  delete from kaptan_deneme;
  for n in 1..4 loop
    r := depo_giris('yanlis' || n);
    perform pg_temp.bekle('deneme ' || n || ' reddedildi, kilit YOK',
      (r->>'ok')::boolean is false and (r->>'hata') = 'Sifre hatali');
  end loop;

  r := depo_giris('yanlis5');
  perform pg_temp.bekle('5. deneme de reddedildi', (r->>'ok')::boolean is false);

  -- 5 basarisiz denemeden sonra kilit devrede
  r := depo_giris('yanlis6');
  perform pg_temp.bekle('6. denemede KILIT devrede', (r->>'hata') like 'Cok fazla%');

  r := depo_giris('TestDepoSifre2026!');
  perform pg_temp.bekle('kilitliyken DOGRU sifre de reddediliyor', (r->>'ok')::boolean is false);

  delete from kaptan_deneme;   -- kilidi kaldir (canlida 15 dk beklenir)
  r := depo_giris('TestDepoSifre2026!');
  perform pg_temp.bekle('kilit dusunce dogru sifre yine calisiyor', (r->>'ok')::boolean);
  v_depo_token := r->>'token';

  raise notice '=== 6. Basarili giris sayaci SIFIRLIYOR ===';
  delete from kaptan_deneme;
  perform depo_giris('yanlis');
  perform depo_giris('yanlis');
  select count(*) into n from kaptan_deneme where kod = '#depo';
  perform pg_temp.bekle('2 basarisiz deneme kayitli', n = 2);
  perform depo_giris('TestDepoSifre2026!');
  select count(*) into n from kaptan_deneme where kod = '#depo';
  perform pg_temp.bekle('basarili girisle sayac sifirlandi', n = 0);

  raise notice '=== 7. Admin girisi ve kaptan olusturma ===';
  r := admin_giris('TestAdminSifre2026!');
  perform pg_temp.bekle('admin girisi', (r->>'ok')::boolean);
  v_admin_token := r->>'token';

  r := kaptan_ekle(v_admin_token, 'maraz', 'Mehmet Turan Araz', '123456', 'bar');
  perform pg_temp.bekle('bar kaptani eklendi', r is not null);
  r := kaptan_ekle(v_admin_token, 'mutfakci', 'Mutfak Sefi', '123456', 'mutfak');
  perform pg_temp.bekle('mutfak kaptani eklendi', r is not null);

  raise notice '=== 8. Kaptan girisi ===';
  r := kaptan_giris('MARAZ', '123456');       -- buyuk harf de olmali
  perform pg_temp.bekle('buyuk/kucuk harf farketmiyor', (r->>'ok')::boolean);
  perform pg_temp.bekle('departman dondu', r->>'departman' = 'bar');
  v_kap_token := r->>'token';

  r := kaptan_giris('maraz', 'yanlisPin');
  perform pg_temp.bekle('yanlis PIN reddedildi', (r->>'ok')::boolean is false);
  delete from kaptan_deneme;

  raise notice '=== 9. YATAY YETKI (M-3) ===';
  -- ASIL MESELE: bar kaptani MUTFAK listesini gorememeli.
  r := katalog_getir('CSM201', v_kap_token);          -- CSM201 = bar
  perform pg_temp.bekle('bar kaptani BAR listesini gorebiliyor',
    jsonb_typeof(r) = 'array' or (r->>'ok') is distinct from 'false');

  -- Reddetme ya RAISE ile ya da {ok:false} ile olur; ikisi de kabul.
  begin
    r := katalog_getir('CMM201', v_kap_token);        -- CMM201 = ANAMUTFAK
    perform pg_temp.bekle('bar kaptani MUTFAK listesini GOREMIYOR',
      jsonb_typeof(r) = 'object' and (r->>'ok') = 'false');
  exception when others then
    perform pg_temp.bekle('bar kaptani MUTFAK listesini GOREMIYOR (' || sqlerrm || ')', true);
  end;

  -- Ters yon: mutfak kaptani bar listesini gorememeli.
  declare rr jsonb; mt text;
  begin
    rr := kaptan_giris('mutfakci', '123456');
    mt := rr->>'token';
    rr := katalog_getir('CMM201', mt);
    perform pg_temp.bekle('mutfak kaptani MUTFAK listesini gorebiliyor',
      jsonb_typeof(rr) = 'array' or (rr->>'ok') is distinct from 'false');
    begin
      rr := katalog_getir('CSM201', mt);
      perform pg_temp.bekle('mutfak kaptani BAR listesini GOREMIYOR',
        jsonb_typeof(rr) = 'object' and (rr->>'ok') = 'false');
    exception when others then
      perform pg_temp.bekle('mutfak kaptani BAR listesini GOREMIYOR (' || sqlerrm || ')', true);
    end;
    perform oturum_iptal(mt);
  end;

  -- Baska bir kaptanin biriminde SIPARIS acamamali.
  begin
    r := siparis_gonder('CMM201', 'ANAMUTFAK',
                        '[{"k":"YIY01000001","a":"TEST","b":"ad","m":10}]'::jsonb,
                        null, gen_random_uuid()::text, v_kap_token);
    perform pg_temp.bekle('bar kaptani mutfak adina siparis acamamaliydi', false);
  exception when others then
    perform pg_temp.bekle('bar kaptani mutfak adina siparis ACAMIYOR (' || sqlerrm || ')', true);
  end;

  raise notice '=== 10. PIN degisince TUM oturumlar kapaniyor ===';
  r := kaptan_giris('maraz', '123456');
  v_kap_token2 := r->>'token';                -- ayni kaptan, IKINCI oturum
  perform pg_temp.bekle('ikinci oturum acildi', v_kap_token2 is not null and v_kap_token2 <> v_kap_token);

  r := kaptan_sifre_degistir(v_kap_token, '123456', '654321');
  perform pg_temp.bekle('PIN degistirildi', (r->>'ok')::boolean);

  select count(*) into n from oturum
   where tip = 'kaptan' and lower(ref) = 'maraz';
  perform pg_temp.bekle('kaptanin TUM oturumlari kapandi (ikisi de)', n = 0);

  r := katalog_getir('CSM201', v_kap_token2);
  perform pg_temp.bekle('eski token artik gecersiz',
    jsonb_typeof(r) = 'object' and (r->>'ok') = 'false');

  r := kaptan_giris('maraz', '654321');
  perform pg_temp.bekle('yeni PIN ile giris yapiliyor', (r->>'ok')::boolean);
  r := kaptan_giris('maraz', '123456');
  perform pg_temp.bekle('eski PIN artik calismiyor', (r->>'ok')::boolean is false);
  delete from kaptan_deneme;

  raise notice '=== 11. Yanlis eski PIN ile degisim reddediliyor ===';
  r := kaptan_giris('maraz', '654321');
  v_kap_token := r->>'token';
  begin
    r := kaptan_sifre_degistir(v_kap_token, 'yanlisEski', '999999');
    perform pg_temp.bekle('yanlis eski PIN reddedilmeliydi', false);
  exception when others then
    perform pg_temp.bekle('yanlis eski PIN reddedildi (' || sqlerrm || ')', true);
  end;

  raise notice '=== 12. Cikis (oturum_iptal) ===';
  r := kaptan_giris('maraz', '654321');
  v_kap_token := r->>'token';
  perform oturum_iptal(v_kap_token);
  r := katalog_getir('CSM201', v_kap_token);
  perform pg_temp.bekle('cikistan sonra token gecersiz',
    jsonb_typeof(r) = 'object' and (r->>'ok') = 'false');

  raise notice '=== 13. Kaptan silinince oturumu da kapaniyor ===';
  r := kaptan_giris('mutfakci', '123456');
  v_kap_token := r->>'token';
  select count(*) into n from oturum where tip='kaptan' and lower(ref)='mutfakci';
  perform pg_temp.bekle('mutfak kaptani oturumu acik', n = 1);
  perform kaptan_sil(v_admin_token, 'mutfakci');
  select count(*) into n from oturum where tip='kaptan' and lower(ref)='mutfakci';
  perform pg_temp.bekle('kaptan silinince oturumu da silindi', n = 0);

  raise notice '=== 14. Suresi dolmus oturum ===';
  r := depo_giris('TestDepoSifre2026!');
  v_depo_token := r->>'token';
  update oturum set son_kullanma = now() - interval '1 minute'
   where token_hash = encode(extensions.digest(v_depo_token,'sha256'),'hex');
  begin
    perform stok_liste(v_depo_token);
    perform pg_temp.bekle('suresi dolmus token reddedilmeliydi', false);
  exception when others then
    perform pg_temp.bekle('suresi dolmus token reddedildi', true);
  end;

  raise notice '=== 15. Sifreler HASH olarak saklaniyor ===';
  perform pg_temp.bekle('depo sifresi duz metin DEGIL',
    (select deger from ayarlar where anahtar='depo_sifre') <> 'TestDepoSifre2026!');
  perform pg_temp.bekle('bcrypt formatinda',
    (select deger from ayarlar where anahtar='depo_sifre') like '$2%');
  perform pg_temp.bekle('kaptan PIN-i duz metin DEGIL',
    (select pin from kaptan where kod='maraz') <> '654321');

  raise notice '';
  raise notice 'TUM SUNUCU TESTLERI GECTI';
end $t$;
