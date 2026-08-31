# Sunucu (SQL) testleri

```bash
bash test/sql/calistir.sh
```

Gereken tek şey **docker**. Geçici bir Postgres 16 kapsayıcısı açar, işi
bitince siler. Canlı veritabanına dokunmaz.

## Neden gerekli

İki şeyi başka türlü doğrulayamıyoruz:

**1. `kurulum.sql`'in gerçekten çalıştığını.** Dosyanın büyük kısmı PL/pgSQL.
SQL ayrıştırıcıları fonksiyon gövdelerini opak metin sayar — `libpg-query`
221 ifadeyi sorunsuz ayrıştırır ama gövdelerdeki bir hatayı görmez. O hatayı
normalde ancak Supabase'e yapıştırınca öğrenirsiniz. Burada önce öğrenirsiniz.

**2. Canlıda denenemeyecek davranışları.** Brute-force kilidi bunların
başında geliyor: canlıda 5 yanlış şifre girmek depo personelini 15 dakika
dışarıda bırakır. Burada serbestçe denenir.

## Ne koşuyor

| Adım | Doğrulanan |
|---|---|
| 1 | Yer tutucu şifreler değiştirilmemişse kurulum **durur** (denetim L-3) |
| 2 | Gerçek şifrelerle kurulum baştan sona tamamlanır |
| 3 | Aynı betik ikinci kez hatasız çalışır (idempotentlik — sizin sürekli yaptığınız şey) |
| 4 | 45 güvenlik doğrulaması (`guvenlik.sql`) |

`guvenlik.sql` içindekiler:

- Token 64 hane, veritabanında **düz değil sha256 hash** olarak duruyor
- Sahte / boş / süresi dolmuş token reddediliyor
- Yanlış şifre denemesi **kaydediliyor** — H-2'nin özü: giriş fonksiyonları
  `raise` etseydi transaction geri alınır ve sayaç hiç artmazdı
- **Brute-force kilidi**: 5 denemeden sonra kilit, kilitliyken doğru şifre bile
  reddediliyor, kilit düşünce yeniden çalışıyor
- Başarılı giriş sayacı sıfırlıyor
- **Yatay yetki (M-3) iki yönlü**: bar kaptanı mutfak listesini göremiyor,
  mutfak kaptanı bar listesini göremiyor, kimse başka birim adına sipariş açamıyor
- PIN değişince o kaptanın **tüm** oturumları kapanıyor (çalınmış token dahil),
  eski PIN çalışmıyor
- Yanlış eski PIN ile değişim reddediliyor
- Çıkış sonrası token geçersiz; kaptan silinince oturumu da siliniyor
- Şifreler bcrypt, PIN düz metin değil

## Dosyalar

- `calistir.sh` — kapsayıcıyı açar, adımları sırayla koşar, temizler
- `onhazirlik.sql` — Supabase'in sağladığı ama vanilla Postgres'te olmayan
  parçalar (`extensions` şeması, `anon` / `authenticated` rolleri)
- `guvenlik.sql` — asıl testler

## Bilinen tuzaklar (ikisi de yaşandı)

- **`pg_isready` kullanmayın.** postgres imajı kurulum sırasında önce yalnızca
  unix soketinde dinleyen geçici bir sunucu açar; `pg_isready` ona da "hazır"
  der, sonra sunucu yeniden başlar ve bir sonraki komut patlar. Betik bu yüzden
  TCP üzerinden gerçek bir sorguyla bekliyor.
- **Git Bash'te `docker cp` yerel yolu.** `MSYS_NO_PATHCONV=1` kapsayıcı
  içindeki `/tmp` yolunun bozulmasını engelliyor ama yerel yolu da
  çevirmiyor; Docker `/d/...` yolunu anlamayıp `GetFileAttributesEx D:\d`
  diyor. Betik yerel yolları `cygpath -w` ile çeviriyor.
