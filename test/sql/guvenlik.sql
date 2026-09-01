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

/* Bir depo oturumunun HANGI izinlere sahip oldugunu tek satirda dondurur.
   Her prob SALT OKUNUR ya da etkisiz secilmistir:
     stok_sil probu gen_random_uuid() ile cagrilir -- yetki gecerse "bulunamadi"
     hatasi alir, yetki gecmezse "yetkiniz yok". Ikisini mesajdan ayiriyoruz.  */
create or replace function pg_temp.izinler(p_token text) returns text
language plpgsql as $$
declare r text := '';
begin
  begin perform depo_liste(p_token, current_date);                   r := r || 'talep ';
  exception when others then null; end;

  begin perform stok_liste(p_token);                                 r := r || 'stok_gor ';
  exception when others then null; end;

  begin perform depo_envanter(p_token, current_date, current_date);  r := r || 'envanter ';
  exception when others then null; end;

  begin perform stok_yukleme_liste(p_token, 5);                      r := r || 'stok_yukle ';
  exception when others then null; end;

  begin
    perform stok_yukleme_geri_al(p_token, gen_random_uuid());
    r := r || 'stok_sil ';
  exception when others then
    if sqlerrm not like '%yetkiniz yok%' and sqlerrm not like '%Oturum gecersiz%'
      then r := r || 'stok_sil ';
    end if;
  end;
  return trim(r);
end $$;

do $t$
declare
  v_admin_token text;
  v_token       text;
  v_token2      text;
  r     jsonb;
  n     int;
  v_red boolean;
  v_izin text;
  v_hata text;
begin

raise notice '=== 0. HAZIRLIK: yonetici girisi ve kullanicilar ===';
  delete from kaptan_deneme;
  r := admin_giris('TestAdminSifre2026!');
  perform pg_temp.bekle('ortak yonetici sifresi ile giris', (r->>'ok')::boolean);
  v_admin_token := r->>'token';

  perform kaptan_ekle(v_admin_token, 'maraz',    'Bar Kaptani',     '123456', 'bar',    'kaptan');
  perform kaptan_ekle(v_admin_token, 'mutfakci', 'Mutfak Kaptani',  '123456', 'mutfak', 'kaptan');
  perform kaptan_ekle(v_admin_token, 'dp',       'Depo Personeli',  '111111', 'hepsi',  'depo_personel');
  perform kaptan_ekle(v_admin_token, 'da',       'Depo Asistani',   '222222', 'hepsi',  'depo_asistan');
  perform kaptan_ekle(v_admin_token, 'dy',       'Depo Yoneticisi', '333333', 'hepsi',  'depo_yonetici');
  perform kaptan_ekle(v_admin_token, 'dymut',    'Mutfak Sefi',     '444444', 'mutfak', 'departman_yonetici');
  perform kaptan_ekle(v_admin_token, 'dybar',    'Bar Muduru',      '555555', 'bar',    'departman_yonetici');
  perform kaptan_ekle(v_admin_token, 'yon1',     'Yonetici Bir',    'UzunParola2026!',  'hepsi', 'admin');
  perform kaptan_ekle(v_admin_token, 'yon2',     'Yonetici Iki',    'BaskaParola2026!', 'hepsi', 'admin');
  perform pg_temp.bekle('9 kullanici olusturuldu', (select count(*) from kaptan) = 9);

raise notice '=== 1. Token uretimi ve saklanmasi ===';
  r := kaptan_giris('DY', '333333');                  -- buyuk harf de olmali
  perform pg_temp.bekle('buyuk/kucuk harf farketmiyor', (r->>'ok')::boolean);
  perform pg_temp.bekle('token 64 hane', length(coalesce(r->>'token','')) = 64);
  v_token := r->>'token';
  perform pg_temp.bekle('token DB-de ACIK METIN olarak DURMUYOR',
    not exists (select 1 from oturum where token_hash = v_token));
  perform pg_temp.bekle('token DB-de sha256 hash olarak duruyor',
    exists (select 1 from oturum
             where token_hash = encode(extensions.digest(v_token,'sha256'),'hex')));
  perform pg_temp.bekle('oturum KIMIN oldugunu biliyor',
    (select lower(ref) from oturum
      where token_hash = encode(extensions.digest(v_token,'sha256'),'hex')) = 'dy');

raise notice '=== 2. Sahte / bos / suresi dolmus token ===';
  v_red := false;
  begin perform stok_liste('sahtetoken0123456789');
  exception when others then v_red := true; end;
  perform pg_temp.bekle('sahte token reddedildi', v_red);

  v_red := false;
  begin perform stok_liste(null);
  exception when others then v_red := true; end;
  perform pg_temp.bekle('bos token reddedildi', v_red);

  update oturum set son_kullanma = now() - interval '1 minute'
   where token_hash = encode(extensions.digest(v_token,'sha256'),'hex');
  v_red := false;
  begin perform stok_liste(v_token);
  exception when others then v_red := true; end;
  perform pg_temp.bekle('suresi dolmus token reddedildi', v_red);
  -- DIKKAT: bu silme YONETICI oturumunu da goturuyor; hemen tazele, yoksa
  -- sonraki admin cagrilari 'Oturum gecersiz' verir ve testler yanlis
  -- sebeple yesil yanar.
  delete from oturum;
  v_admin_token := admin_giris('TestAdminSifre2026!')->>'token';

raise notice '=== 3. ORTAK SIFRE: sayac ve kilit (canlida denenemez) ===';
  delete from kaptan_deneme;
  r := depo_giris('yanlisSifre');
  perform pg_temp.bekle('yanlis sifre reddedildi', (r->>'ok')::boolean is false);
  select count(*) into n from kaptan_deneme where kod = '#depo';
  -- H-2: giris fonksiyonlari RAISE etseydi transaction geri alinir, sayac artmazdi.
  perform pg_temp.bekle('deneme KAYDEDILDI (raise etseydi geri alinirdi)', n = 1);

  delete from kaptan_deneme;
  for n in 1..4 loop
    r := depo_giris('yanlis' || n);
    perform pg_temp.bekle('deneme ' || n || ' reddedildi, kilit YOK',
      (r->>'hata') = 'Sifre hatali');
  end loop;
  r := depo_giris('yanlis5');
  perform pg_temp.bekle('5. deneme de reddedildi', (r->>'ok')::boolean is false);
  r := depo_giris('yanlis6');
  perform pg_temp.bekle('6. denemede KILIT devrede', (r->>'hata') like 'Cok fazla%');
  r := depo_giris('TestDepoSifre2026!');
  perform pg_temp.bekle('kilitliyken DOGRU sifre de reddediliyor', (r->>'ok')::boolean is false);
  delete from kaptan_deneme;
  r := depo_giris('TestDepoSifre2026!');
  perform pg_temp.bekle('kilit dusunce dogru sifre yine calisiyor', (r->>'ok')::boolean);

  delete from kaptan_deneme;
  perform depo_giris('yanlis'); perform depo_giris('yanlis');
  select count(*) into n from kaptan_deneme where kod = '#depo';
  perform pg_temp.bekle('2 basarisiz deneme kayitli', n = 2);
  perform depo_giris('TestDepoSifre2026!');
  select count(*) into n from kaptan_deneme where kod = '#depo';
  perform pg_temp.bekle('basarili girisle sayac sifirlandi', n = 0);

  -- ORTAK SIFRE OTURUMU ARTIK HICBIR SEY YAPAMAZ: depo_izin kaptan tablosuna
  -- join ediyor, ortak sifre oturumunda ref NULL. Kapali fail -- dogru davranis.
  r := depo_giris('TestDepoSifre2026!');
  perform pg_temp.bekle('ortak sifre oturumu SIFIR yetkili',
    pg_temp.izinler(r->>'token') = '');
  delete from oturum; delete from kaptan_deneme;
  v_admin_token := admin_giris('TestAdminSifre2026!')->>'token';

raise notice '=== 4. DEPO KADEMELERI: izin matrisi ===';
  r := kaptan_giris('dp', '111111');
  v_izin := pg_temp.izinler(r->>'token');
  perform pg_temp.bekle('PERSONEL: talep + stok_gor  [' || v_izin || ']',
    v_izin = 'talep stok_gor');

  r := kaptan_giris('da', '222222');
  v_izin := pg_temp.izinler(r->>'token');
  perform pg_temp.bekle('ASISTAN: + envanter + stok_yukle  [' || v_izin || ']',
    v_izin = 'talep stok_gor envanter stok_yukle');

  r := kaptan_giris('dy', '333333');
  v_izin := pg_temp.izinler(r->>'token');
  perform pg_temp.bekle('YONETICI: hepsi  [' || v_izin || ']',
    v_izin = 'talep stok_gor envanter stok_yukle stok_sil');

  r := kaptan_giris('dymut', '444444');
  v_izin := pg_temp.izinler(r->>'token');
  -- Departman yoneticisi SALT OKUNUR: talep yok, yukleme yok, silme yok.
  perform pg_temp.bekle('DEPARTMAN YON.: salt okunur  [' || v_izin || ']',
    v_izin = 'stok_gor envanter');
  delete from kaptan_deneme;

raise notice '=== 5. DEPARTMAN KAPSAMI: kendi birimleri ===';
  delete from siparisler;
  insert into siparisler (siparis_no, outlet_kod, outlet_ad, gonderen, kalemler, tarih, durum)
  values ('T-BAR', 'CSM201', 'ALIBEY RESTAURANT', 'test',
          '[{"k":"ICA02000001","a":"KOLA","b":"kol","m":1}]'::jsonb, current_date, 'talep'),
         ('T-MUT', 'CMM201', 'ANAMUTFAK', 'test',
          '[{"k":"YIY01000001","a":"UN","b":"kg","m":1}]'::jsonb, current_date, 'talep');

  r := kaptan_giris('dymut', '444444');
  r := depo_envanter(r->>'token', current_date, current_date);
  perform pg_temp.bekle('mutfak sefi YALNIZ mutfak siparisini goruyor',
    jsonb_array_length(r) = 1 and r->0->>'outlet_kod' = 'CMM201');

  r := kaptan_giris('dybar', '555555');
  r := depo_envanter(r->>'token', current_date, current_date);
  perform pg_temp.bekle('bar muduru YALNIZ bar siparisini goruyor',
    jsonb_array_length(r) = 1 and r->0->>'outlet_kod' = 'CSM201');

  r := kaptan_giris('dy', '333333');
  r := depo_envanter(r->>'token', current_date, current_date);
  perform pg_temp.bekle('depo yoneticisi IKISINI DE goruyor', jsonb_array_length(r) = 2);
  delete from siparisler; delete from kaptan_deneme;

raise notice '=== 6. ROLLER birbirine gecmiyor ===';
  r := kaptan_giris('dy', '333333');
  v_token := r->>'token';
  perform pg_temp.bekle('depo oturumu tip=depo',
    exists (select 1 from oturum
             where token_hash = encode(extensions.digest(v_token,'sha256'),'hex')
               and tip = 'depo'));
  v_red := false;
  begin
    r := katalog_getir('CSM201', v_token);
    v_red := (jsonb_typeof(r) = 'object' and (r->>'ok') = 'false');
  exception when others then v_red := true; end;
  perform pg_temp.bekle('depo kullanicisi SIPARIS ekranina giremiyor', v_red);
  v_red := false;
  begin perform kaptan_liste(v_token);
  exception when others then v_red := true; end;
  perform pg_temp.bekle('depo kullanicisi YONETIM ekranina giremiyor', v_red);

  r := kaptan_giris('maraz', '123456');
  v_token := r->>'token';
  perform pg_temp.bekle('kaptan rolu dondu', r->>'rol' = 'kaptan');
  v_red := false;
  begin perform stok_liste(v_token);
  exception when others then v_red := true; end;
  perform pg_temp.bekle('kaptan DEPO ekranina giremiyor', v_red);

  r := kaptan_giris('yon1', 'UzunParola2026!');
  v_token := r->>'token';
  perform pg_temp.bekle('yonetici rolu dondu', r->>'rol' = 'admin');
  perform pg_temp.bekle('yonetici oturumu tip=admin',
    exists (select 1 from oturum
             where token_hash = encode(extensions.digest(v_token,'sha256'),'hex')
               and tip = 'admin'));
  perform pg_temp.bekle('yonetici YONETIM RPC-lerini kullanabiliyor',
    kaptan_liste(v_token) is not null);
  -- katalog_getir admin token-ini BILEREK kabul eder (panel listeleri duzenliyor).
  perform pg_temp.bekle('yonetici katalogu gorebiliyor (panel icin gerekli)',
    jsonb_typeof(katalog_getir('CSM201', v_token)) = 'array');
  v_red := false;
  begin perform stok_liste(v_token);
  exception when others then v_red := true; end;
  perform pg_temp.bekle('yonetici DEPO ekranina giremiyor', v_red);
  v_red := false;
  begin
    r := siparis_gonder('CSM201', 'ALIBEY RESTAURANT',
                        '[{"k":"ICA02000001","a":"TEST","b":"kol","m":10}]'::jsonb,
                        null, gen_random_uuid()::text, v_token);
    v_red := (jsonb_typeof(r) = 'object' and (r->>'ok') = 'false');
  exception when others then v_red := true; end;
  perform pg_temp.bekle('yonetici SIPARIS ACAMIYOR', v_red);
  delete from kaptan_deneme;

raise notice '=== 7. YATAY YETKI (M-3) ===';
  r := kaptan_giris('maraz', '123456');
  v_token := r->>'token';
  perform pg_temp.bekle('bar kaptani BAR listesini gorebiliyor',
    jsonb_typeof(katalog_getir('CSM201', v_token)) = 'array');
  v_red := false;
  begin
    r := katalog_getir('CMM201', v_token);
    v_red := (jsonb_typeof(r) = 'object' and (r->>'ok') = 'false');
  exception when others then v_red := true; end;
  perform pg_temp.bekle('bar kaptani MUTFAK listesini GOREMIYOR', v_red);

  r := kaptan_giris('mutfakci', '123456');
  v_token2 := r->>'token';
  perform pg_temp.bekle('mutfak kaptani MUTFAK listesini gorebiliyor',
    jsonb_typeof(katalog_getir('CMM201', v_token2)) = 'array');
  v_red := false;
  begin
    r := katalog_getir('CSM201', v_token2);
    v_red := (jsonb_typeof(r) = 'object' and (r->>'ok') = 'false');
  exception when others then v_red := true; end;
  perform pg_temp.bekle('mutfak kaptani BAR listesini GOREMIYOR', v_red);

  v_red := false;
  begin
    r := siparis_gonder('CMM201', 'ANAMUTFAK',
                        '[{"k":"YIY01000001","a":"TEST","b":"ad","m":10}]'::jsonb,
                        null, gen_random_uuid()::text, v_token);
    v_red := (jsonb_typeof(r) = 'object' and (r->>'ok') = 'false');
  exception when others then v_red := true; end;
  perform pg_temp.bekle('bar kaptani mutfak adina siparis ACAMIYOR', v_red);
  delete from kaptan_deneme;

raise notice '=== 8. PAROLA KURALI role gore ===';
  -- Once yonetici oturumunun GECERLI oldugunu dogrula: asagidaki testler
  -- 'reddedildi mi' diye baktigi icin gecersiz oturum da onlari gecirirdi.
  perform pg_temp.bekle('yonetici oturumu gecerli', kaptan_liste(v_admin_token) is not null);

  v_hata := '';
  begin perform kaptan_ekle(v_admin_token, 'yeni1', 'Test', '123456', 'hepsi', 'admin');
  exception when others then v_hata := sqlerrm; end;
  perform pg_temp.bekle('yoneticiye 6 haneli PIN verilemiyor  [' || v_hata || ']',
    v_hata like '%parola%');

  v_hata := '';
  begin perform kaptan_ekle(v_admin_token, 'yeni2', 'Test', 'kisa', 'hepsi', 'admin');
  exception when others then v_hata := sqlerrm; end;
  perform pg_temp.bekle('kisa parola reddediliyor  [' || v_hata || ']',
    v_hata like '%parola%');

  v_hata := '';
  begin perform kaptan_ekle(v_admin_token, 'yeni3', 'Test', 'harfliparola', 'bar', 'kaptan');
  exception when others then v_hata := sqlerrm; end;
  perform pg_temp.bekle('kaptana harfli parola verilemiyor  [' || v_hata || ']',
    v_hata like '%PIN%');

  perform pg_temp.bekle('reddedilen kullanicilar OLUSMADI',
    (select count(*) from kaptan where kod in ('yeni1','yeni2','yeni3')) = 0);

  perform pg_temp.bekle('departman yoneticisinde departman KORUNUYOR',
    (select departman from kaptan where kod = 'dymut') = 'mutfak');
  perform pg_temp.bekle('depo kademelerinde departman hepsi',
    (select departman from kaptan where kod = 'dp') = 'hepsi');

raise notice '=== 9. Parola/PIN degisimi TUM oturumlari kapatiyor ===';
  delete from oturum;
  v_admin_token := admin_giris('TestAdminSifre2026!')->>'token';
  r := kaptan_giris('dy', '333333'); v_token  := r->>'token';
  r := kaptan_giris('dy', '333333'); v_token2 := r->>'token';   -- ayni kisi, ikinci oturum
  perform pg_temp.bekle('iki oturum acildi', v_token <> v_token2);
  r := kaptan_sifre_degistir(v_token, '333333', '999999');
  perform pg_temp.bekle('PIN degistirildi', (r->>'ok')::boolean);
  select count(*) into n from oturum where lower(ref) = 'dy';
  perform pg_temp.bekle('IKI oturum da kapandi', n = 0);
  v_red := false;
  begin perform stok_liste(v_token2);
  exception when others then v_red := true; end;
  perform pg_temp.bekle('eski token gecersiz', v_red);
  perform pg_temp.bekle('yeni PIN calisiyor', (kaptan_giris('dy','999999')->>'ok')::boolean);
  perform pg_temp.bekle('eski PIN calismiyor', (kaptan_giris('dy','333333')->>'ok')::boolean is false);
  delete from kaptan_deneme;

  r := kaptan_giris('yon1', 'UzunParola2026!'); v_token := r->>'token';
  v_red := false;
  begin
    r := kaptan_sifre_degistir(v_token, 'UzunParola2026!', '123456');
    v_red := (jsonb_typeof(r) = 'object' and (r->>'ok') = 'false');
  exception when others then v_red := true; end;
  perform pg_temp.bekle('yonetici parolasini 6 haneli PIN yapamiyor', v_red);
  r := kaptan_sifre_degistir(v_token, 'UzunParola2026!', 'YeniUzunParola2026!');
  perform pg_temp.bekle('yonetici parolasini degistirdi', (r->>'ok')::boolean);
  delete from kaptan_deneme;

  r := kaptan_giris('dy', '999999'); v_token := r->>'token';
  v_red := false;
  begin
    r := kaptan_sifre_degistir(v_token, 'yanlisEski', '888888');
    v_red := (jsonb_typeof(r) = 'object' and (r->>'ok') = 'false');
  exception when others then v_red := true; end;
  perform pg_temp.bekle('yanlis eski PIN reddedildi', v_red);
  perform pg_temp.bekle('PIN degismedi', (kaptan_giris('dy','999999')->>'ok')::boolean);
  delete from kaptan_deneme;

raise notice '=== 10. KILIT kisi basina (N-1 cozuldu) ===';
  delete from kaptan_deneme;
  for n in 1..6 loop perform kaptan_giris('dp', 'yanlis' || n); end loop;
  perform pg_temp.bekle('dp kilitlendi', (kaptan_giris('dp','111111')->>'ok')::boolean is false);
  -- ASIL MESELE: birinin kilitlenmesi digerlerini etkilememeli.
  perform pg_temp.bekle('da ETKILENMEDI',     (kaptan_giris('da','222222')->>'ok')::boolean);
  perform pg_temp.bekle('dy ETKILENMEDI',     (kaptan_giris('dy','999999')->>'ok')::boolean);
  perform pg_temp.bekle('kaptan ETKILENMEDI', (kaptan_giris('maraz','123456')->>'ok')::boolean);
  delete from kaptan_deneme;

raise notice '=== 11. Rol degisimi, silme, cikis ===';
  r := kaptan_giris('da', '222222'); v_token := r->>'token';
  perform kaptan_rol(v_admin_token, 'da', 'depo_personel');
  select count(*) into n from oturum where lower(ref) = 'da';
  perform pg_temp.bekle('rol degisince oturum kapandi', n = 0);
  r := kaptan_giris('da', '222222');
  perform pg_temp.bekle('yeni rol personel', r->>'rol' = 'depo_personel');
  perform pg_temp.bekle('yetkileri de daraldi',
    pg_temp.izinler(r->>'token') = 'talep stok_gor');

  r := kaptan_giris('dybar', '555555'); v_token := r->>'token';
  perform oturum_iptal(v_token);
  v_red := false;
  begin perform stok_liste(v_token);
  exception when others then v_red := true; end;
  perform pg_temp.bekle('cikistan sonra token gecersiz', v_red);

  r := kaptan_giris('dymut', '444444');
  select count(*) into n from oturum where lower(ref) = 'dymut';
  perform pg_temp.bekle('oturum acik', n = 1);
  perform kaptan_sil(v_admin_token, 'dymut');
  select count(*) into n from oturum where lower(ref) = 'dymut';
  perform pg_temp.bekle('kullanici silinince oturumu da silindi', n = 0);
  delete from kaptan_deneme;

raise notice '=== 12. Sifreler HASH olarak saklaniyor ===';
  perform pg_temp.bekle('depo ortak sifresi duz metin DEGIL',
    (select deger from ayarlar where anahtar='depo_sifre') <> 'TestDepoSifre2026!');
  perform pg_temp.bekle('bcrypt formatinda',
    (select deger from ayarlar where anahtar='depo_sifre') like '$2%');
  perform pg_temp.bekle('kullanici PIN-i duz metin DEGIL',
    (select pin from kaptan where kod='dp') <> '111111');
  perform pg_temp.bekle('yonetici parolasi duz metin DEGIL',
    (select pin from kaptan where kod='yon1') <> 'YeniUzunParola2026!');

raise notice '=== 13. Ortak sifreler KAPATILABILIYOR ===';
  delete from kaptan_deneme;
  perform pg_temp.bekle('depo ortak sifresi acik',
    (depo_giris('TestDepoSifre2026!')->>'ok')::boolean);
  delete from ayarlar where anahtar = 'depo_sifre';
  r := depo_giris('TestDepoSifre2026!');
  perform pg_temp.bekle('kapatildiktan sonra reddediliyor', (r->>'ok')::boolean is false);
  perform pg_temp.bekle('mesaj yonlendiriyor', r->>'hata' like '%Kullanici adi ve PIN%');
  -- Sayaca DOKUNMADAN donmeli: 6 cagri sonrasi hala kilit mesaji YOK
  for n in 1..6 loop perform depo_giris('yanlis' || n); end loop;
  perform pg_temp.bekle('kapali kapi sayaci BESLEMIYOR',
    (depo_giris('x')->>'hata') like 'Ortak depo%');

  delete from ayarlar where anahtar = 'admin_sifre';
  r := admin_giris('TestAdminSifre2026!');
  perform pg_temp.bekle('yonetici ortak sifresi de kapandi', r->>'hata' like 'Ortak yonetici%');
  for n in 1..6 loop perform admin_giris('yanlis' || n); end loop;
  perform pg_temp.bekle('kapali yonetici kapisi da sayaci BESLEMIYOR',
    (admin_giris('x')->>'hata') like 'Ortak yonetici%');

  delete from kaptan_deneme;
  perform pg_temp.bekle('depo kullanicisi ETKILENMEDI',
    (kaptan_giris('dp','111111')->>'ok')::boolean);
  perform pg_temp.bekle('yonetici ETKILENMEDI',
    (kaptan_giris('yon2','BaskaParola2026!')->>'ok')::boolean);
  delete from kaptan_deneme;

raise notice '=== 14. GUNLUK LN MUTABAKATI ===';
  delete from kaptan_deneme; delete from siparisler; delete from stok;
  delete from stok_yukleme; delete from ayarlar where anahtar = 'son_kesim';
  -- Mutabakat 'stok_yukle' izni ister: asistan yeter.
  r := kaptan_giris('dy', '999999');
  v_token := r->>'token';

  -- KULLANICININ VERDIGI ORNEK: S=100, G=30 (gun basi 130), L=150
  --   gelen = L-(S+G) = 20,  yeni stok = L-G = 120
  insert into stok (kod, ad, birim, miktar) values ('ICA02000001','KOLA','kol',100);
  insert into siparisler (siparis_no, outlet_kod, outlet_ad, gonderen, kalemler,
                          tarih, durum, onay_saati)
  values ('T-1','CSM201','ALIBEY RESTAURANT','test',
          '[{"k":"ICA02000001","a":"KOLA","b":"kol","m":30}]'::jsonb,
          -- T-1: kesimden ONCE (kesim now() anina yaziliyor)
          current_date, 'onaylandi', now() - interval '1 hour');

  r := stok_mutabakat_onizle(v_token,
        '[{"k":"ICA02000001","a":"KOLA","b":"kol","m":150}]'::jsonb, false);
  perform pg_temp.bekle('onizleme S=100', (r->'kalemler'->0->>'s')::numeric = 100);
  perform pg_temp.bekle('onizleme G=30',  (r->'kalemler'->0->>'g')::numeric = 30);
  perform pg_temp.bekle('onizleme L=150', (r->'kalemler'->0->>'l')::numeric = 150);
  perform pg_temp.bekle('YENI STOK = 120 (L-G)', (r->'kalemler'->0->>'m')::numeric = 120);
  perform pg_temp.bekle('onizleme HICBIR SEY YAZMADI',
    (select miktar from stok where kod = 'ICA02000001') = 100);

  r := stok_mutabakat(v_token,
        '[{"k":"ICA02000001","a":"KOLA","b":"kol","m":150}]'::jsonb, false);
  perform pg_temp.bekle('uygulandi', (r->>'ok')::boolean);
  perform pg_temp.bekle('stok 120 oldu',
    (select miktar from stok where kod = 'ICA02000001') = 120);

raise notice '--- kesim (cumartesi): stok dogrudan LN olur ---';
  delete from stok_yukleme;
  r := stok_mutabakat(v_token,
        '[{"k":"ICA02000001","a":"KOLA","b":"kol","m":150}]'::jsonb, true);
  perform pg_temp.bekle('kesimde stok = L = 150',
    (select miktar from stok where kod = 'ICA02000001') = 150);
  perform pg_temp.bekle('son_kesim kaydedildi',
    exists (select 1 from ayarlar where anahtar = 'son_kesim'));

raise notice '--- kesimden ONCEKI siparisler G-ye girmez ---';
  -- Yukaridaki siparis kesimden once onaylandi; artik sayilmamali.
  r := stok_mutabakat_onizle(v_token,
        '[{"k":"ICA02000001","a":"KOLA","b":"kol","m":150}]'::jsonb, false);
  perform pg_temp.bekle('G sifirlandi', (r->'kalemler'->0->>'g')::numeric = 0);
  perform pg_temp.bekle('yeni stok = L (G yok)', (r->'kalemler'->0->>'m')::numeric = 150);

  -- Kesimden SONRA yeni bir siparis onaylanirsa G ye girer.
  insert into siparisler (siparis_no, outlet_kod, outlet_ad, gonderen, kalemler,
                          tarih, durum, onay_saati)
  values ('T-2','CSM201','ALIBEY RESTAURANT','test',
          '[{"k":"ICA02000001","a":"KOLA","b":"kol","m":40}]'::jsonb,
          -- T-2: kesimden SONRA (kesim now() anina yaziliyor)
          current_date, 'onaylandi', now() + interval '1 minute');
  r := stok_mutabakat_onizle(v_token,
        '[{"k":"ICA02000001","a":"KOLA","b":"kol","m":150}]'::jsonb, false);
  perform pg_temp.bekle('kesim sonrasi siparis G-ye girdi', (r->'kalemler'->0->>'g')::numeric = 40);
  perform pg_temp.bekle('yeni stok = 110', (r->'kalemler'->0->>'m')::numeric = 110);

raise notice '--- G: ONAY miktari esas, yoksa istenen ---';
  delete from siparisler;
  -- Depo 30 istenen kalemi 12 olarak onaylamis: G=12 olmali.
  insert into siparisler (siparis_no, outlet_kod, outlet_ad, gonderen, kalemler,
                          tarih, durum, onay_saati)
  values ('T-3','CSM201','ALIBEY RESTAURANT','test',
          '[{"k":"ICA02000001","a":"KOLA","b":"kol","m":30,"o":12}]'::jsonb,
          -- T-3: kesimden SONRA (kesim now() anina yaziliyor)
          current_date, 'onaylandi', now() + interval '1 minute');
  r := stok_mutabakat_onizle(v_token,
        '[{"k":"ICA02000001","a":"KOLA","b":"kol","m":150}]'::jsonb, false);
  perform pg_temp.bekle('G onay miktarini kullaniyor (12)', (r->'kalemler'->0->>'g')::numeric = 12);

raise notice '--- ONAYLANMAMIS siparis G-ye GIRMEZ ---';
  insert into siparisler (siparis_no, outlet_kod, outlet_ad, gonderen, kalemler,
                          tarih, durum)
  values ('T-4','CSM201','ALIBEY RESTAURANT','test',
          '[{"k":"ICA02000001","a":"KOLA","b":"kol","m":999}]'::jsonb,
          current_date, 'talep');
  r := stok_mutabakat_onizle(v_token,
        '[{"k":"ICA02000001","a":"KOLA","b":"kol","m":150}]'::jsonb, false);
  perform pg_temp.bekle('bekleyen talep G-ye girmedi', (r->'kalemler'->0->>'g')::numeric = 12);

raise notice '--- negatif uyarisi ---';
  delete from siparisler;
  insert into siparisler (siparis_no, outlet_kod, outlet_ad, gonderen, kalemler,
                          tarih, durum, onay_saati)
  values ('T-5','CSM201','ALIBEY RESTAURANT','test',
          '[{"k":"ICA02000001","a":"KOLA","b":"kol","m":500}]'::jsonb,
          -- T-5: kesimden SONRA (kesim now() anina yaziliyor)
          current_date, 'onaylandi', now() + interval '1 minute');
  r := stok_mutabakat_onizle(v_token,
        '[{"k":"ICA02000001","a":"KOLA","b":"kol","m":150}]'::jsonb, false);
  perform pg_temp.bekle('negatif kalem sayiliyor', (r->>'negatif')::int = 1);
  perform pg_temp.bekle('negatif deger dogru (150-500)', (r->'kalemler'->0->>'m')::numeric = -350);

raise notice '--- mukerrer dosya engelleniyor ---';
  delete from siparisler; delete from stok_yukleme;
  perform stok_mutabakat(v_token,
        '[{"k":"ICA02000001","a":"KOLA","b":"kol","m":77}]'::jsonb, false);
  v_red := false;
  begin
    perform stok_mutabakat(v_token,
        '[{"k":"ICA02000001","a":"KOLA","b":"kol","m":77}]'::jsonb, false);
  exception when others then v_red := (sqlerrm like '%zaten yuklendi%'); end;
  perform pg_temp.bekle('ayni dosya ikinci kez reddedildi', v_red);
  perform pg_temp.bekle('zorla ile gecebiliyor',
    (stok_mutabakat(v_token,
        '[{"k":"ICA02000001","a":"KOLA","b":"kol","m":77}]'::jsonb, false, true)->>'ok')::boolean);

raise notice '--- GERI ALMA: stok VE kesim geri doner ---';
  delete from stok_yukleme; delete from siparisler;
  delete from ayarlar where anahtar = 'son_kesim';
  update stok set miktar = 55 where kod = 'ICA02000001';
  perform stok_mutabakat(v_token,
        '[{"k":"ICA02000001","a":"KOLA","b":"kol","m":200}]'::jsonb, true);
  perform pg_temp.bekle('kesim uygulandi, stok 200',
    (select miktar from stok where kod = 'ICA02000001') = 200);
  perform pg_temp.bekle('son_kesim yazildi',
    exists (select 1 from ayarlar where anahtar = 'son_kesim'));
  perform stok_yukleme_geri_al(v_token,
    (select id from stok_yukleme order by olusturma desc limit 1));
  perform pg_temp.bekle('stok eski degerine dondu (55)',
    (select miktar from stok where kod = 'ICA02000001') = 55);
  -- Kesim geri alinmazsa bir sonraki mutabakat YANLIS G penceresiyle hesaplar.
  perform pg_temp.bekle('son_kesim de geri alindi',
    not exists (select 1 from ayarlar where anahtar = 'son_kesim'));

raise notice '--- yetki: personel mutabakat yapamaz ---';
  delete from kaptan_deneme;
  r := kaptan_giris('dp', '111111');
  v_red := false;
  begin
    perform stok_mutabakat_onizle(r->>'token',
        '[{"k":"ICA02000001","a":"KOLA","b":"kol","m":1}]'::jsonb, false);
  exception when others then v_red := (sqlerrm like '%yetkiniz yok%'); end;
  perform pg_temp.bekle('depo personeli mutabakat ONIZLEYEMEZ', v_red);
  v_red := false;
  begin
    perform stok_mutabakat(r->>'token',
        '[{"k":"ICA02000001","a":"KOLA","b":"kol","m":1}]'::jsonb, false);
  exception when others then v_red := (sqlerrm like '%yetkiniz yok%'); end;
  perform pg_temp.bekle('depo personeli mutabakat UYGULAYAMAZ', v_red);
  delete from kaptan_deneme; delete from siparisler; delete from stok;
  delete from stok_yukleme; delete from ayarlar where anahtar = 'son_kesim';
raise notice '=== 15. DEPO TALEBI (ortak kayit) ===';
  delete from kaptan_deneme; delete from depo_talep;
  -- 11. testte 'da' personele dusurulmustu; burada asistan olmasi gerekiyor
  -- (senaryo: YONETICI yazar, ASISTAN LN'e aktarir).
  -- 13. test ortak yonetici sifresini kapatti; KISISEL hesapla giriliyor.
  r := kaptan_giris('yon2', 'BaskaParola2026!');
  perform kaptan_rol(r->>'token', 'da', 'depo_asistan');
  delete from kaptan_deneme;
  r := kaptan_giris('dy', '999999');   -- depo yoneticisi yazar
  v_token := r->>'token';

  r := depo_talep_ekle(v_token,
    '[{"k":"ICA02000001","a":"KOLA","b":"kol","m":10},
      {"k":"ICB01000005","a":"BIRA FICI","b":"fic","m":4}]'::jsonb,
    'ICECEK', current_date, current_date);
  perform pg_temp.bekle('talep kaydedildi', (r->>'ok')::boolean);
  perform pg_temp.bekle('2 kalem', (r->>'adet')::int = 2);
  perform pg_temp.bekle('YAZAN adiyla kaydedildi',
    (select olusturan from depo_talep limit 1) = 'Depo Yoneticisi');

raise notice '--- ASIL MESELE: baskasi da goruyor ---';
  delete from kaptan_deneme;
  r := kaptan_giris('da', '222222');   -- asistan LN-e aktaracak
  v_token2 := r->>'token';
  r := depo_talep_liste(v_token2, 30);
  perform pg_temp.bekle('asistan talebi GORUYOR', jsonb_array_length(r) = 1);
  perform pg_temp.bekle('kalemler de geliyor (dosya yeniden uretilebilsin)',
    jsonb_array_length(r->0->'kalemler') = 2);
  perform pg_temp.bekle('bekliyor durumunda', (r->0->>'aktarildi')::boolean is false);

raise notice '--- aktarildi isareti KIMIN yaptigini tutuyor ---';
  perform depo_talep_aktarildi(v_token2, (r->0->>'id')::uuid, true);
  r := depo_talep_liste(v_token2, 30);
  perform pg_temp.bekle('aktarildi', (r->0->>'aktarildi')::boolean);
  perform pg_temp.bekle('aktaran ASISTAN', r->0->>'aktaran' = 'Depo Asistani');
  perform pg_temp.bekle('yazan hala YONETICI', r->0->>'olusturan' = 'Depo Yoneticisi');

  -- Yanlislikla isaretlendiyse geri alinabilmeli.
  perform depo_talep_aktarildi(v_token2, (r->0->>'id')::uuid, false);
  r := depo_talep_liste(v_token2, 30);
  perform pg_temp.bekle('geri alinabiliyor', (r->0->>'aktarildi')::boolean is false);
  perform pg_temp.bekle('aktaran temizlendi', r->0->>'aktaran' is null);

raise notice '--- gecersiz kalemler eleniyor ---';
  -- Onceki kaydi temizle: ayni transactionda olusturma damgalari esit
  -- oldugu icin "en yeni" belirsizlesir (uretimde ayri transactionlar).
  delete from depo_talep;
  r := depo_talep_ekle(v_token,
    '[{"k":"ICA02000001","a":"KOLA","b":"kol","m":5},
      {"k":"BOZUKKOD","a":"X","b":"ad","m":9},
      {"k":"ICA02000002","a":"Y","b":"ad","m":0},
      {"k":"ICA02000001","a":"KOLA","b":"kol","m":3}]'::jsonb, 'TEST');
  perform pg_temp.bekle('bozuk kod ve sifir miktar elendi', (r->>'adet')::int = 1);
  r := depo_talep_liste(v_token, 1);
  perform pg_temp.bekle('ayni kod TOPLANDI (5+3=8)',
    (r->0->'kalemler'->0->>'m')::numeric = 8);

  v_red := false;
  begin perform depo_talep_ekle(v_token, '[]'::jsonb, 'BOS');
  exception when others then v_red := true; end;
  perform pg_temp.bekle('bos talep reddedildi', v_red);

raise notice '--- yetki: personel ve departman yoneticisi ---';
  delete from kaptan_deneme;
  r := kaptan_giris('dp', '111111');
  v_red := false;
  begin perform depo_talep_liste(r->>'token', 30);
  exception when others then v_red := (sqlerrm like '%yetkiniz yok%'); end;
  perform pg_temp.bekle('depo personeli talepleri GOREMIYOR', v_red);
  v_red := false;
  begin perform depo_talep_ekle(r->>'token',
    '[{"k":"ICA02000001","a":"K","b":"kol","m":1}]'::jsonb, 'X');
  exception when others then v_red := (sqlerrm like '%yetkiniz yok%'); end;
  perform pg_temp.bekle('depo personeli talep YAZAMIYOR', v_red);

  delete from kaptan_deneme;
  r := kaptan_giris('dybar', '555555');   -- departman yoneticisi: SALT OKUNUR
  v_red := false;
  begin perform depo_talep_ekle(r->>'token',
    '[{"k":"ICA02000001","a":"K","b":"kol","m":1}]'::jsonb, 'X');
  exception when others then v_red := (sqlerrm like '%yetkiniz yok%'); end;
  perform pg_temp.bekle('departman yoneticisi talep YAZAMIYOR', v_red);

raise notice '--- silme ---';
  delete from kaptan_deneme;
  r := kaptan_giris('dy', '999999');
  v_token := r->>'token';
  r := depo_talep_liste(v_token, 30);
  n := jsonb_array_length(r);
  perform depo_talep_sil(v_token, (r->0->>'id')::uuid);
  perform pg_temp.bekle('talep silindi',
    jsonb_array_length(depo_talep_liste(v_token, 30)) = n - 1);
  delete from depo_talep; delete from kaptan_deneme;
  raise notice '';
  raise notice 'TUM SUNUCU TESTLERI GECTI';
end $t$;
