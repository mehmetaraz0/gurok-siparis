# Testler

Bağımlılık yok, kurulum yok. Node yeterli:

```bash
node test/calistir.js
```

Tek dosya çalıştırmak için: `node test/bar.test.js`

## Ne test ediliyor

Bu testler **kimlik ve oturum akışlarını** hedefler — canlıda bozulduğunda en
pahalıya mal olan ve tarayıcıda elle denemesi en zahmetli olan yer burası.

| Dosya | Kapsam |
|---|---|
| `sozdizimi.test.js` | Her `.js` ve her inline `<script>` ayrıştırılabiliyor mu (ESM blokları dahil) |
| `ortak.test.js` | Token üretimi/saklama/iptali, `yetkiArg`/`kaptanArg`, `katalogGetir`, `stokGizliYukle`, `miktarHaritasiTemizle` |
| `bar.test.js` | Kaptan girişi, sayfa yenileme, PIN değiştirme, çıkış |
| `depo-admin.test.js` | Depo/admin şifreyle giriş, kilit mesajı, token'la oturum sürdürme |

Özellikle korunan davranışlar:

- **Şifre/PIN hiçbir yere yazılmaz.** Ne `sessionStorage`'a, ne giriş dışındaki
  bir RPC'ye. (Denetim bulgusu M-1)
- **Eski `p_sifre`/`p_kaptan_pin` yoluna düşülmez.** Yanlış şifrede tek RPC
  çağrısı olmalı; ikinci bir deneme geçiş shim'inin geri geldiği anlamına gelir.
  (Denetim bulgusu N-2)
- **Sayfa yenilendikten sonra da her şey çalışır.** PIN artık bellekte olmadığı
  için "PIN varsa" koşuluna bağlı kalan kod sessizce çalışmayı bırakıyordu;
  stok gizleme ve PIN değiştirme bu yüzden bozulmuştu.
- **PIN değişince oturum kapanır.** Sunucu `oturum_kapat_tumu` çağırdığı için
  eldeki token ölür; istemci kullanıcıyı yeniden girişe yollamalı.

## Nasıl çalışıyor

`yardimci.js` Node'un `vm` modülüyle sahte bir tarayıcı kurar (sessionStorage,
document, prompt/alert, sahte Supabase istemcisi) ve **gerçek dosyaları** —
`ortak.js` ile HTML'lerin inline `<script>` bloğunu — olduğu gibi çalıştırır.
Kopya kod yok; test edilen şey canlıya giden kodun ta kendisi.

Bir ayrıntı: `ortak.js` üst düzeyde `const SB` / `let TOKEN` kullanıyor.
Bunlar vm bağlamında nesne özelliği olmaz, o yüzden testler `t.ev("TOKEN")`
gibi ifadelerle okur.

## Yeni test eklerken

Testin gerçekten hata yakaladığını doğrulayın: kodu kasten bozup testin
kırmızıya döndüğünü görün, sonra geri alın. Her zaman yeşil yanan test
yoktan beterdir.
