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
  v_red boolean;   -- reddedildi mi (raise VEYA {ok:false})
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
  v_red := false;
  begin perform stok_liste('sahtetoken0123456789');
  exception when others then v_red := true; end;
  perform pg_temp.bekle('sahte token reddedildi', v_red);
  v_red := false;
  begin perform stok_liste(null);
  exception when others then v_red := true; end;
  perform pg_temp.bekle('bos token reddedildi', v_red);

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
  v_red := false;
  begin
    r := katalog_getir('CMM201', v_kap_token);        -- CMM201 = ANAMUTFAK
    v_red := (jsonb_typeof(r) = 'object' and (r->>'ok') = 'false');
  exception when others then v_red := true; end;
  perform pg_temp.bekle('bar kaptani MUTFAK listesini GOREMIYOR', v_red);

  -- Ters yon: mutfak kaptani bar listesini gorememeli.
  declare rr jsonb; mt text; v_red2 boolean;
  begin
    rr := kaptan_giris('mutfakci', '123456');
    mt := rr->>'token';
    rr := katalog_getir('CMM201', mt);
    perform pg_temp.bekle('mutfak kaptani MUTFAK listesini gorebiliyor',
      jsonb_typeof(rr) = 'array' or (rr->>'ok') is distinct from 'false');
    v_red2 := false;
    begin
      rr := katalog_getir('CSM201', mt);
      v_red2 := (jsonb_typeof(rr) = 'object' and (rr->>'ok') = 'false');
    exception when others then v_red2 := true; end;
    perform pg_temp.bekle('mutfak kaptani BAR listesini GOREMIYOR', v_red2);
    perform oturum_iptal(mt);
  end;

  -- Baska bir kaptanin biriminde SIPARIS acamamali.
  v_red := false;
  begin
    r := siparis_gonder('CMM201', 'ANAMUTFAK',
                        '[{"k":"YIY01000001","a":"TEST","b":"ad","m":10}]'::jsonb,
                        null, gen_random_uuid()::text, v_kap_token);
    v_red := (jsonb_typeof(r) = 'object' and (r->>'ok') = 'false');
  exception when others then v_red := true; end;
  perform pg_temp.bekle('bar kaptani mutfak adina siparis ACAMIYOR', v_red);

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
  v_red := false;
  begin
    r := kaptan_sifre_degistir(v_kap_token, 'yanlisEski', '999999');
    v_red := (jsonb_typeof(r) = 'object' and (r->>'ok') = 'false');
  exception when others then v_red := true; end;
  perform pg_temp.bekle('yanlis eski PIN reddedildi', v_red);
  -- ve PIN GERCEKTEN degismemis olmali
  perform pg_temp.bekle('PIN degismedi', (kaptan_giris('maraz','654321')->>'ok')::boolean);
  delete from kaptan_deneme;

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
  v_red := false;
  begin perform stok_liste(v_depo_token);
  exception when others then v_red := true; end;
  perform pg_temp.bekle('suresi dolmus token reddedildi', v_red);

  raise notice '=== 15. Sifreler HASH olarak saklaniyor ===';
  perform pg_temp.bekle('depo sifresi duz metin DEGIL',
    (select deger from ayarlar where anahtar='depo_sifre') <> 'TestDepoSifre2026!');
  perform pg_temp.bekle('bcrypt formatinda',
    (select deger from ayarlar where anahtar='depo_sifre') like '$2%');
  perform pg_temp.bekle('kaptan PIN-i duz metin DEGIL',
    (select pin from kaptan where kod='maraz') <> '654321');

  raise notice '=== 16. DEPO KULLANICISI (kullanici adi + PIN) ===';
  delete from kaptan_deneme;
  r := admin_giris('TestAdminSifre2026!');
  v_admin_token := r->>'token';

  perform kaptan_ekle(v_admin_token, 'depocu1', 'Depo Personeli 1', '111111', 'hepsi', 'depo');
  perform kaptan_ekle(v_admin_token, 'depocu2', 'Depo Personeli 2', '222222', 'hepsi', 'depo');
  perform pg_temp.bekle('depo kullanicilari eklendi',
    (select count(*) from kaptan where rol = 'depo') = 2);

  r := kaptan_giris('DEPOCU1', '111111');
  perform pg_temp.bekle('depo kullanicisi giris yapabiliyor', (r->>'ok')::boolean);
  perform pg_temp.bekle('rol donuyor', r->>'rol' = 'depo');
  v_kap_token := r->>'token';

  perform pg_temp.bekle('oturum tipi DEPO acildi',
    exists (select 1 from oturum
             where token_hash = encode(extensions.digest(v_kap_token,'sha256'),'hex')
               and tip = 'depo' and lower(ref) = 'depocu1'));
  perform pg_temp.bekle('oturum KIMIN oldugunu biliyor (hesap verebilirlik)',
    (select lower(ref) from oturum
      where token_hash = encode(extensions.digest(v_kap_token,'sha256'),'hex')) = 'depocu1');

  raise notice '--- depo token-i depo RPC-lerinde calisiyor ---';
  perform pg_temp.bekle('stok_liste calisti', stok_liste(v_kap_token) is not null);
  perform pg_temp.bekle('depo_liste calisti', depo_liste(v_kap_token, current_date) is not null);

  raise notice '--- roller birbirine gecmiyor ---';
  v_red := false;
  begin
    r := katalog_getir('CSM201', v_kap_token);
    v_red := (jsonb_typeof(r) = 'object' and (r->>'ok') = 'false');
  exception when others then v_red := true; end;
  perform pg_temp.bekle('depo kullanicisi siparis ekranina GIREMIYOR', v_red);

  r := kaptan_giris('maraz', '654321');            -- kaptan rolu
  v_kap_token2 := r->>'token';
  perform pg_temp.bekle('kaptan girisinde rol kaptan', r->>'rol' = 'kaptan');
  v_red := false;
  begin perform stok_liste(v_kap_token2);
  exception when others then v_red := true; end;
  perform pg_temp.bekle('kaptan DEPO ekranina GIREMIYOR', v_red);

  raise notice '=== 17. N-1 COZULDU: kilit artik KISI basina ===';
  delete from kaptan_deneme;
  for n in 1..6 loop
    perform kaptan_giris('depocu1', 'yanlis' || n);
  end loop;
  r := kaptan_giris('depocu1', '111111');
  perform pg_temp.bekle('depocu1 kilitlendi', (r->>'ok')::boolean is false);
  -- ASIL MESELE: bir kisinin kilitlenmesi DIGERLERINI etkilememeli.
  r := kaptan_giris('depocu2', '222222');
  perform pg_temp.bekle('depocu2 ETKILENMEDI, girebiliyor', (r->>'ok')::boolean);
  r := kaptan_giris('maraz', '654321');
  perform pg_temp.bekle('kaptan da etkilenmedi', (r->>'ok')::boolean);
  delete from kaptan_deneme;

  raise notice '=== 18. Depo kullanicisi KENDI PIN-ini degistirebiliyor ===';
  r := kaptan_giris('depocu1', '111111');
  v_kap_token := r->>'token';
  r := kaptan_sifre_degistir(v_kap_token, '111111', '333333');
  perform pg_temp.bekle('PIN degistirildi', (r->>'ok')::boolean);
  select count(*) into n from oturum where lower(ref) = 'depocu1';
  perform pg_temp.bekle('depo oturumlari da kapandi', n = 0);
  r := kaptan_giris('depocu1', '333333');
  perform pg_temp.bekle('yeni PIN calisiyor', (r->>'ok')::boolean);
  delete from kaptan_deneme;

  raise notice '=== 19. Rol degisince oturum kapaniyor ===';
  delete from oturum where lower(ref) = 'depocu2';   -- onceki testlerden kalanlar
  r := kaptan_giris('depocu2', '222222');
  v_kap_token := r->>'token';
  select count(*) into n from oturum where lower(ref) = 'depocu2';
  perform pg_temp.bekle('oturum acik', n = 1);
  perform kaptan_rol(v_admin_token, 'depocu2', 'kaptan');
  select count(*) into n from oturum where lower(ref) = 'depocu2';
  perform pg_temp.bekle('rol degisince oturum kapandi', n = 0);
  r := kaptan_giris('depocu2', '222222');
  perform pg_temp.bekle('artik kaptan rolunde', r->>'rol' = 'kaptan');
  delete from kaptan_deneme;

  raise notice '=== 20. Ortak depo sifresi KAPATILABILIYOR (gecisin son adimi) ===';
  r := depo_giris('TestDepoSifre2026!');
  perform pg_temp.bekle('kapatmadan once calisiyor', (r->>'ok')::boolean);
  delete from ayarlar where anahtar = 'depo_sifre';
  r := depo_giris('TestDepoSifre2026!');
  perform pg_temp.bekle('kapatildiktan sonra reddediliyor', (r->>'ok')::boolean is false);
  perform pg_temp.bekle('mesaj kullaniciyi yonlendiriyor',
    r->>'hata' like '%Kullanici adi ve PIN%');
  -- depo kullanicisi hala girebiliyor olmali
  r := kaptan_giris('depocu1', '333333');
  perform pg_temp.bekle('depo kullanicisi ETKILENMEDI', (r->>'ok')::boolean);
  delete from kaptan_deneme;

  raise notice '';
  raise notice 'TUM SUNUCU TESTLERI GECTI';
end $t$;
