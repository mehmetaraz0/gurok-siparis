-- ============================================================
--  GUROK SİPARİŞ — TEK KURULUM DOSYASI (birleşik + sağlamlaştırılmış)
--
--  Bu dosya, kurulum + guncelleme-01..14'ün TAMAMINI ve güvenlik
--  sertleştirmesini tek, İDEMPOTENT betikte toplar. Sıfırdan kuran biri
--  yalnızca bunu çalıştırır. MEVCUT bir veritabanında çalıştırmak da
--  güvenlidir: veriler, şifreler ve PIN'ler KORUNUR.
--
--  Supabase panelinde:  SQL Editor → New query → yapıştır → Run
--
--  SIFIRDAN KURULUMDA: aşağıdaki BURAYA_DEPO_SIFRE / BURAYA_ADMIN_SIFRE
--  yerlerini değiştir (mevcut kurulumda dokunma — eskiler korunur).
--  Değiştirmezsen betik "ŞİFRELER" bölümünde durur ve seni uyarır; bu
--  yer tutucular herkese açık repoda yazılı olduğu için kurulmalarına
--  izin verilmiyor.
-- ============================================================

create extension if not exists pgcrypto with schema extensions;

-- ================= TABLOLAR =================

create table if not exists public.siparisler (
  id                uuid primary key default gen_random_uuid(),
  tarih             date not null,
  outlet_kod        text not null,
  outlet_ad         text not null,
  kalemler          jsonb not null,
  gonderilme_saati  timestamptz not null default now(),
  siparis_no        text,
  durum             text not null default 'talep',
  onay_saati        timestamptz,
  bolum             text,
  istemci_id        text
);
-- Mevcut tabloya eksik sütunları ekle (eski kurulumdan geliyorsa)
alter table public.siparisler add column if not exists siparis_no text;
alter table public.siparisler add column if not exists durum      text not null default 'talep';
alter table public.siparisler add column if not exists onay_saati timestamptz;
alter table public.siparisler add column if not exists bolum      text;
alter table public.siparisler add column if not exists istemci_id text;
-- Eski "gün+outlet tekil" kısıtı kalktı (bir outlet günde çok sipariş verebilir)
alter table public.siparisler drop constraint if exists siparisler_tarih_outlet_kod_key;
alter table public.siparisler drop constraint if exists siparisler_durum_chk;
alter table public.siparisler add constraint siparisler_durum_chk check (durum in ('talep','onaylandi','iptal'));
-- Geri çağırma izi (kaptan iptal ettiğinde doldurulur)
alter table public.siparisler add column if not exists iptal_saati timestamptz;
alter table public.siparisler add column if not exists iptal_eden  text;
-- Teslim mutabakatı (kaptan depo onayından sonra doldurur)
alter table public.siparisler add column if not exists teslim_durum text;
alter table public.siparisler add column if not exists teslim_saati timestamptz;
alter table public.siparisler add column if not exists teslim_eden  text;
alter table public.siparisler add column if not exists teslim_not   text;
alter table public.siparisler drop constraint if exists siparisler_teslim_chk;
alter table public.siparisler add constraint siparisler_teslim_chk
  check (teslim_durum is null or teslim_durum in ('alindi','itiraz'));
create index if not exists siparisler_tarih_idx on public.siparisler (tarih);
create unique index if not exists siparisler_no_idx on public.siparisler (siparis_no);
create unique index if not exists siparisler_istemci_idx
  on public.siparisler (istemci_id) where istemci_id is not null;

create table if not exists public.ayarlar (
  anahtar text primary key,
  deger   text not null
);

-- Outlet allowlist (sahte outlet engellenir)
create table if not exists public.outletler (
  kod text primary key,
  ad  text not null,
  tur text not null default 'bar',   -- 'bar' | 'mutfak'
  pin text                            -- (eski tek-PIN sütunu; artık outlet_pin tablosu kullanılıyor)
);

-- Outlet başına 10'a kadar PIN — her biri farklı kişi/gönderen.
-- etiket = depoda görünen "gönderen" kodu (ör. kişi adı ya da 1..10).
create table if not exists public.outlet_pin (
  id         uuid primary key default gen_random_uuid(),
  outlet_kod text not null,
  etiket     text not null,
  pin        text not null,           -- bcrypt hash
  unique (outlet_kod, etiket)
);
create index if not exists outlet_pin_kod_idx on public.outlet_pin (outlet_kod);

-- Siparişe gönderen kimliği (hangi PIN/kişi) yazılır
alter table public.siparisler add column if not exists gonderen text;

-- Eski tek-PIN'leri çoklu tabloya taşı (etiket = '1')
insert into public.outlet_pin (outlet_kod, etiket, pin)
select kod, '1', pin from public.outletler where pin is not null
on conflict (outlet_kod, etiket) do nothing;

-- Kaptanlar: bara bağlı DEĞİL, kişi bazlı kimlik. Kaptan kendi PIN'iyle girer,
-- sipariş vereceği barı seçer. 'ad' depoda 'gönderen' olarak görünür.
create table if not exists public.kaptan (
  kod   text primary key,
  ad    text not null,
  pin   text not null,               -- bcrypt hash
  aktif boolean not null default true
);
-- Departman: personel yalnızca kendi departmanının birimlerini görür.
--   'bar'    -> sadece barlar, 'mutfak' -> sadece mutfaklar, 'hepsi' -> ikisi
alter table public.kaptan add column if not exists departman text not null default 'hepsi';
alter table public.kaptan drop constraint if exists kaptan_departman_chk;
alter table public.kaptan add constraint kaptan_departman_chk check (departman in ('bar','mutfak','hepsi'));
-- Rol: bu kişi nereye giriyor.
--   'kaptan'             -> bar/mutfak sipariş ekranı (bar.html)
--   'depo_personel'      -> depo: talepler + onay + stok listesi
--   'depo_asistan'       -> + kalem envanteri/tüketim + stok yükleme
--   'depo_yonetici'      -> + yükleme geri alma + stok silme
--   'departman_yonetici' -> SALT OKUNUR, kendi departmanı (FM müdürü, mutfak şefi)
--   'admin'              -> liste/kullanıcı yönetimi (admin.html)
-- Depo girişi eskiden HERKESİN kullandığı tek ortak şifreydi; sayaç kişi
-- başına tutulamadığı için kilit de kapı başınaydı ve yabancı biri 5 yanlış
-- denemeyle tüm depoyu 15 dakika dışarıda bırakabiliyordu (denetim N-1).
-- Depo personeli de kendi kullanıcı adı + PIN'i ile girince sayaç kişiye
-- bağlanıyor ve bu kapanıyor. Yan kazanç: oturum artık KİMİN olduğunu biliyor.
alter table public.kaptan add column if not exists rol text not null default 'kaptan';
alter table public.kaptan drop constraint if exists kaptan_rol_chk;
-- GEÇİŞ: tek 'depo' rolü üç kademeye ayrıldı. Mevcut depo kullanıcıları
-- YETKİ KAYBETMESİN diye en genişe taşınıyor; yönetim panelinden gerektiği
-- gibi asistan/personel'e düşürülür. (Genişten daralt, tersi değil: sessizce
--  yetki kaybı canlıda işi durdurur, fazlalık yetki durdurmaz.)
update public.kaptan set rol = 'depo_yonetici' where rol = 'depo';
alter table public.kaptan add constraint kaptan_rol_chk check (rol in
  ('kaptan','depo_personel','depo_asistan','depo_yonetici','departman_yonetici','admin'));
-- Girişte hep lower(kod) eşleştiği için kod da küçük harfe sabitlenir. Aksi halde
-- 'Maraz' + 'maraz' iki ayrı satır olur, giriş hangisine düşeceği belirsizleşir.
update public.kaptan set kod = lower(kod) where kod <> lower(kod);
create unique index if not exists kaptan_kod_lower_idx on public.kaptan (lower(kod));

-- Hatalı PIN denemeleri (brute-force engeli). YALNIZCA başarısız denemeler yazılır;
-- başarılı girişte o kullanıcının kayıtları silinir.
-- NOT: kayıt kaptan_giris içinde tutulur — hata exception ile dönseydi transaction
-- geri alınır ve sayaç hiç artmazdı. Bu yüzden kaptan_giris artık {ok:false} döner.
create table if not exists public.kaptan_deneme (
  id    bigserial primary key,
  kod   text not null,
  zaman timestamptz not null default now()
);
create index if not exists kaptan_deneme_idx on public.kaptan_deneme (kod, zaman desc);
alter table public.kaptan_deneme enable row level security;
revoke all on public.kaptan_deneme from anon, authenticated;

-- Kilitli mi? (son 15 dakikada 5+ hatalı deneme)
create or replace function public.kaptan_kilitli(p_kod text)
returns boolean language sql security definer set search_path = public as $$
  select count(*) >= 5 from kaptan_deneme
   where kod = lower(coalesce(p_kod,'')) and zaman > now() - interval '15 minutes';
$$;

-- Kaptan PIN doğrulama + BAŞARISIZ DENEME KAYDI (tek kapı).
--
-- Eskiden sayacı yalnızca kaptan_giris besliyordu; PIN doğrulayan diğer yedi
-- fonksiyon kilidi OKUYOR ama başarısız denemeyi YAZMIYORDU. Böylece
-- stok_gizli_kodlar / katalog_getir gibi bir fonksiyon üzerinden sınırsız PIN
-- denenebiliyordu: sayaç artmadığı için kilit hiç kurulmuyordu.
--
-- KRİTİK: çağıran fonksiyon KİMLİK hatasında RAISE ETMEMELİ; bu fonksiyonun
-- döndürdüğü {ok:false} nesnesini olduğu gibi döndürmeli. raise exception
-- transaction'ı geri alır ve kaptan_deneme kaydı da silinir — kaptan_giris'in
-- {ok:false} dönmesinin sebebi de budur (bkz. kaptan_deneme tablo notu).
-- YETKİ hatası (yanlış departman) için raise serbesttir; orada sayaca
-- yazılacak bir şey yoktur.
create or replace function public.kaptan_dogrula(p_kod text, p_pin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v_ad text; v_dep text; v_rol text; v_k text := lower(coalesce(p_kod,''));
begin
  -- Kod hiç verilmemiş: sayaca yazılacak bir kimlik yok, boş kod satırı üretme.
  if v_k = '' then
    return jsonb_build_object('ok', false, 'hata', 'Kullanici girisi gerekli');
  end if;

  if kaptan_kilitli(v_k) then
    return jsonb_build_object('ok', false,
      'hata', 'Cok fazla hatali deneme. 15 dakika sonra tekrar deneyin.');
  end if;

  select ad, departman, rol into v_ad, v_dep, v_rol from kaptan
   where lower(kod) = v_k and aktif
     and pin = extensions.crypt(coalesce(p_pin,''), pin);

  if v_ad is null then
    insert into kaptan_deneme (kod) values (v_k);
    return jsonb_build_object('ok', false, 'hata', 'Kullanici girisi gerekli');
  end if;

  return jsonb_build_object('ok', true, 'ad', v_ad, 'departman', coalesce(v_dep,'hepsi'),
    'rol', coalesce(v_rol,'kaptan'));
end $$;

-- Bir kaptan verilen birim türüne (bar/mutfak) yetkili mi?

-- ================= OTURUM (TOKEN) =================
-- H-1/H-2/M-1'in KÖK NEDENİ: şifre/PIN her RPC'nin parametresiydi, yani her RPC
-- bir deneme kapısıydı. kaptan_dogrula sayacı besleyerek H-2'yi kapattı; ancak
-- depo/admin şifreleri hâlâ her çağrıda dolaşıyordu (H-1) ve tarayıcıda düz
-- metin duruyordu (M-1). Çözüm kapı sayısını 1'e indirmek:
--   • şifre/PIN YALNIZCA üç giriş fonksiyonunda kabul edilir
--   • diğer tüm RPC'ler kısa ömürlü, iptal edilebilir token alır
--   • token DB'de düz tutulmaz; yalnız sha256 özeti saklanır
create table if not exists public.oturum (
  token_hash   text primary key,
  tip          text not null,              -- 'kaptan' | 'depo' | 'admin'
  ref          text,                       -- kaptan kodu (depo/admin'de null)
  olusturma    timestamptz not null default now(),
  son_kullanma timestamptz not null
);
create index if not exists oturum_sonkullanma_idx on public.oturum (son_kullanma);
alter table public.oturum enable row level security;
revoke all on public.oturum from anon, authenticated;

create or replace function public.oturum_omru(p_tip text)
returns interval language sql immutable as $$
  select case when p_tip = 'kaptan' then interval '12 hours' else interval '2 hours' end;
$$;

-- Token üret + kaydet; DÜZ token yalnız burada, bir kez döner
create or replace function public.oturum_ac(p_tip text, p_ref text)
returns text language plpgsql security definer set search_path = public, extensions as $$
declare v_token text;
begin
  delete from oturum where son_kullanma < now();          -- lazy temizlik
  v_token := encode(extensions.gen_random_bytes(32), 'hex');
  insert into oturum (token_hash, tip, ref, son_kullanma)
  values (encode(extensions.digest(v_token, 'sha256'), 'hex'), p_tip, p_ref,
          now() + oturum_omru(p_tip));
  return v_token;
end $$;

-- Kaptan oturumu → kaptan_dogrula ile AYNI jsonb sözleşmesi:
--   {ok:true, kod, ad, departman} | {ok:false, hata}
-- Böylece çağıran fonksiyonların gövdesi değişmez.
create or replace function public.oturum_kaptan(p_token text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v_kod text; v_ad text; v_dep text;
begin
  select k.kod, k.ad, k.departman into v_kod, v_ad, v_dep
    from oturum o join kaptan k on lower(k.kod) = lower(o.ref)
   where o.token_hash = encode(extensions.digest(coalesce(p_token,''), 'sha256'), 'hex')
     and o.son_kullanma > now() and o.tip = 'kaptan' and k.aktif;
  if v_ad is null then
    return jsonb_build_object('ok', false, 'hata', 'Oturum gecersiz veya suresi dolmus');
  end if;
  return jsonb_build_object('ok', true, 'kod', v_kod, 'ad', v_ad,
    'departman', coalesce(v_dep,'hepsi'));
end $$;

/* Depo tarafı izinleri.  Kademeler TEK BİR MERDİVEN DEĞİL: departman
   yöneticisi tüketimi görebilir ama sipariş onaylayamaz; personel sipariş
   onaylar ama tüketimi göremez. O yüzden seviye sayısı değil, izin listesi.

   İzinler:
     talep      : talepleri görmek, miktar girmek, onaylamak
     stok_gor   : stok listesini görüntülemek
     envanter   : kalem envanteri + tüketim (AYNI veri, aynı RPC)
     stok_yukle : baseline / mal kabul yüklemek, yükleme geçmişi
     stok_sil   : yükleme geri alma, katalog dışını temizleme, tüm stoğu silme */
create or replace function public.depo_yetki(p_rol text, p_izin text)
returns boolean language sql immutable as $$
  select case p_izin
    when 'talep'      then p_rol in ('depo_personel','depo_asistan','depo_yonetici')
    when 'stok_gor'   then p_rol in ('depo_personel','depo_asistan','depo_yonetici','departman_yonetici')
    when 'envanter'   then p_rol in ('depo_asistan','depo_yonetici','departman_yonetici')
    when 'stok_yukle' then p_rol in ('depo_asistan','depo_yonetici')
    when 'stok_sil'   then p_rol in ('depo_yonetici')
    else false
  end;
$$;

-- Oturum tipi rolden türer. Depo tarafındaki DÖRT rol de tip='depo' oturumu
-- açar; ayrım oturum tipinde değil, RPC başına izin kontrolünde yapılır.
create or replace function public.rol_oturum_tipi(p_rol text)
returns text language sql immutable as $$
  select case when p_rol = 'admin' then 'admin'
              when p_rol in ('depo_personel','depo_asistan','depo_yonetici','departman_yonetici')
                then 'depo'
              else 'kaptan' end;
$$;

-- Parola kuralı role göre değişir.
--   kaptan/depo : tablette hızlı girilsin diye 6-12 haneli sayısal PIN.
--   admin       : yönetim yetkisi taşıdığı için serbest metin, en az 10 karakter.
-- Sayısal PIN çevrimiçi kırılamaz (5 denemede kilit), ama admin hesabı daha
-- geniş yetkili; orada uzun parola isteniyor.
create or replace function public.sifre_kurali_uygun(p_rol text, p_sifre text)
returns boolean language sql immutable as $$
  select case when coalesce(p_rol,'kaptan') = 'admin'
              then length(coalesce(p_sifre,'')) >= 10
              else coalesce(p_sifre,'') ~ '^[0-9]{6,12}$'
         end;
$$;

create or replace function public.sifre_kurali_metni(p_rol text)
returns text language sql immutable as $$
  select case when coalesce(p_rol,'kaptan') = 'admin'
              then 'Yonetici parolasi en az 10 karakter olmali'
              else 'PIN en az 6 haneli sayi olmali'
         end;
$$;

-- Bir KİŞİ oturumunu (kaptan, depo ya da admin) kaptan satırına çözer.
-- oturum_kaptan yalnızca tip='kaptan' bakar; depo rolündeki kişinin oturumu
-- tip='depo' olduğu için oraya düşmez. Kendi PIN'ini değiştirme gibi
-- "kim olduğun" yeten işlemler bunu kullanır.
create or replace function public.oturum_kisi(p_token text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v_kod text; v_ad text; v_dep text; v_rol text;
begin
  select k.kod, k.ad, k.departman, k.rol into v_kod, v_ad, v_dep, v_rol
    from oturum o join kaptan k on lower(k.kod) = lower(o.ref)
   where o.token_hash = encode(extensions.digest(coalesce(p_token,''), 'sha256'), 'hex')
     and o.son_kullanma > now() and o.tip in ('kaptan','depo','admin') and k.aktif;
  if v_ad is null then
    return jsonb_build_object('ok', false, 'hata', 'Oturum gecersiz veya suresi dolmus');
  end if;
  return jsonb_build_object('ok', true, 'kod', v_kod, 'ad', v_ad,
    'departman', coalesce(v_dep,'hepsi'), 'rol', coalesce(v_rol,'kaptan'));
end $$;

-- Bir kişinin TÜM oturumlarını kapatır (kaptan ve depo oturumları birlikte).
-- PIN değişimi / silme sonrası tek tip kapatmak yetmez: kişi rol değiştirmiş
-- olabilir ve eski tipte açık oturumu kalabilir.
create or replace function public.oturum_kapat_kisi(p_kod text)
returns void language sql security definer set search_path = public as $$
  delete from oturum
   where tip in ('kaptan','depo','admin') and lower(coalesce(ref,'')) = lower(coalesce(p_kod,''));
$$;

/* Depo tarafı RPC'lerinin tek giriş kontrolü. Yetkisizse RAISE eder;
   yetkiliyse {rol, departman} döner -- departman yöneticisinin verisini
   kendi departmanına daraltmak için gerekiyor.

   Not: ortak şifreyle açılmış eski oturumlarda ref NULL'dı; join tutmadığı
   için onlar da reddedilir. Ortak şifre 1 Eyl 2026'da zaten kapatıldı. */
create or replace function public.depo_izin(p_token text, p_izin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v_rol text; v_dep text;
begin
  select k.rol, k.departman into v_rol, v_dep
    from oturum o join kaptan k on lower(k.kod) = lower(o.ref)
   where o.token_hash = encode(extensions.digest(coalesce(p_token,''),'sha256'),'hex')
     and o.son_kullanma > now() and o.tip = 'depo' and k.aktif;
  if v_rol is null then raise exception 'Oturum gecersiz veya suresi dolmus'; end if;
  if not depo_yetki(v_rol, p_izin) then raise exception 'Bu islem icin yetkiniz yok'; end if;
  return jsonb_build_object('rol', v_rol, 'departman', coalesce(v_dep,'hepsi'));
end $$;

create or replace function public.oturum_depo(p_token text)
returns boolean language sql security definer set search_path = public, extensions as $$
  select exists (select 1 from oturum
                  where token_hash = encode(extensions.digest(coalesce(p_token,''),'sha256'),'hex')
                    and son_kullanma > now() and tip = 'depo');
$$;

create or replace function public.oturum_admin(p_token text)
returns boolean language sql security definer set search_path = public, extensions as $$
  select exists (select 1 from oturum
                  where token_hash = encode(extensions.digest(coalesce(p_token,''),'sha256'),'hex')
                    and son_kullanma > now() and tip = 'admin');
$$;

-- Çıkış
create or replace function public.oturum_iptal(p_token text)
returns jsonb language sql security definer set search_path = public, extensions as $$
  with x as (delete from oturum
              where token_hash = encode(extensions.digest(coalesce(p_token,''),'sha256'),'hex')
             returning 1)
  select jsonb_build_object('ok', true, 'silinen', (select count(*) from x));
$$;

-- Bir kimliğin tüm oturumlarını kapat (PIN/şifre değişimi, kaptan silme)
create or replace function public.oturum_kapat_tumu(p_tip text, p_ref text)
returns void language sql security definer set search_path = public as $$
  delete from oturum
   where tip = p_tip and (p_ref is null or lower(coalesce(ref,'')) = lower(p_ref));
$$;

-- Parametre adı/sayısı değiştiği için create-or-replace yetmez; ESKİ İMZALAR
-- DÜŞÜRÜLÜR. Bu, eski şifre/PIN'li çağrı yüzeyini de tamamen kapatır:
-- iki kapılı mimari bırakılmaz.
drop function if exists public.depo_liste(text, date);
drop function if exists public.depo_envanter(text, date, date);
drop function if exists public.depo_kalem_guncelle(text, text, text, int);
drop function if exists public.depo_durum_degistir(text, text, text);
drop function if exists public.onay_stok_kontrol(text, text);
drop function if exists public.stok_baseline(text, jsonb, boolean);
drop function if exists public.stok_malkabul(text, jsonb, boolean);
drop function if exists public.stok_yukleme_liste(text, int);
drop function if exists public.stok_yukleme_geri_al(text, uuid);
drop function if exists public.stok_liste(text);
drop function if exists public.stok_katalog_disi_sil(text, jsonb);
drop function if exists public.stok_temizle(text);
drop function if exists public.kaptan_liste(text);
drop function if exists public.kaptan_ekle(text, text, text, text, text);
drop function if exists public.kaptan_rol(text, text, text);
drop function if exists public.kaptan_sil(text, text);
drop function if exists public.kaptan_departman(text, text, text);
drop function if exists public.kaptan_pin_degistir(text, text, text);
drop function if exists public.katalog_giris(text);
drop function if exists public.katalog_seed(text, text, jsonb);
drop function if exists public.katalog_ekle(text, text, text, text, text, text);
drop function if exists public.katalog_cikar(text, text, text);
drop function if exists public.katalog_duzelt(text, text, text, text, text, text);
drop function if exists public.katalog_sira(text, text, jsonb);
drop function if exists public.urun_min_ayarla(text, text, numeric);
drop function if exists public.urun_minstok_ayarla(text, text, numeric);
drop function if exists public.outlet_liste(text);
drop function if exists public.outlet_pin_liste(text, text);
drop function if exists public.outlet_pin_ekle(text, text, text, text);
drop function if exists public.outlet_pin_sil(text, uuid);
drop function if exists public.katalog_getir(text, text, text, text);
drop function if exists public.stok_gizli_kodlar(text, text);
drop function if exists public.siparis_gonder(text, text, jsonb, text, text, text, text);
drop function if exists public.bekleyen_siparisler(text, text, text, text);
drop function if exists public.siparis_geri_cagir(text, text, text);
drop function if exists public.siparis_teslim(text, text, text, text, text);
drop function if exists public.kaptan_sifre_degistir(text, text, text);

-- ===== GİRİŞ FONKSİYONLARI (şifre/PIN yalnızca burada kabul edilir) =====
-- Hepsi hata durumunda EXCEPTION ATMAZ: {ok:false} döner. Aksi halde deneme
-- sayacı transaction ile birlikte geri alınır (H-2'nin kök nedeni).

create or replace function public.depo_giris(p_sifre text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
  delete from kaptan_deneme where zaman < now() - interval '1 day';
  -- ORTAK DEPO ŞİFRESİ 1 Eyl 2026'DA KAPATILDI (denetim N-1). Depo personeli
  -- kendi kullanıcı adı + PIN'i ile giriyor; sayaç artık kişiye bağlı.
  -- Eskiden sayaç '#depo' sabit anahtarındaydı, yani KAPI başınaydı: yabancı
  -- biri 5 yanlış denemeyle tüm depoyu 15 dakika dışarıda bırakabiliyordu.
  --
  -- Fonksiyon bilerek DURUYOR: tarayıcısında eski sayfa önbellekte kalmış biri
  -- burayı çağırdığında PGRST202 yerine ne yapması gerektiğini söyleyen bir
  -- mesaj alsın. Sayaca dokunmadan hemen döndüğü için '#depo' yolu tamamen ölü.
  -- Yeniden açmak istenirse: ayarlar'a 'depo_sifre' satırı eklemek yeter.
  if not exists (select 1 from ayarlar where anahtar = 'depo_sifre') then
    return jsonb_build_object('ok', false,
      'hata', 'Ortak depo sifresi kapatildi. Kullanici adi ve PIN ile girin.');
  end if;
  if kaptan_kilitli('#depo') then
    return jsonb_build_object('ok', false,
      'hata', 'Cok fazla hatali deneme. 15 dakika sonra tekrar deneyin.');
  end if;
  if not depo_dogru(p_sifre) then
    insert into kaptan_deneme (kod) values ('#depo');
    return jsonb_build_object('ok', false, 'hata', 'Sifre hatali');
  end if;
  delete from kaptan_deneme where kod = '#depo';
  return jsonb_build_object('ok', true, 'token', oturum_ac('depo', null));
end $$;

create or replace function public.admin_giris(p_sifre text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
  delete from kaptan_deneme where zaman < now() - interval '1 day';
  -- GEÇİŞ: ortak yönetici şifresi. Yönetici kendi kullanıcı adı + parolasına
  -- geçtikten sonra bu kapı kapatılır:
  --     delete from public.ayarlar where anahtar = 'admin_sifre';
  -- Kapanana kadar '#admin' sayacı GLOBAL: yabancı biri 5 yanlış denemeyle
  -- yönetim panelini 15 dakika kilitleyebilir. Kişisel girişte sayaç kişiye
  -- bağlı olduğu için bu sorun yok.
  -- DİKKAT: kapatmadan önce EN AZ İKİ admin rolünde kullanıcı olsun; parolayı
  -- unutursanız geri dönüş yolu yalnızca doğrudan SQL olur.
  if not exists (select 1 from ayarlar where anahtar = 'admin_sifre') then
    return jsonb_build_object('ok', false,
      'hata', 'Ortak yonetici sifresi kapatildi. Kullanici adi ve parola ile girin.');
  end if;
  if kaptan_kilitli('#admin') then
    return jsonb_build_object('ok', false,
      'hata', 'Cok fazla hatali deneme. 15 dakika sonra tekrar deneyin.');
  end if;
  if not admin_dogru(p_sifre) then
    insert into kaptan_deneme (kod) values ('#admin');
    return jsonb_build_object('ok', false, 'hata', 'Sifre hatali');
  end if;
  delete from kaptan_deneme where kod = '#admin';
  return jsonb_build_object('ok', true, 'token', oturum_ac('admin', null));
end $$;

create or replace function public.kaptan_birim_yetkili(p_departman text, p_tur text)
returns boolean language sql immutable as $$
  select coalesce(p_departman,'hepsi') = 'hepsi'
      or coalesce(p_departman,'hepsi') = coalesce(p_tur,'bar');
$$;

create table if not exists public.stok (
  kod        text primary key,
  ad         text,
  birim      text,
  miktar     numeric not null default 0,
  guncelleme timestamptz not null default now()
);

create table if not exists public.katalog (
  liste text not null,
  kod   text not null,
  ad    text not null,
  birim text not null default 'ad',
  grup  text,
  sira  int  not null default 0,
  primary key (liste, kod)
);
create index if not exists katalog_liste_idx on public.katalog (liste, sira);

create table if not exists public.urun_min (
  kod        text primary key,
  min_miktar numeric,
  min_stok   numeric
);
alter table public.urun_min add column if not exists min_miktar numeric;
alter table public.urun_min add column if not exists min_stok   numeric;
alter table public.urun_min alter column min_miktar drop not null;
alter table public.urun_min drop constraint if exists urun_min_min_miktar_check;
alter table public.urun_min drop constraint if exists urun_min_min_miktar_chk;
alter table public.urun_min drop constraint if exists urun_min_min_stok_chk;
alter table public.urun_min add constraint urun_min_min_miktar_chk check (min_miktar is null or min_miktar > 0);
alter table public.urun_min add constraint urun_min_min_stok_chk   check (min_stok   is null or min_stok   >= 0);

-- ================= KİLİT (RLS) =================
-- Hepsinde RLS açık, HİÇBİR policy yok → anon key ile hiçbir tabloya
-- doğrudan erişilemez. Tüm erişim SECURITY DEFINER fonksiyonlarından geçer.
alter table public.siparisler enable row level security;
alter table public.ayarlar    enable row level security;
alter table public.outletler  enable row level security;
alter table public.outlet_pin enable row level security;
alter table public.stok       enable row level security;
alter table public.katalog    enable row level security;
alter table public.urun_min   enable row level security;
alter table public.kaptan     enable row level security;
revoke all on public.siparisler from anon, authenticated;
revoke all on public.ayarlar    from anon, authenticated;
revoke all on public.outletler  from anon, authenticated;
revoke all on public.outlet_pin from anon, authenticated;
revoke all on public.stok       from anon, authenticated;
revoke all on public.katalog    from anon, authenticated;
revoke all on public.urun_min   from anon, authenticated;
revoke all on public.kaptan     from anon, authenticated;

-- ================= ŞİFRELER (mevcut olan KORUNUR) =================
-- MEVCUT KURULUMDA: şifre satırları zaten var, bu blok hiçbir şey yapmaz.
-- SIFIRDAN KURULUMDA: aşağıdaki iki değeri değiştirmeden çalıştırırsanız
-- betik BURADA DURUR. Yer tutucular herkese açık repoda yazılı; sessizce
-- kurulmalarına izin verilmiyor.
do $sifre$
declare
  v_depo  text := 'BURAYA_DEPO_SIFRE';
  v_admin text := 'BURAYA_ADMIN_SIFRE';
  -- Karşılaştırma değerleri PARÇALI yazıldı: yukarıdaki yer tutucuları
  -- ara-değiştir ile toplu değiştirdiğinizde bunlar değişmesin diye.
  s_depo  text := 'BURAYA_' || 'DEPO_SIFRE';
  s_admin text := 'BURAYA_' || 'ADMIN_SIFRE';
begin
  -- Depo rolunde kullanici VARSA ortak sifrenin yoklugu KASITLIDIR: kisisel
  -- hesaplara gecilmis ve o kapi kapatilmistir. Betik onu geri kurmaya
  -- calismamali, yer tutucu yuzunden durmamali.
  if not exists (select 1 from public.ayarlar where anahtar = 'depo_sifre')
     and not exists (select 1 from public.kaptan
                        where rol in ('depo_personel','depo_asistan','depo_yonetici')) then
    if v_depo = s_depo then
      raise exception 'KURULUM DURDU: depo sifresi hala yer tutucu (%). kurulum.sql icinde gercek bir sifre yazip tekrar calistirin.', s_depo;
    end if;
    if length(v_depo) < 12 then
      raise exception 'KURULUM DURDU: depo sifresi en az 12 karakter olmali.';
    end if;
    insert into public.ayarlar (anahtar, deger)
    values ('depo_sifre', extensions.crypt(v_depo, extensions.gen_salt('bf', 10)));
  end if;

  -- Depo'daki ile aynı mantık: admin rolünde kullanıcı varsa ortak şifrenin
  -- yokluğu kasıtlıdır, betik onu geri kurmaya çalışmamalı.
  if not exists (select 1 from public.ayarlar where anahtar = 'admin_sifre')
     and not exists (select 1 from public.kaptan where rol = 'admin') then
    if v_admin = s_admin then
      raise exception 'KURULUM DURDU: admin sifresi hala yer tutucu (%). kurulum.sql icinde gercek bir sifre yazip tekrar calistirin.', s_admin;
    end if;
    if length(v_admin) < 12 then
      raise exception 'KURULUM DURDU: admin sifresi en az 12 karakter olmali.';
    end if;
    insert into public.ayarlar (anahtar, deger)
    values ('admin_sifre', extensions.crypt(v_admin, extensions.gen_salt('bf', 10)));
  end if;
end $sifre$;

-- ================= OUTLET TOHUMU (PIN'ler KORUNUR) =================
insert into public.outletler (kod, ad, tur) values
  ('CSM201', 'ALIBEY RESTAURANT', 'bar'),
  ('CSM202', 'PARK RESTAURANT', 'bar'),
  ('CSM204', 'SAHIL RESTAURANT', 'bar'),
  ('CSM205', 'AQUA RESTAURANT', 'bar'),
  ('CSM206', 'KIYI RESTAURANT', 'bar'),
  ('CSM301', 'TURK KAHVESI', 'bar'),
  ('CSM302', 'CARDAK', 'bar'),
  ('CSM303', 'TALVAR', 'bar'),
  ('CSM304', 'POOL', 'bar'),
  ('CSM305', 'ALI''S PUB', 'bar'),
  ('CSM306', 'TENIS BAR', 'bar'),
  ('CSM307', 'KONAK', 'bar'),
  ('CSM308', 'KARAGOZ', 'bar'),
  ('CSM310', 'ILICA BAR', 'bar'),
  ('CSM311', 'HARLEK', 'bar'),
  ('CSM312', 'HISAR', 'bar'),
  ('CSM313', 'YONCALI', 'bar'),
  ('CSM314', 'FRIG BEACH BAR', 'bar'),
  ('CSM315', 'PAVILLION BAR', 'bar'),
  ('CSM316', 'LOBBY BAR', 'bar'),
  ('CSM317', 'PARK TURK KAHVESI', 'bar'),
  ('CSM318', 'SARAP VE BIRA EVI', 'bar'),
  ('CSM401', 'RESEPSIYON CAY OCAGI', 'bar'),
  ('CSM402', 'PARK RESEPSIYON CAY OCAGI', 'bar'),
  ('CSM403', 'IDARI BINA CAY OCAGI', 'bar'),
  ('CMM201', 'ANAMUTFAK', 'mutfak'),
  ('CMM204', 'PARK MUTFAK', 'mutfak'),
  ('CMM202', 'AQUA MUTFAK', 'mutfak')
on conflict (kod) do update set ad = excluded.ad, tur = excluded.tur;


-- ================= YARDIMCILAR =================
create or replace function public.admin_dogru(p_sifre text)
returns boolean language sql security definer set search_path = public, extensions as $$
  select exists (select 1 from ayarlar where anahtar='admin_sifre'
                 and deger = extensions.crypt(coalesce(p_sifre,''), deger));
$$;

create or replace function public.depo_dogru(p_sifre text)
returns boolean language sql security definer set search_path = public, extensions as $$
  select exists (select 1 from ayarlar where anahtar='depo_sifre'
                 and deger = extensions.crypt(coalesce(p_sifre,''), deger));
$$;


-- ================= HERKESE AÇIK =================

-- Bar/mutfak girişi: outlet var mı + PIN doğru mu (PIN yoksa serbest).
-- Outlet'in birden çok PIN'i olabilir; girilen PIN hangisine uyuyorsa
-- o kişinin etiketi 'gonderen' olarak döner.
create or replace function public.outlet_giris(p_kod text, p_pin text default null)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v_ad text; v_var int; v_gonderen text;
begin
  select ad into v_ad from outletler where kod = p_kod;
  if not found then raise exception 'Gecersiz kod'; end if;

  select count(*) into v_var from outlet_pin where outlet_kod = p_kod;
  if v_var > 0 then
    select etiket into v_gonderen from outlet_pin
     where outlet_kod = p_kod and pin = extensions.crypt(coalesce(p_pin,''), pin) limit 1;
    if v_gonderen is null then raise exception 'PIN gerekli'; end if;
  end if;

  return jsonb_build_object('ok', true, 'kod', p_kod, 'ad', v_ad,
    'pinli', v_var > 0, 'gonderen', v_gonderen);
end $$;

-- Bir listenin ürünleri (min + minstok ile).
-- KİMLİK ŞART: geçerli kaptan PIN'i VEYA admin şifresi. Eskiden argümanı olan ama
-- kimlik istemeyen bir fonksiyondu; anon key ile tüm ürün katalogu (kod, ad, birim,
-- min sipariş/min stok) dışarı alınabiliyordu.
drop function if exists public.katalog_getir(text);
drop function if exists public.katalog_getir(text, text, text);
create or replace function public.katalog_getir(
  p_liste text,
  p_token text default null)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v_kimlik jsonb; v_tur text; v_admin boolean;
begin
  -- Admin oturumu tüm listeleri görebilir; kaptan yalnız kendi departmanını.
  v_admin := oturum_admin(p_token);

  if not v_admin then
    v_kimlik := oturum_kaptan(p_token);
    if not (v_kimlik->>'ok')::boolean then return v_kimlik; end if;

    -- YATAY YETKİ: istenen liste kaptanın departmanına ait olmalı. Eskiden
    -- p_liste hiç denetlenmiyordu; geçerli PIN'i olan bir bar personeli
    -- mutfak katalogunu da çekebiliyordu.
    -- liste = outlet kodu ('CSM315') ya da 'CMM201|KAHVALTI' → outlet kodu ilk parça.
    select tur into v_tur from outletler where kod = split_part(p_liste, '|', 1);
    if not kaptan_birim_yetkili(v_kimlik->>'departman', v_tur) then
      raise exception 'Bu birime yetkiniz yok';
    end if;
  end if;

  return coalesce((select jsonb_agg(
           jsonb_build_object('k', k.kod, 'a', k.ad, 'b', k.birim, 'g', k.grup,
                              'sira', k.sira, 'min', m.min_miktar, 'minstok', m.min_stok)
           order by k.sira)
    from katalog k left join urun_min m on m.kod = k.kod
   where k.liste = p_liste), '[]'::jsonb);
end $$;

-- Stoğu 0/negatif olan kodlar (bar/mutfak bunları gizler).
-- KİMLİK ŞART: eskiden argümansız ve anon'a açıktı; kimlik doğrulamadan
-- stok tablosundan "hangi ürünler tükendi" bilgisi dışarı alınabiliyordu.
-- Artık geçerli + aktif bir kaptan PIN'i ister (kasa farketmez).
drop function if exists public.stok_gizli_kodlar();
create or replace function public.stok_gizli_kodlar(p_token text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v_kimlik jsonb;
begin
  v_kimlik := oturum_kaptan(p_token);
  -- RAISE ETME: sayaç kaydı geri alınır (bkz. kaptan_dogrula notu).
  if not (v_kimlik->>'ok')::boolean then return v_kimlik; end if;
  return coalesce((select jsonb_agg(kod) from stok where miktar <= 0), '[]'::jsonb);
end $$;

-- BAR/MUTFAK → sipariş gönder (SAĞLAMLAŞTIRILMIŞ KÖPRÜ)
--  • outlet allowlist  • kaptan kimliği  • ad'ı SUNUCU belirler
--  • kalem kodu (seed'liyse) listede olmalı  • günlük hız sınırı
drop function if exists public.siparis_gonder(text, text, jsonb);
drop function if exists public.siparis_gonder(text, text, jsonb, text);
drop function if exists public.siparis_gonder(text, text, jsonb, text, text);
drop function if exists public.siparis_gonder(text, text, jsonb, text, text, text);
-- p_pin taşıyan 8 parametreli imza kaldırıldı (aşağıdaki nota bakın).
drop function if exists public.siparis_gonder(text, text, jsonb, text, text, text, text, text);

-- NOT: p_pin parametresi kaldırıldı. Outlet-PIN modelinden kalmıştı; kaptan
-- modeline geçildiğinde gövdede kullanılmayı bıraktı ama imzada durmaya devam
-- etti. Çağırana "PIN de doğrulanıyor" izlenimi veriyordu; hiçbir istemci
-- göndermiyordu. Kimlik artık OTURUM TOKEN'ı ile doğrulanır (p_token).
create or replace function public.siparis_gonder(
  p_outlet_kod  text,
  p_outlet_ad   text,               -- YOK SAYILIR (sunucu outletler'den alır)
  p_kalemler    jsonb,
  p_bolum       text default null,
  p_istemci_id  text default null,
  p_token       text default null   -- oturum token'ı (kaptan girişinden)
)
returns jsonb
language plpgsql security definer set search_path = public, extensions
as $$
declare
  v_tarih date := (now() at time zone 'Europe/Istanbul')::date;
  v_no text; v_saat timestamptz; v_sira int; v_deneme int := 0;
  v_el jsonb; v_m numeric; v_ad text; v_liste text; v_gunluk int;
  v_gonderen text; v_tur text; v_dep text; v_min_hata text;
  v_iid text := nullif(left(coalesce(p_istemci_id, ''), 64), '');
  v_kimlik jsonb;
  rec record;
begin
  -- 1) Outlet gerçek mi + kimlik. TÜM birimler (bar + mutfak) kişi bazlı giriş ister.
  --    ad'ı ve gonderen'i SUNUCU belirler.
  select ad, tur into v_ad, v_tur from outletler where kod = p_outlet_kod;
  if v_ad is null then raise exception 'Gecersiz outlet'; end if;

  -- Kişi (kaptan/personel) kimliği: geçerli + aktif kaptan PIN'i şart (kasa farketmez).
  v_kimlik := oturum_kaptan(p_token);
  -- RAISE ETME: sayaç kaydı geri alınır (bkz. kaptan_dogrula notu).
  if not (v_kimlik->>'ok')::boolean then return v_kimlik; end if;
  v_gonderen := v_kimlik->>'ad';
  v_dep      := v_kimlik->>'departman';

  -- DEPARTMAN SUNUCUDA ZORLANIR. Client'taki birim filtresi yalnızca kolaylıktır;
  -- sessionStorage değiştirilerek atlanabilirdi.
  if not kaptan_birim_yetkili(v_dep, v_tur) then
    raise exception 'Bu birime siparis yetkiniz yok';
  end if;

  -- 2) Kalem listesi biçimi
  if jsonb_typeof(p_kalemler) <> 'array' or jsonb_array_length(p_kalemler) = 0 then
    raise exception 'Kalem listesi bos';
  end if;
  if jsonb_array_length(p_kalemler) > 5000 then raise exception 'Kalem listesi cok buyuk'; end if;

  -- 3) Her kalem: biçim + kod deseni + alanlar + miktar
  for v_el in select * from jsonb_array_elements(p_kalemler) loop
    if jsonb_typeof(v_el) <> 'object' then raise exception 'Gecersiz kalem bicimi'; end if;
    if coalesce(v_el->>'k','') !~ '^[A-Z]{3}[0-9]{8}$' then raise exception 'Gecersiz kalem kodu'; end if;
    if coalesce(v_el->>'a','') = '' or length(v_el->>'a') > 120
       or coalesce(v_el->>'b','') = '' or length(v_el->>'b') > 20 then
      raise exception 'Gecersiz kalem alani';
    end if;
    if (v_el->>'m') is null or (v_el->>'m') !~ '^\d+$' then raise exception 'Gecersiz miktar'; end if;
    v_m := (v_el->>'m')::numeric;
    if v_m <= 0 or v_m > 100000 then raise exception 'Miktar araligi disinda'; end if;
  end loop;

  -- 3b) MİNİMUM SİPARİŞ MİKTARI sunucuda da zorlanır (client kontrolü atlanabilir).
  select string_agg(el->>'a' || ' (en az ' || um.min_miktar || ')', ', ') into v_min_hata
    from jsonb_array_elements(p_kalemler) el
    join urun_min um on um.kod = el->>'k'
   where um.min_miktar is not null and (el->>'m')::numeric < um.min_miktar;
  if v_min_hata is not null then
    raise exception 'Minimum siparis miktarinin altinda: %', v_min_hata;
  end if;

  -- 4) Kalem kodları o listenin katalogunda olmalı (liste seed'liyse zorlanır;
  --    değilse gömülü listeyle çalışan bara izin verilir).
  v_liste := case when coalesce(p_bolum,'') <> '' then p_outlet_kod || '|' || p_bolum else p_outlet_kod end;
  if exists (select 1 from katalog where liste = v_liste) then
    if exists (
      select 1 from jsonb_array_elements(p_kalemler) el
       where not exists (select 1 from katalog k where k.liste = v_liste and k.kod = el->>'k')
    ) then raise exception 'Katalog disi kalem'; end if;
  end if;

  -- 5) Günlük hız sınırı (flood engeli): outlet başına 200
  select count(*) into v_gunluk from siparisler where tarih = v_tarih and outlet_kod = p_outlet_kod;
  if v_gunluk >= 200 then raise exception 'Gunluk siparis siniri asildi'; end if;

  -- 6) İdempotency: aynı istemci kimliği varsa var olanı döndür
  if v_iid is not null then
    select siparis_no, gonderilme_saati, jsonb_array_length(kalemler) into rec
      from siparisler where istemci_id = v_iid;
    if found then
      return jsonb_build_object('ok', true, 'tekrar', true, 'siparis_no', rec.siparis_no,
        'saat', to_char(rec.gonderilme_saati at time zone 'Europe/Istanbul','HH24:MI'),
        'kalem', rec.jsonb_array_length);
    end if;
  end if;

  -- 7) Numara üret (max+1) + yaz (outlet_ad = SUNUCU değeri)
  loop
    v_deneme := v_deneme + 1;
    select coalesce(max(split_part(siparis_no,'-',3)::int),0)+1 into v_sira
      from siparisler where tarih = v_tarih;
    v_no := 'SIP-' || to_char(v_tarih,'YYYYMMDD') || '-' || lpad(v_sira::text,3,'0');
    begin
      insert into siparisler (tarih, outlet_kod, outlet_ad, kalemler, siparis_no, durum, bolum, istemci_id, gonderen)
      values (v_tarih, p_outlet_kod, left(v_ad,120), p_kalemler, v_no, 'talep',
              nullif(left(coalesce(p_bolum,''),40),''), v_iid, v_gonderen)
      returning gonderilme_saati into v_saat;
      exit;
    exception when unique_violation then
      if v_iid is not null then
        select siparis_no, gonderilme_saati, jsonb_array_length(kalemler) into rec
          from siparisler where istemci_id = v_iid;
        if found then
          return jsonb_build_object('ok', true, 'tekrar', true, 'siparis_no', rec.siparis_no,
            'saat', to_char(rec.gonderilme_saati at time zone 'Europe/Istanbul','HH24:MI'),
            'kalem', rec.jsonb_array_length);
        end if;
      end if;
      if v_deneme >= 15 then raise exception 'Siparis numarasi uretilemedi, tekrar deneyin'; end if;
    end;
  end loop;

  return jsonb_build_object('ok', true, 'siparis_no', v_no,
    'saat', to_char(v_saat at time zone 'Europe/Istanbul','HH24:MI'),
    'kalem', jsonb_array_length(p_kalemler));
end $$;

-- Kaldırılan eski fonksiyon
drop function if exists public.siparis_getir(text);


-- ================= DEPO (şifre ister) =================

create or replace function public.depo_liste(p_token text, p_tarih date default null)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v_tarih date := coalesce(p_tarih, (now() at time zone 'Europe/Istanbul')::date);
begin
  perform depo_izin(p_token, 'talep');
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'siparis_no', siparis_no, 'outlet_kod', outlet_kod, 'outlet_ad', outlet_ad,
             'bolum', bolum, 'gonderen', gonderen, 'kalemler', kalemler,
             'gonderilme_saati', gonderilme_saati, 'durum', durum, 'onay_saati', onay_saati,
             'iptal_saati', iptal_saati, 'iptal_eden', iptal_eden,
             'teslim_durum', teslim_durum, 'teslim_eden', teslim_eden,
             'teslim_not', teslim_not, 'teslim_saati', teslim_saati)
             order by gonderilme_saati desc)
      from siparisler where tarih = v_tarih), '[]'::jsonb);
end $$;

create or replace function public.depo_envanter(p_token text, p_bas date, p_bit date)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  v_bas date := coalesce(p_bas, (now() at time zone 'Europe/Istanbul')::date);
  v_bit date := coalesce(p_bit, (now() at time zone 'Europe/Istanbul')::date);
  v_izin jsonb;
  v_dep  text;
begin
  v_izin := depo_izin(p_token, 'envanter');
  -- Departman yöneticisi dışındakiler tüm birimleri görür.
  v_dep := case when v_izin->>'rol' = 'departman_yonetici'
                then v_izin->>'departman' else 'hepsi' end;
  if v_bit < v_bas then raise exception 'Bitis tarihi baslangictan once olamaz'; end if;
  if v_bit - v_bas > 92 then raise exception 'En fazla 92 gunluk aralik sorgulanabilir'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'siparis_no', siparis_no, 'tarih', tarih, 'outlet_kod', outlet_kod,
             'outlet_ad', outlet_ad, 'bolum', bolum, 'gonderen', gonderen, 'kalemler', kalemler,
             'gonderilme_saati', gonderilme_saati, 'durum', durum, 'onay_saati', onay_saati)
             order by gonderilme_saati)
      from siparisler s where s.tarih between v_bas and v_bit
       -- DEPARTMAN KAPSAMI: departman yöneticisi yalnız kendi birimlerini
       -- görür (mutfak şefi mutfakları, bar müdürü barları). Diğer depo
       -- rollerinde departman 'hepsi' olduğu için koşul her satırı geçirir.
       and kaptan_birim_yetkili(v_dep,
             (select o.tur from outletler o where o.kod = s.outlet_kod))
      ), '[]'::jsonb);
end $$;

create or replace function public.depo_kalem_guncelle(p_token text, p_siparis_no text, p_kalem_kod text, p_onay int)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v_durum text;
begin
  perform depo_izin(p_token, 'talep');
  if p_onay is null or p_onay < 0 or p_onay > 100000 then raise exception 'Gecersiz miktar'; end if;
  select durum into v_durum from siparisler where siparis_no = p_siparis_no;
  if not found then raise exception 'Siparis bulunamadi'; end if;
  if v_durum = 'onaylandi' then raise exception 'Siparis kilitli, once kilidi acin'; end if;
  if v_durum = 'iptal' then raise exception 'Siparis iptal edilmis'; end if;
  update siparisler set kalemler = (
      select jsonb_agg(case when el->>'k' = p_kalem_kod
                            then el || jsonb_build_object('o', p_onay) else el end order by ord)
        from jsonb_array_elements(kalemler) with ordinality as t(el, ord))
   where siparis_no = p_siparis_no;
  return jsonb_build_object('ok', true);
end $$;

-- Onayda TABAN STOK KESİN ENGEL + stok düş / kilit açınca geri ekle
create or replace function public.depo_durum_degistir(p_token text, p_siparis_no text, p_durum text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v_saat timestamptz; v_eski text; v_engel text;
begin
  perform depo_izin(p_token, 'talep');
  if p_durum not in ('talep','onaylandi') then raise exception 'Gecersiz durum'; end if;
  select durum into v_eski from siparisler where siparis_no = p_siparis_no;
  if not found then raise exception 'Siparis bulunamadi'; end if;
  -- İptal edilmiş sipariş onaylanamaz: stok düşmeden durum 'onaylandi' olurdu.
  if v_eski = 'iptal' then raise exception 'Siparis iptal edilmis'; end if;

  if p_durum = 'onaylandi' and v_eski = 'talep' then
    select string_agg(s.ad || ' (' || st.miktar || '->' || (st.miktar - s.mik)
                      || ', min ' || um.min_stok || ')', ', ') into v_engel
      from (select el->>'k' kod, el->>'a' ad,
                   coalesce((el->>'o')::numeric,(el->>'m')::numeric) mik
              from siparisler ss, jsonb_array_elements(ss.kalemler) el
             where ss.siparis_no = p_siparis_no) s
      join stok st on st.kod = s.kod
      join urun_min um on um.kod = s.kod
     where um.min_stok is not null and s.mik > 0 and (st.miktar - s.mik) < um.min_stok;
    if v_engel is not null then raise exception 'Taban stok engeli: %', v_engel; end if;

    update stok s set miktar = s.miktar - x.mik, guncelleme = now()
      from (select el->>'k' kod, coalesce((el->>'o')::numeric,(el->>'m')::numeric) mik
              from siparisler ss, jsonb_array_elements(ss.kalemler) el
             where ss.siparis_no = p_siparis_no) x
     where s.kod = x.kod and x.mik > 0;
  elsif p_durum = 'talep' and v_eski = 'onaylandi' then
    update stok s set miktar = s.miktar + x.mik, guncelleme = now()
      from (select el->>'k' kod, coalesce((el->>'o')::numeric,(el->>'m')::numeric) mik
              from siparisler ss, jsonb_array_elements(ss.kalemler) el
             where ss.siparis_no = p_siparis_no) x
     where s.kod = x.kod and x.mik > 0;
  end if;

  -- Kilit açılırsa kaptanın teslim onayı geçersizdir: depo düzeltme yapacak,
  -- kaptan yeniden kontrol etmeli.
  update siparisler set durum = p_durum,
         onay_saati = case when p_durum='onaylandi' then now() else null end,
         teslim_durum = case when p_durum='talep' then null else teslim_durum end,
         teslim_saati = case when p_durum='talep' then null else teslim_saati end,
         teslim_eden  = case when p_durum='talep' then null else teslim_eden  end,
         teslim_not   = case when p_durum='talep' then null else teslim_not   end
   where siparis_no = p_siparis_no returning onay_saati into v_saat;
  return jsonb_build_object('ok', true, 'durum', p_durum,
    'saat', case when v_saat is null then null
                 else to_char(v_saat at time zone 'Europe/Istanbul','HH24:MI') end);
end $$;

create or replace function public.onay_stok_kontrol(p_token text, p_siparis_no text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
  perform depo_izin(p_token, 'talep');
  return coalesce((
    select jsonb_agg(jsonb_build_object('kod', s.kod, 'ad', s.ad, 'mevcut', st.miktar,
             'dusecek', s.mik, 'sonra', st.miktar - s.mik, 'min_stok', um.min_stok))
    from (select el->>'k' kod, el->>'a' ad,
                 coalesce((el->>'o')::numeric,(el->>'m')::numeric) mik
            from siparisler ss, jsonb_array_elements(ss.kalemler) el
           where ss.siparis_no = p_siparis_no) s
    join stok st on st.kod = s.kod
    join urun_min um on um.kod = s.kod
    where um.min_stok is not null and s.mik > 0 and (st.miktar - s.mik) < um.min_stok
  ), '[]'::jsonb);
end $$;

-- ================= STOK YÜKLEME KAYDI (mükerrer engel + geri alma) =================
-- Mal kabul TOPLAYARAK çalışır; aynı KUM dosyası ikinci kez yüklenirse gelen
-- miktarlar sessizce ikiye katlanıyordu (ağ koparınca "Uygula"ya tekrar basmak
-- da aynı sonucu veriyordu). Artık her yükleme, İÇERİK PARMAK İZİYLE kaydedilir:
-- imza = sha256("kod:miktar;kod:miktar;..." kod sırasında). Parmak izi SUNUCUDA
-- hesaplanır — istemciye güvenilmez, eski istemciler de otomatik korunur.
-- Aynı imza ikinci kez gelirse REDDEDİLİR; bilerek geçmek için p_zorla => true.
--
-- Her kayıt uygulanan miktarları VE yükleme öncesi stok değerlerini tutar:
--   kalemler = [{k: kod, a: ad, b: birim, m: uygulanan, e: önceki stok (null = ürün yoktu)}]
-- Böylece yanlış yükleme geri alınabilir (bkz. stok_yukleme_geri_al).

create table if not exists public.stok_yukleme (
  id              uuid primary key default gen_random_uuid(),
  tarih           date not null default (now() at time zone 'Europe/Istanbul')::date,
  mod             text not null,
  imza            text not null,
  kalem_sayisi    int  not null default 0,
  toplam          numeric not null default 0,
  kalemler        jsonb not null default '[]'::jsonb,
  zorlandi        boolean not null default false,
  geri_alindi     boolean not null default false,
  geri_alma_saati timestamptz,
  olusturma       timestamptz not null default now()
);
alter table public.stok_yukleme drop constraint if exists stok_yukleme_mod_chk;
alter table public.stok_yukleme add constraint stok_yukleme_mod_chk check (mod in ('baseline','malkabul'));
create index if not exists stok_yukleme_zaman_idx on public.stok_yukleme (olusturma desc);
-- Bir imza aynı anda yalnızca bir GEÇERLİ yüklemede olabilir. Geri alınanlar ve
-- bilerek zorlananlar dışarıda kalır (yarış durumuna karşı ikinci kemer).
create unique index if not exists stok_yukleme_imza_idx
  on public.stok_yukleme (imza) where (not geri_alindi and not zorlandi);

alter table public.stok_yukleme enable row level security;
revoke all on public.stok_yukleme from anon, authenticated;


-- STOK yükleme / listeleme / temizleme
-- Eski iki parametreli sürümler kaldırılır; yeni sürümde p_zorla VARSAYILANLI,
-- yani {p_sifre, p_kalemler} ile çağıran eski istemci de çalışmaya devam eder.
drop function if exists public.stok_baseline(text, jsonb);
drop function if exists public.stok_malkabul(text, jsonb);

create or replace function public.stok_baseline(p_token text, p_kalemler jsonb, p_zorla boolean default false)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  v_kalemler jsonb; v_imza text; v_adet int; v_toplam numeric;
  v_eski timestamptz; v_eskimod text; v_mukerrer boolean := false;
begin
  perform depo_izin(p_token, 'stok_yukle');
  if jsonb_typeof(p_kalemler) <> 'array' then raise exception 'Gecersiz veri'; end if;

  -- Dosyada aynı kod birden çok kez geçebilir (çok sayfalı Excel). Baseline bir
  -- ANLIK GÖRÜNTÜ olduğu için tek kayda indirilir (en büyük değer alınır).
  -- Eskiden bu, "ON CONFLICT ... cannot affect row a second time" ile patlıyordu.
  with ham as (
    select el->>'k' kod, left(el->>'a',120) ad, left(coalesce(el->>'b','ad'),20) birim,
           (el->>'m')::numeric miktar
      from jsonb_array_elements(p_kalemler) el
     where el->>'k' ~ '^[A-Z]{3}[0-9]{8}$' and (el->>'m') ~ '^-?[0-9]+(\.[0-9]+)?$'),
  veri as (select kod, max(ad) ad, max(birim) birim, max(miktar) miktar from ham group by kod)
  select coalesce(jsonb_agg(jsonb_build_object(
           'k', v.kod, 'a', v.ad, 'b', v.birim, 'm', v.miktar, 'e', s.miktar) order by v.kod), '[]'::jsonb)
    into v_kalemler
    from veri v left join stok s on s.kod = v.kod;

  v_adet := jsonb_array_length(v_kalemler);
  if v_adet = 0 then raise exception 'Uygulanabilir kalem yok'; end if;

  select encode(extensions.digest(
           string_agg((el->>'k') || ':' || (el->>'m'), ';' order by el->>'k'), 'sha256'), 'hex'),
         coalesce(sum((el->>'m')::numeric), 0)
    into v_imza, v_toplam
    from jsonb_array_elements(v_kalemler) el;

  select olusturma, mod into v_eski, v_eskimod
    from stok_yukleme where imza = v_imza and not geri_alindi
   order by olusturma desc limit 1;
  if found then
    v_mukerrer := true;
    if not coalesce(p_zorla, false) then
      raise exception 'Bu dosya zaten yuklendi: % (%). Yine de uygulamak icin "yine de uygula" isaretleyin.',
        to_char(v_eski at time zone 'Europe/Istanbul', 'DD.MM.YYYY HH24:MI'), v_eskimod;
    end if;
  end if;

  insert into stok (kod, ad, birim, miktar, guncelleme)
  select el->>'k', el->>'a', el->>'b', (el->>'m')::numeric, now()
    from jsonb_array_elements(v_kalemler) el
  on conflict (kod) do update set miktar=excluded.miktar, ad=excluded.ad,
    birim=excluded.birim, guncelleme=now();

  insert into stok_yukleme (mod, imza, kalem_sayisi, toplam, kalemler, zorlandi)
  values ('baseline', v_imza, v_adet, v_toplam, v_kalemler, v_mukerrer);

  return jsonb_build_object('ok', true, 'adet', v_adet, 'toplam', v_toplam, 'zorlandi', v_mukerrer);
end $$;

create or replace function public.stok_malkabul(p_token text, p_kalemler jsonb, p_zorla boolean default false)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  v_kalemler jsonb; v_imza text; v_adet int; v_toplam numeric;
  v_eski timestamptz; v_eskimod text; v_mukerrer boolean := false;
begin
  perform depo_izin(p_token, 'stok_yukle');
  if jsonb_typeof(p_kalemler) <> 'array' then raise exception 'Gecersiz veri'; end if;

  -- Mal kabulde aynı kod birden çok satırda gelebilir → TOPLANIR (gerçekten iki
  -- kalem girişi olabilir). Tek satıra indirmek ON CONFLICT çakışmasını da önler.
  with ham as (
    select el->>'k' kod, left(el->>'a',120) ad, left(coalesce(el->>'b','ad'),20) birim,
           (el->>'m')::numeric miktar
      from jsonb_array_elements(p_kalemler) el
     where el->>'k' ~ '^[A-Z]{3}[0-9]{8}$' and (el->>'m') ~ '^[0-9]+(\.[0-9]+)?$'
       and (el->>'m')::numeric > 0),
  veri as (select kod, max(ad) ad, max(birim) birim, sum(miktar) miktar from ham group by kod)
  select coalesce(jsonb_agg(jsonb_build_object(
           'k', v.kod, 'a', v.ad, 'b', v.birim, 'm', v.miktar, 'e', s.miktar) order by v.kod), '[]'::jsonb)
    into v_kalemler
    from veri v left join stok s on s.kod = v.kod;

  v_adet := jsonb_array_length(v_kalemler);
  if v_adet = 0 then raise exception 'Uygulanabilir kalem yok (gelen miktari 0 olan dosya)'; end if;

  select encode(extensions.digest(
           string_agg((el->>'k') || ':' || (el->>'m'), ';' order by el->>'k'), 'sha256'), 'hex'),
         coalesce(sum((el->>'m')::numeric), 0)
    into v_imza, v_toplam
    from jsonb_array_elements(v_kalemler) el;

  select olusturma, mod into v_eski, v_eskimod
    from stok_yukleme where imza = v_imza and not geri_alindi
   order by olusturma desc limit 1;
  if found then
    v_mukerrer := true;
    if not coalesce(p_zorla, false) then
      raise exception 'Bu dosya zaten yuklendi: % (%). Yine de uygulamak icin "yine de uygula" isaretleyin.',
        to_char(v_eski at time zone 'Europe/Istanbul', 'DD.MM.YYYY HH24:MI'), v_eskimod;
    end if;
  end if;

  insert into stok (kod, ad, birim, miktar, guncelleme)
  select el->>'k', el->>'a', el->>'b', (el->>'m')::numeric, now()
    from jsonb_array_elements(v_kalemler) el
  on conflict (kod) do update set miktar=stok.miktar+excluded.miktar, guncelleme=now();

  insert into stok_yukleme (mod, imza, kalem_sayisi, toplam, kalemler, zorlandi)
  values ('malkabul', v_imza, v_adet, v_toplam, v_kalemler, v_mukerrer);

  return jsonb_build_object('ok', true, 'adet', v_adet, 'toplam', v_toplam, 'zorlandi', v_mukerrer);
end $$;

-- Son yüklemeler (kalemler dönmez — liste hafif kalsın)
create or replace function public.stok_yukleme_liste(p_token text, p_adet int default 30)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
  perform depo_izin(p_token, 'stok_yukle');
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', t.id, 'tarih', t.tarih, 'mod', t.mod, 'kalem_sayisi', t.kalem_sayisi,
             'toplam', t.toplam, 'zorlandi', t.zorlandi, 'geri_alindi', t.geri_alindi,
             'geri_alma_saati', t.geri_alma_saati, 'olusturma', t.olusturma,
             'imza', left(t.imza, 10)) order by t.olusturma desc)
      from (select * from stok_yukleme order by olusturma desc
             limit least(coalesce(p_adet, 30), 200)) t), '[]'::jsonb);
end $$;

-- Bir yüklemeyi geri al.
--  • mal kabul → eklenen miktar geri ÇIKARILIR (aradaki sipariş onayları korunur)
--  • baseline  → yükleme ÖNCESİ değerlere dönülür (o yüklemeden sonraki
--                onay düşümleri de geri gelir; bu yüzden istemci uyarı gösterir)
-- Yalnızca EN YENİ geçerli yükleme geri alınabilir: daha yeni bir yükleme
-- araya girmişse eski kaydın "önceki değer"leri artık doğru değildir.
create or replace function public.stok_yukleme_geri_al(p_token text, p_id uuid)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v_mod text; v_kalemler jsonb; v_zaman timestamptz; v_geri boolean; v_adet int;
begin
  perform depo_izin(p_token, 'stok_sil');
  select mod, kalemler, olusturma, geri_alindi
    into v_mod, v_kalemler, v_zaman, v_geri
    from stok_yukleme where id = p_id;
  if not found then raise exception 'Yukleme kaydi bulunamadi'; end if;
  if v_geri then raise exception 'Bu yukleme zaten geri alindi'; end if;
  if exists (select 1 from stok_yukleme
              where olusturma > v_zaman and not geri_alindi) then
    raise exception 'Once bundan sonraki yuklemeleri geri alin (en yeniden eskiye dogru)';
  end if;

  if v_mod = 'malkabul' then
    update stok s set miktar = s.miktar - (el->>'m')::numeric, guncelleme = now()
      from jsonb_array_elements(v_kalemler) el
     where s.kod = el->>'k';
  else
    update stok s set miktar = (el->>'e')::numeric, guncelleme = now()
      from jsonb_array_elements(v_kalemler) el
     where s.kod = el->>'k' and (el->>'e') is not null;
  end if;

  -- Bu yüklemeyle İLK KEZ oluşmuş kayıtlar tamamen silinir
  delete from stok where kod in (
    select el->>'k' from jsonb_array_elements(v_kalemler) el where (el->>'e') is null);

  update stok_yukleme set geri_alindi = true, geri_alma_saati = now() where id = p_id;
  v_adet := jsonb_array_length(v_kalemler);
  return jsonb_build_object('ok', true, 'adet', v_adet, 'mod', v_mod);
end $$;

create or replace function public.stok_liste(p_token text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
  perform depo_izin(p_token, 'stok_gor');
  return coalesce((select jsonb_agg(jsonb_build_object('kod',kod,'ad',ad,'birim',birim,
    'miktar',miktar,'guncelleme',guncelleme) order by kod) from stok), '[]'::jsonb);
end $$;

-- Katalog dışı stok temizle (yiyecek/içecek YIY/ICA/ICB KORUNUR)
create or replace function public.stok_katalog_disi_sil(p_token text, p_kodlar jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v_silinen int;
begin
  perform depo_izin(p_token, 'stok_sil');
  if jsonb_typeof(p_kodlar) <> 'array' or jsonb_array_length(p_kodlar) = 0 then
    raise exception 'Katalog listesi bos'; end if;
  with sil as (
    delete from stok where kod not in (select jsonb_array_elements_text(p_kodlar))
      and kod !~ '^(YIY|ICA|ICB)[0-9]' returning 1)
  select count(*) into v_silinen from sil;
  return jsonb_build_object('ok', true, 'silinen', v_silinen);
end $$;

create or replace function public.stok_temizle(p_token text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v_silinen int;
begin
  perform depo_izin(p_token, 'stok_sil');
  with sil as (delete from stok returning 1) select count(*) into v_silinen from sil;
  return jsonb_build_object('ok', true, 'silinen', v_silinen);
end $$;


-- ================= ADMIN (yönetici şifresi ister) =================

create or replace function public.katalog_giris(p_token text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
  if not oturum_admin(p_token) then raise exception 'Oturum gecersiz veya suresi dolmus'; end if;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.katalog_seed(p_token text, p_liste text, p_kalemler jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v_adet int;
begin
  if not oturum_admin(p_token) then raise exception 'Oturum gecersiz veya suresi dolmus'; end if;
  if coalesce(p_liste,'') = '' then raise exception 'Liste bos'; end if;
  if jsonb_typeof(p_kalemler) <> 'array' then raise exception 'Gecersiz veri'; end if;
  delete from katalog where liste = p_liste;
  with veri as (
    select el->>'k' kod, left(el->>'a',120) ad, left(coalesce(el->>'b','ad'),20) birim,
           left(coalesce(el->>'g',''),60) grup, coalesce((el->>'sira')::int,0) sira
      from jsonb_array_elements(p_kalemler) el
     where el->>'k' ~ '^[A-Z]{3}[0-9]{8}$' and coalesce(el->>'a','') <> ''),
  yaz as (
    insert into katalog (liste, kod, ad, birim, grup, sira)
    select p_liste, kod, ad, birim, nullif(grup,''), sira from veri
    on conflict (liste, kod) do update set ad=excluded.ad, birim=excluded.birim,
      grup=excluded.grup, sira=excluded.sira returning 1)
  select count(*) into v_adet from yaz;
  return jsonb_build_object('ok', true, 'adet', v_adet);
end $$;

create or replace function public.katalog_ekle(p_token text, p_liste text, p_kod text, p_ad text, p_birim text, p_grup text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v_sira int;
begin
  if not oturum_admin(p_token) then raise exception 'Oturum gecersiz veya suresi dolmus'; end if;
  if coalesce(p_kod,'') !~ '^[A-Z]{3}[0-9]{8}$' then raise exception 'Gecersiz kod (ornek: ICA02000001)'; end if;
  if coalesce(p_ad,'') = '' then raise exception 'Ad bos olamaz'; end if;
  select coalesce(max(sira),0)+1 into v_sira from katalog where liste = p_liste;
  insert into katalog (liste, kod, ad, birim, grup, sira)
  values (p_liste, p_kod, left(p_ad,120), left(coalesce(p_birim,'ad'),20),
          nullif(left(coalesce(p_grup,''),60),''), v_sira)
  on conflict (liste, kod) do update set ad=excluded.ad, birim=excluded.birim, grup=excluded.grup;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.katalog_cikar(p_token text, p_liste text, p_kod text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
  if not oturum_admin(p_token) then raise exception 'Oturum gecersiz veya suresi dolmus'; end if;
  delete from katalog where liste = p_liste and kod = p_kod;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.katalog_duzelt(p_token text, p_liste text, p_kod text, p_ad text, p_birim text, p_grup text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
  if not oturum_admin(p_token) then raise exception 'Oturum gecersiz veya suresi dolmus'; end if;
  if coalesce(p_ad,'') = '' then raise exception 'Ad bos olamaz'; end if;
  update katalog set ad=left(p_ad,120), birim=left(coalesce(p_birim,'ad'),20),
    grup=nullif(left(coalesce(p_grup,''),60),'') where liste=p_liste and kod=p_kod;
  if not found then raise exception 'Urun bulunamadi'; end if;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.katalog_sira(p_token text, p_liste text, p_kodlar jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
  if not oturum_admin(p_token) then raise exception 'Oturum gecersiz veya suresi dolmus'; end if;
  update katalog k set sira = x.ord
    from (select value kod, ordinality ord from jsonb_array_elements_text(p_kodlar) with ordinality) x
   where k.liste = p_liste and k.kod = x.kod;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.urun_min_ayarla(p_token text, p_kod text, p_min numeric)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
  if not oturum_admin(p_token) then raise exception 'Oturum gecersiz veya suresi dolmus'; end if;
  if coalesce(p_kod,'') !~ '^[A-Z]{3}[0-9]{8}$' then raise exception 'Gecersiz kod'; end if;
  insert into urun_min (kod, min_miktar) values (p_kod, nullif(p_min,0))
  on conflict (kod) do update set min_miktar = nullif(p_min,0);
  delete from urun_min where kod = p_kod and min_miktar is null and min_stok is null;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.urun_minstok_ayarla(p_token text, p_kod text, p_minstok numeric)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
  if not oturum_admin(p_token) then raise exception 'Oturum gecersiz veya suresi dolmus'; end if;
  if coalesce(p_kod,'') !~ '^[A-Z]{3}[0-9]{8}$' then raise exception 'Gecersiz kod'; end if;
  if p_minstok is not null and p_minstok < 0 then raise exception 'Negatif olamaz'; end if;
  insert into urun_min (kod, min_stok) values (p_kod, p_minstok)
  on conflict (kod) do update set min_stok = p_minstok;
  delete from urun_min where kod = p_kod and min_miktar is null and min_stok is null;
  return jsonb_build_object('ok', true);
end $$;

-- Outlet listesi + her outlet'in PIN sayısı (admin genel görünüm)
create or replace function public.outlet_liste(p_token text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
  if not oturum_admin(p_token) then raise exception 'Oturum gecersiz veya suresi dolmus'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
    'kod', o.kod, 'ad', o.ad, 'tur', o.tur,
    'pin_sayisi', (select count(*) from outlet_pin p where p.outlet_kod = o.kod)) order by o.kod)
    from outletler o), '[]'::jsonb);
end $$;

-- Bir outlet'in PIN'leri (etiketler; hash dönmez)
create or replace function public.outlet_pin_liste(p_token text, p_kod text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
  if not oturum_admin(p_token) then raise exception 'Oturum gecersiz veya suresi dolmus'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', id, 'etiket', etiket) order by etiket)
    from outlet_pin where outlet_kod = p_kod), '[]'::jsonb);
end $$;

-- PIN ekle (outlet başına en fazla 10; etiket = gönderen kimliği)
create or replace function public.outlet_pin_ekle(p_token text, p_kod text, p_etiket text, p_pin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v_adet int;
begin
  if not oturum_admin(p_token) then raise exception 'Oturum gecersiz veya suresi dolmus'; end if;
  if not exists (select 1 from outletler where kod = p_kod) then raise exception 'Outlet yok'; end if;
  if coalesce(p_etiket,'') = '' then raise exception 'Etiket (gonderen) bos olamaz'; end if;
  if p_pin !~ '^[0-9]{3,12}$' then raise exception 'PIN 3-12 haneli sayi olmali'; end if;
  select count(*) into v_adet from outlet_pin where outlet_kod = p_kod;
  if v_adet >= 10 then raise exception 'Bu outlet icin en fazla 10 PIN'; end if;
  insert into outlet_pin (outlet_kod, etiket, pin)
  values (p_kod, left(p_etiket,40), extensions.crypt(p_pin, extensions.gen_salt('bf', 10)))
  on conflict (outlet_kod, etiket) do update set pin = excluded.pin;
  return jsonb_build_object('ok', true);
end $$;

-- PIN sil (id ile)
create or replace function public.outlet_pin_sil(p_token text, p_id uuid)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
  if not oturum_admin(p_token) then raise exception 'Oturum gecersiz veya suresi dolmus'; end if;
  delete from outlet_pin where id = p_id;
  return jsonb_build_object('ok', true);
end $$;

-- ===== KAPTAN =====
-- NOT: kaptan_liste_ac KALDIRILDI. Giriş isim listesinden kullanıcı adı+PIN'e geçince
-- tüketicisi kalmadı ve personel ad listesini anon'a açıyordu (PII sızıntısı).
drop function if exists public.kaptan_liste_ac();

-- Kaptan girişi: kod (BÜYÜK/küçük harf fark etmez) + PIN.
-- Hatalı denemede EXCEPTION ATMAZ ({ok:false} döner) — aksi halde deneme sayacı
-- rollback olur ve brute-force engeli hiç çalışmaz.
create or replace function public.kaptan_giris(p_kod text, p_pin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v_kod text; v_kimlik jsonb; v_rol text; v_k text := lower(coalesce(p_kod,''));
begin
  -- Eski kayıtları temizle (tablo şişmesin)
  delete from kaptan_deneme where zaman < now() - interval '1 day';

  -- Doğrulama + başarısız deneme kaydı tek kapıda: kaptan_dogrula.
  v_kimlik := kaptan_dogrula(p_kod, p_pin);
  if not (v_kimlik->>'ok')::boolean then
    -- Giriş ekranına özgü metin korunur (kilit mesajı olduğu gibi geçer).
    if v_kimlik->>'hata' = 'Kullanici girisi gerekli' then
      return jsonb_build_object('ok', false, 'hata', 'Kaptan kodu veya PIN hatali');
    end if;
    return v_kimlik;
  end if;

  select kod into v_kod from kaptan where lower(kod) = v_k;
  delete from kaptan_deneme where kod = v_k;      -- başarılı giriş sayacı sıfırlar

  -- Oturumun TİPİ role göre açılır. Böylece depo rolündeki kişinin token'ı
  -- oturum_depo()'dan geçer ve ~20 depo RPC'sinin hiçbiri değişmez; kaptan
  -- rolündeki kişinin token'ı ise depo RPC'lerinden geçmez. Yanlış ekrana
  -- giren kişi giriş yapmış görünüp sonra sessizce reddedilmesin diye 'rol'
  -- yanıtta da dönüyor; ekranlar buna bakıp açık mesaj veriyor.
  v_rol := coalesce(v_kimlik->>'rol', 'kaptan');
  return jsonb_build_object('ok', true, 'kod', v_kod, 'ad', v_kimlik->>'ad',
    'departman', v_kimlik->>'departman', 'rol', v_rol,
    'token', oturum_ac(rol_oturum_tipi(v_rol), v_kod));
end $$;

-- Admin: kaptan listesi (PIN yok)
create or replace function public.kaptan_liste(p_token text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
  if not oturum_admin(p_token) then raise exception 'Oturum gecersiz veya suresi dolmus'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('kod', kod, 'ad', ad, 'aktif', aktif,
                                    'departman', departman, 'rol', coalesce(rol,'kaptan')) order by ad)
    from kaptan), '[]'::jsonb);
end $$;

-- Admin: kaptan ekle/güncelle (departman ile)
drop function if exists public.kaptan_ekle(text, text, text, text);
create or replace function public.kaptan_ekle(p_token text, p_kod text, p_ad text, p_pin text,
                                              p_departman text default 'hepsi',
                                              p_rol text default 'kaptan')
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v_dep text := coalesce(nullif(p_departman,''),'hepsi');
        v_rol text := coalesce(nullif(p_rol,''),'kaptan');
begin
  if not oturum_admin(p_token) then raise exception 'Oturum gecersiz veya suresi dolmus'; end if;
  if coalesce(p_kod,'') !~ '^[A-Za-z0-9]{1,10}$' then raise exception 'Kod 1-10 harf/rakam olmali'; end if;
  if coalesce(p_ad,'') = '' then raise exception 'Ad bos olamaz'; end if;
  if not sifre_kurali_uygun(v_rol, p_pin) then raise exception '%', sifre_kurali_metni(v_rol); end if;
  if v_rol not in ('kaptan','depo_personel','depo_asistan','depo_yonetici','departman_yonetici','admin') then raise exception 'Gecersiz rol'; end if;
  -- Departman YALNIZCA kaptan ve departman yöneticisi için anlamlı:
  -- kaptan hangi birimlere sipariş açacağını, departman yöneticisi hangi
  -- birimlerin verisini göreceğini oradan alıyor. Depo kademeleri ve admin
  -- tüm tesise bakar.
  if v_rol not in ('kaptan','departman_yonetici') then v_dep := 'hepsi'; end if;
  if v_dep not in ('bar','mutfak','hepsi') then raise exception 'Gecersiz departman'; end if;
  -- kod küçük harfe normalize edilir (giriş kasadan bağımsız çalışsın)
  insert into kaptan (kod, ad, pin, aktif, departman, rol)
  values (lower(p_kod), left(p_ad,60), extensions.crypt(p_pin, extensions.gen_salt('bf', 10)), true, v_dep, v_rol)
  on conflict (kod) do update set ad = excluded.ad, pin = excluded.pin, aktif = true,
                                  departman = excluded.departman, rol = excluded.rol;
  -- Rol/PIN değişmiş olabilir: açık oturumlar kapansın, yeni kimlikle girsin.
  perform oturum_kapat_kisi(p_kod);
  return jsonb_build_object('ok', true);
end $$;

-- Rolü tek başına değiştirmek (kişiyi silip yeniden eklemeden).
create or replace function public.kaptan_rol(p_token text, p_kod text, p_rol text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
  if not oturum_admin(p_token) then raise exception 'Oturum gecersiz veya suresi dolmus'; end if;
  if coalesce(p_rol,'') not in ('kaptan','depo_personel','depo_asistan','depo_yonetici','departman_yonetici','admin') then raise exception 'Gecersiz rol'; end if;
  -- Parola kuralı role göre: sayısal PIN'li biri admin yapılırsa parolası
  -- kurala uymaz. Rolü değiştiren admin yeni parolayı ayrıca atamalı.
  update kaptan set rol = p_rol,
                    departman = case when p_rol in ('kaptan','departman_yonetici')
                                     then departman else 'hepsi' end
   where lower(kod) = lower(coalesce(p_kod,''));
  if not found then raise exception 'Kullanici bulunamadi'; end if;
  -- Rol değişti: eski tipteki oturumu artık yanlış ekrana ait, kapat.
  perform oturum_kapat_kisi(p_kod);
  return jsonb_build_object('ok', true);
end $$;

-- Admin: kaptan sil
create or replace function public.kaptan_sil(p_token text, p_kod text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
  if not oturum_admin(p_token) then raise exception 'Oturum gecersiz veya suresi dolmus'; end if;
  perform oturum_kapat_kisi(p_kod);             -- silinen kişinin oturumları kapanır
  delete from kaptan where lower(kod) = lower(coalesce(p_kod,''));
  if not found then raise exception 'Kaptan bulunamadi'; end if;
  return jsonb_build_object('ok', true);
end $$;

-- Admin: kaptan departman değiştir
create or replace function public.kaptan_departman(p_token text, p_kod text, p_departman text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
  if not oturum_admin(p_token) then raise exception 'Oturum gecersiz veya suresi dolmus'; end if;
  if coalesce(p_departman,'') not in ('bar','mutfak','hepsi') then raise exception 'Gecersiz departman'; end if;
  update kaptan set departman = p_departman where lower(kod) = lower(coalesce(p_kod,''));
  if not found then raise exception 'Kaptan bulunamadi'; end if;
  return jsonb_build_object('ok', true);
end $$;

-- Admin: kaptan PIN (şifre) SIFIRLA (unutulan PIN için; eski PIN gerekmez)
create or replace function public.kaptan_pin_degistir(p_token text, p_kod text, p_pin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
  if not oturum_admin(p_token) then raise exception 'Oturum gecersiz veya suresi dolmus'; end if;
  if not sifre_kurali_uygun((select rol from kaptan where lower(kod) = lower(coalesce(p_kod,''))), p_pin) then
    raise exception '%', sifre_kurali_metni((select rol from kaptan where lower(kod) = lower(coalesce(p_kod,''))));
  end if;
  update kaptan set pin = extensions.crypt(p_pin, extensions.gen_salt('bf', 10))
   where lower(kod) = lower(coalesce(p_kod,''));
  if not found then raise exception 'Kaptan bulunamadi'; end if;
  perform oturum_kapat_kisi(p_kod);             -- admin sıfırladı: oturumlar kapanır
  return jsonb_build_object('ok', true);
end $$;

-- Kaptan KENDİ şifresini değiştirir: eski PIN'i bilmek yeterli (admin şifresi GEREKMEZ).
create or replace function public.kaptan_sifre_degistir(p_token text, p_eski_pin text, p_yeni_pin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v_kimlik jsonb; v_kod text;
begin
  -- Kural kontrolü kimlik çözüldükten SONRA (rolü bilmemiz gerekiyor).
  -- Kimlik OTURUMDAN gelir; ek olarak eski PIN sorulur (açık oturumu ele
  -- geçiren PIN değiştirip hesabı devralamasın).
  -- oturum_kisi: kaptan VE depo oturumlarını çözer. oturum_kaptan yalnızca
  -- tip='kaptan' bakıyor; depo rolündeki kişi kendi PIN'ini değiştiremezdi.
  v_kimlik := oturum_kisi(p_token);
  if not (v_kimlik->>'ok')::boolean then return v_kimlik; end if;
  v_kod := v_kimlik->>'kod';
  if not sifre_kurali_uygun(v_kimlik->>'rol', p_yeni_pin) then
    raise exception '%', sifre_kurali_metni(v_kimlik->>'rol');
  end if;
  if not exists (select 1 from kaptan where lower(kod) = lower(v_kod)
                  and pin = extensions.crypt(coalesce(p_eski_pin,''), pin)) then
    raise exception 'Eski PIN hatali';
  end if;
  update kaptan set pin = extensions.crypt(p_yeni_pin, extensions.gen_salt('bf', 10))
   where lower(kod) = lower(v_kod);
  -- PIN değişti: bu kaptanın TÜM oturumları kapanır (çalınmış token dahil)
  perform oturum_kapat_kisi(v_kod);
  return jsonb_build_object('ok', true);
end $$;



-- ================= SİPARİŞ GERİ ÇAĞIRMA (kaptan) =================
-- Depo henüz ONAYLAMADIYSA kaptan kendi biriminin siparişini geri çağırabilir:
-- düzeltip yeniden gönderir ya da tamamen iptal eder. Kayıt silinmez, iz kalır.

-- O birimin BUGÜNKÜ siparişleri. İPTAL EDİLENLER DE DÖNER: kaptan ekranı
-- iptal edilmiş siparişi "kim iptal etti" bilgisiyle gösteriyor, o yüzden
-- durum süzgeci bilerek yok. (Eski yorum "iptal olanlar dönmez" diyordu ama
-- sorguda öyle bir filtre hiç olmadı.)
create or replace function public.bekleyen_siparisler(
  p_outlet_kod text, p_bolum text, p_token text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  v_tarih date := (now() at time zone 'Europe/Istanbul')::date;
  v_kimlik jsonb; v_tur text;
begin
  v_kimlik := oturum_kaptan(p_token);
  -- RAISE ETME: sayaç kaydı geri alınır (bkz. kaptan_dogrula notu).
  if not (v_kimlik->>'ok')::boolean then return v_kimlik; end if;

  -- YATAY YETKİ: eskiden yalnızca PIN doğrulanıyor, p_outlet_kod hiç
  -- denetlenmiyordu — geçerli PIN'i olan HERHANGİ bir kaptan, HERHANGİ bir
  -- birimin günlük siparişlerini kalem detayıyla okuyabiliyordu. Kural artık
  -- siparis_gonder / siparis_geri_cagir ile aynı: departman eşleşmeli.
  select tur into v_tur from outletler where kod = p_outlet_kod;
  if v_tur is null then raise exception 'Gecersiz outlet'; end if;
  if not kaptan_birim_yetkili(v_kimlik->>'departman', v_tur) then
    raise exception 'Bu birime yetkiniz yok';
  end if;

  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'siparis_no', siparis_no,
             'saat', to_char(gonderilme_saati at time zone 'Europe/Istanbul','HH24:MI'),
             'kalem', jsonb_array_length(kalemler),
             'durum', durum, 'gonderen', gonderen, 'iptal_eden', iptal_eden,
             'kalemler', kalemler, 'teslim_durum', teslim_durum,
             'teslim_eden', teslim_eden, 'teslim_not', teslim_not,
             'teslim_saati', teslim_saati)
             order by gonderilme_saati desc)
      from siparisler
     where tarih = v_tarih and outlet_kod = p_outlet_kod
       and coalesce(bolum,'') = coalesce(nullif(p_bolum,''),'')), '[]'::jsonb);
end $$;

-- Siparişi geri çağır (iptal et) ve kalemlerini döndür.
-- Yalnız BUGÜN + durum='talep' olan sipariş geri çağrılabilir.
create or replace function public.siparis_geri_cagir(
  p_siparis_no text, p_token text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  v_ad text; v_dep text; v_tur text; v_kalemler jsonb;
  v_tarih date; v_outlet text; v_kimlik jsonb;
  v_bugun date := (now() at time zone 'Europe/Istanbul')::date;
begin
  v_kimlik := oturum_kaptan(p_token);
  -- RAISE ETME: sayaç kaydı geri alınır (bkz. kaptan_dogrula notu).
  if not (v_kimlik->>'ok')::boolean then return v_kimlik; end if;
  v_ad  := v_kimlik->>'ad';
  v_dep := v_kimlik->>'departman';

  select tarih, outlet_kod into v_tarih, v_outlet
    from siparisler where siparis_no = p_siparis_no;
  if v_tarih is null then raise exception 'Siparis bulunamadi'; end if;
  if v_tarih <> v_bugun then raise exception 'Yalnizca bugunku siparis geri cagirilabilir'; end if;

  -- Departman kuralı (bar personeli mutfak siparişini geri çağıramaz)
  select tur into v_tur from outletler where kod = v_outlet;
  if coalesce(v_dep,'hepsi') <> 'hepsi' and v_dep <> coalesce(v_tur,'bar') then
    raise exception 'Bu birime yetkiniz yok';
  end if;

  -- ATOMİK: yalnız hâlâ 'talep' ise iptale çevir. Depo aynı anda onaylıyorsa
  -- hangisi önce davranırsa o kazanır; diğeri buradan net hata alır.
  update siparisler
     set durum = 'iptal', iptal_saati = now(), iptal_eden = v_ad
   where siparis_no = p_siparis_no and durum = 'talep'
  returning kalemler into v_kalemler;
  if v_kalemler is null then
    raise exception 'Bu siparis artik geri cagirilamaz (depo islem yapmis olabilir)';
  end if;

  return jsonb_build_object('ok', true, 'kalemler', v_kalemler);
end $$;


-- Teslim onayı: depo onayladıktan sonra kaptan ne verildiğini görür ve
-- "teslim aldım" der ya da itiraz eder. Stok/Excel/tüketim ETKİLENMEZ —
-- bu yalnızca mutabakat kaydıdır.
create or replace function public.siparis_teslim(
  p_siparis_no text, p_durum text, p_not text,
  p_token text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  v_ad text; v_dep text; v_tur text; v_durum text; v_tarih date; v_outlet text;
  v_kimlik jsonb;
  v_bugun date := (now() at time zone 'Europe/Istanbul')::date;
begin
  if coalesce(p_durum,'') not in ('alindi','itiraz') then
    raise exception 'Gecersiz teslim durumu';
  end if;

  v_kimlik := oturum_kaptan(p_token);
  -- RAISE ETME: sayaç kaydı geri alınır (bkz. kaptan_dogrula notu).
  if not (v_kimlik->>'ok')::boolean then return v_kimlik; end if;
  v_ad  := v_kimlik->>'ad';
  v_dep := v_kimlik->>'departman';

  select durum, tarih, outlet_kod into v_durum, v_tarih, v_outlet
    from siparisler where siparis_no = p_siparis_no;
  if v_durum is null then raise exception 'Siparis bulunamadi'; end if;
  if v_tarih <> v_bugun then raise exception 'Yalnizca bugunku siparis onaylanabilir'; end if;
  if v_durum <> 'onaylandi' then raise exception 'Once depo onaylamali'; end if;

  select tur into v_tur from outletler where kod = v_outlet;
  if coalesce(v_dep,'hepsi') <> 'hepsi' and v_dep <> coalesce(v_tur,'bar') then
    raise exception 'Bu birime yetkiniz yok';
  end if;

  update siparisler
     set teslim_durum = p_durum,
         teslim_saati = now(),
         teslim_eden  = v_ad,
         teslim_not   = nullif(left(coalesce(p_not,''), 200), '')
   where siparis_no = p_siparis_no;

  return jsonb_build_object('ok', true, 'teslim_durum', p_durum, 'teslim_eden', v_ad);
end $$;

-- ================= İZİNLER (anon yalnızca fonksiyonları çağırır) =================
revoke all on all functions in schema public from public;

-- outlet_giris ARTIK ANON'A ACIK DEGIL: kimlik kaptan modeline gecti, client cagirmiyor.
-- (Fonksiyon duruyor ama disaridan cagrilamaz; anon icin PIN deneme/outlet adi sizintisi kapandi.)
revoke execute on function public.outlet_giris(text, text) from anon;
grant execute on function public.katalog_getir(text, text)              to anon;
grant execute on function public.stok_gizli_kodlar(text)                        to anon;
grant execute on function public.siparis_gonder(text, text, jsonb, text, text, text)       to anon;
grant execute on function public.bekleyen_siparisler(text, text, text)          to anon;
grant execute on function public.siparis_geri_cagir(text, text)                 to anon;
grant execute on function public.siparis_teslim(text, text, text, text)         to anon;
grant execute on function public.depo_giris(text)                                     to anon;
grant execute on function public.admin_giris(text)                                    to anon;
grant execute on function public.oturum_iptal(text)                                   to anon;
grant execute on function public.kaptan_giris(text, text)                             to anon;
grant execute on function public.kaptan_liste(text)                                   to anon;
grant execute on function public.kaptan_ekle(text, text, text, text, text, text)      to anon;
grant execute on function public.kaptan_rol(text, text, text)                         to anon;
grant execute on function public.kaptan_sil(text, text)                               to anon;
grant execute on function public.kaptan_departman(text, text, text)                   to anon;
grant execute on function public.kaptan_pin_degistir(text, text, text)                to anon;
grant execute on function public.kaptan_sifre_degistir(text, text, text)              to anon;
grant execute on function public.depo_liste(text, date)                               to anon;
grant execute on function public.depo_envanter(text, date, date)                      to anon;
grant execute on function public.depo_kalem_guncelle(text, text, text, int)           to anon;
grant execute on function public.depo_durum_degistir(text, text, text)                to anon;
grant execute on function public.onay_stok_kontrol(text, text)                        to anon;
grant execute on function public.stok_baseline(text, jsonb, boolean)                  to anon;
grant execute on function public.stok_malkabul(text, jsonb, boolean)                  to anon;
grant execute on function public.stok_yukleme_liste(text, int)                        to anon;
grant execute on function public.stok_yukleme_geri_al(text, uuid)                     to anon;
grant execute on function public.stok_liste(text)                                     to anon;
grant execute on function public.stok_katalog_disi_sil(text, jsonb)                   to anon;
grant execute on function public.stok_temizle(text)                                   to anon;
grant execute on function public.katalog_giris(text)                                  to anon;
grant execute on function public.katalog_seed(text, text, jsonb)                      to anon;
grant execute on function public.katalog_ekle(text, text, text, text, text, text)     to anon;
grant execute on function public.katalog_cikar(text, text, text)                      to anon;
grant execute on function public.katalog_duzelt(text, text, text, text, text, text)   to anon;
grant execute on function public.katalog_sira(text, text, jsonb)                      to anon;
grant execute on function public.urun_min_ayarla(text, text, numeric)                 to anon;
grant execute on function public.urun_minstok_ayarla(text, text, numeric)             to anon;
grant execute on function public.outlet_liste(text)                                   to anon;
grant execute on function public.outlet_pin_liste(text, text)                         to anon;
grant execute on function public.outlet_pin_ekle(text, text, text, text)              to anon;
grant execute on function public.outlet_pin_sil(text, uuid)                           to anon;
