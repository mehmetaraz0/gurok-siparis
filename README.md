# GUROK Sipariş Sistemi

ALI BEY CLUB MANAVGAT — 22 outlet, 3.408 kalem, LN Infor Excel çıktısı.

Eski tek dosyalık `siparis_sistemi.html` ikiye ayrıldı: barlar kendi ekranından sipariş
gönderir, depo hepsini tek ekranda toplu görür. İki sayfa Supabase üzerinden birbirine bağlıdır.

| Sayfa | Kim kullanır | Ne yapar |
|---|---|---|
| `bar.html` | Bar / restoran personeli | **Bar kodunu girer** (201, 315...), miktar girer, **Siparişi Gönder** |
| `depo.html` | Depo sorumlusu | Şifreyle girer, tüm siparişleri konsolide görür, Excel indirir |

## Bar kodları

Personel bar.html'i açtığında bu üç haneli kodu girer, kendi barının listesi gelir.

| Kod | Bar | | Kod | Bar |
|---|---|---|---|---|
| **201** | ALIBEY RESTAURANT | | **308** | KARAGOZ |
| **202** | PARK RESTAURANT | | **310** | ILICA BAR |
| **204** | SAHIL RESTAURANT | | **311** | HARLEK |
| **205** | AQUA RESTAURANT | | **312** | HISAR |
| **206** | KIYI RESTAURANT | | **313** | YONCALI |
| **301** | TURK KAHVESI | | **314** | FRIG BEACH BAR |
| **302** | CARDAK | | **315** | PAVILLION BAR |
| **303** | TALVAR | | **316** | LOBBY BAR |
| **304** | POOL | | **317** | PARK TURK KAHVESI |
| **305** | ALI'S PUB | | **318** | SARAP VE BIRA EVI |
| **306** | TENIS BAR | | | |
| **307** | KONAK | | | |

`315`, `csm315`, `CSM315` yazımlarının hepsi kabul edilir. Kod sekme oturumunda tutulur:
sayfa yenilenince tekrar sorulmaz, sekme kapanınca sorulur. Başlıktaki **↔ Bar Değiştir**
ile koda dönülür.

## Dosyalar

| Dosya | İçerik |
|---|---|
| `index.html` | İki sayfaya yönlendiren kapak |
| `bar.html` | Sipariş girişi ekranı |
| `depo.html` | Depo toplama ekranı |
| `ortak.js` | **Excel üretimi** + Supabase istemcisi + yardımcılar |
| `veri.js` | Ürün kataloğu (`D`), Excel şablonu (`TPL_B64`), satır şablonu (`ROW2`), grup renkleri (`GC`) — *otomatik üretildi* |
| `stil.css` | Ortak stiller |
| `config.js` | Supabase adresi ve anon key |
| `kurulum.sql` | Supabase kurulumu — bir kez çalıştırılır |

Excel üretimi `ortak.js` içinde **tek** `buildExcelBlob()` fonksiyonundadır. Eski sürümde
aynı kurgu `dlExcel()` ve `dlAllExcel()` içinde iki ayrı kopya halindeydi; artık bar da depo
da aynı kodu çağırdığı için üretilen dosya birebir aynıdır.

## Kurulum

### 1. Supabase

1. Supabase panelinde **SQL Editor → New query**
2. `kurulum.sql` dosyasını yapıştır
3. İçindeki `BURAYA_SIFRE_YAZ` yerine depo şifreni yaz
4. **Run**

Şifreyi sonra değiştirmek için `kurulum.sql` içindeki `insert into public.ayarlar ...`
satırını yeni şifreyle tekrar çalıştırman yeterli.

### 2. GitHub Pages

1. Yeni bir repo aç
2. Bu klasördeki dosyaları yükle
3. **Settings → Pages → Source: Deploy from a branch → main / (root)**
4. Birkaç dakika sonra adres hazır:
   - Bar: `https://<kullanici>.github.io/<repo>/bar.html`
   - Depo: `https://<kullanici>.github.io/<repo>/depo.html`

## Güvenlik

`config.js` içindeki anon key tarayıcıda açıktadır — Supabase'de bu **tasarım gereğidir**,
gizli bir bilgi değildir. Korumayı veritabanı tarafı sağlar:

- `siparisler` ve `ayarlar` tablolarında RLS açık ve **hiçbir policy yok** → anon key ile
  bu tablolara doğrudan erişilemez, okunamaz, yazılamaz.
- Tüm erişim üç `SECURITY DEFINER` fonksiyonundan geçer:
  - `siparis_gonder` — bar sipariş yazar (outlet kodu ve kalem listesi doğrulanır)
  - `siparis_getir` — bar **sadece kendi** o günkü siparişini okur
  - `depo_liste` — şifre doğruysa o günün tüm siparişlerini döner
- Depo şifresi bcrypt ile saklanır, düz metin hiçbir yerde durmaz, doğrulama sunucuda yapılır.

Bilinen ve kabul edilmiş sınır: **bar kodu bir şifre değildir.** `201`, `315` gibi kodlar
tahmin edilebilir ve doğrulama tarayıcıda yapılır — amacı personeli doğru outlet'e
yönlendirmek, yanlış bara sipariş girilmesini önlemektir. Linki bilen biri sahte sipariş
gönderebilir. Gerçek koruma isteniyorsa `siparis_gonder` fonksiyonuna sunucu tarafında
doğrulanan bir bar şifresi eklenmelidir.

## Çalışma mantığı

**Bar tarafı**
- Kod girilince o günkü gönderilmiş sipariş varsa geri yüklenir → eksik eklenip yeniden gönderilir.
- Her miktar girişi tarayıcıya taslak olarak yazılır. Telefon kilitlenir ya da sayfa yenilenirse
  girilen miktarlar kaybolmaz. Taslak sadece o güne aittir.
- Aynı outlet aynı gün ikinci kez gönderirse **eski sipariş bu listeyle değiştirilir** (onay sorulur).
- Gönderilmemiş değişiklikle sayfadan çıkılmak istenirse tarayıcı uyarır.
- İnternet yoksa ekran çalışmaya devam eder, miktarlar taslakta durur; bağlantı gelince gönderilir.

**Depo tarafı**
- Şifre sekme oturumunda tutulur; sayfa yenilenince tekrar sorulmaz, sekme kapanınca silinir.
- Liste 15 saniyede bir kendini yeniler.
- Tarih seçiciyle geçmiş günlere bakılabilir.
- Durum şeridi hangi outlet'in gönderdiğini, hangisinin beklendiğini gösterir.
- **Tüm Siparişleri İndir** → gönderen her outlet için ayrı bir LN Infor `.xlsx` dosyası.

## Katalog güncellemesi

Ürün listesi değişirse `veri.js` içindeki `const D = [...]` satırı yenisiyle değiştirilir.
Dosyanın geri kalanına (`TPL_B64`, `ROW2`, `GC`) dokunulmaz.

## Bakım notu

Bu sürümde düzeltilen hata: ürün adındaki `&` karakteri XML'e kaçışlanmadan yazılıyordu.
Katalogda `&` içeren 5 farklı ürün var (`ICE TEA MANGO&ANANAS`, `KOKTEYL MIX PETBUER&ALMON`,
`CHIWAS SMOOTH&SMOKY 70CL`, `CHIWAS SMOOTH&SMOKY 100 CL`, `TEQUILA SIP&SIP`). Bunlardan biri
siparişe girildiğinde eski sürüm bozuk `.xlsx` üretiyor, Excel dosyayı açmayı reddediyordu.
