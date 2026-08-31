/* ortak.js: oturum token'ı, yetki argümanları, katalog/stok çağrıları. */

const { ok, tarayiciKur } = require("./yardimci");

module.exports = async function () {

console.log("\n########## ortak.js ##########");

console.log("=== 1. Depo girişi: doğru şifre ===");
{
  const t = tarayiciKur({ rpc: ad => ad === "depo_giris"
    ? { data: { ok: true, token: "TKN123" }, error: null } : { data: null, error: null } });
  const r = await t.ev('sifreIleGiris("depo_giris", "gizliSifre")');
  ok("giriş başarılı", r.ok === true, JSON.stringify(r));
  ok("token belleğe alındı", t.ev("TOKEN") === "TKN123", t.ev("TOKEN"));
  t.ev('tokenKaydet("gurok_depo")');
  ok("sessionStorage'da token var", t.ss.getItem("gurok_depo_token") === "TKN123");
  ok("sessionStorage'da ŞİFRE YOK",
      !Array.from(t.ss._map.values()).some(v => String(v).indexOf("gizliSifre") >= 0),
      JSON.stringify(Array.from(t.ss._map.entries())));
  ok("yetkiArg token gönderiyor", JSON.stringify(t.ev("yetkiArg()")) === '{"p_token":"TKN123"}');
  ok("kaptanArg token gönderiyor", JSON.stringify(t.ev("kaptanArg()")) === '{"p_token":"TKN123"}');
  ok("şifre yalnızca depo_giris'e gitti",
      t.cagrilar.length === 1 && t.cagrilar[0].ad === "depo_giris" && t.cagrilar[0].arg.p_sifre === "gizliSifre");
}

console.log("=== 2. Depo girişi: yanlış şifre ===");
{
  const t = tarayiciKur({ rpc: () => ({ data: { ok: false, hata: "Sifre hatali" }, error: null }) });
  const r = await t.ev('sifreIleGiris("depo_giris", "yanlis")');
  ok("giriş reddedildi", r.ok === false);
  ok("mesaj Türkçe", r.hata === "Şifre hatalı.", r.hata);
  ok("token yok", t.ev("TOKEN") === null);
  // N-2: eski p_sifre yolu silindi; ikinci bir RPC denemesi OLMAMALI.
  ok("eski şifre yoluna düşmedi (tek RPC)", t.cagrilar.length === 1,
      JSON.stringify(t.cagrilar.map(c => c.ad)));
}

console.log("=== 3. Depo girişi: hesap kilitli ===");
{
  const t = tarayiciKur({ rpc: () => ({ data: { ok: false,
    hata: "Cok fazla hatali deneme. 15 dakika sonra tekrar deneyin." }, error: null }) });
  const r = await t.ev('sifreIleGiris("depo_giris", "x")');
  ok("kilit mesajı kullanıcıya ulaşıyor", /Çok fazla hatalı deneme/.test(r.hata), r.hata);
}

console.log("=== 4. Yenileme: token geri yükleniyor ===");
{
  const t = tarayiciKur({});
  t.ss.setItem("gurok_depo_token", "TKN999");
  t.ev('oturumDamgala("gurok_depo")');
  ok("geri yükleme başarılı", t.ev('tokenGeriYukle("gurok_depo")') === true);
  ok("TOKEN doğru", t.ev("TOKEN") === "TKN999");
}

console.log("=== 5. Yenileme: oturum süresi dolmuş ===");
{
  const t = tarayiciKur({});
  t.ss.setItem("gurok_depo_token", "ESKI");
  t.ss.setItem("gurok_depo_zaman", String(Date.now() - 13 * 3600 * 1000));
  ok("süresi dolmuş oturum reddedildi", t.ev('tokenGeriYukle("gurok_depo")') === false);
  ok("TOKEN yüklenmedi", t.ev("TOKEN") === null);
}

console.log("=== 6. stokGizliYukle: yenilemeden SONRA da çalışıyor ===");
{
  // Regresyon: PIN artık saklanmadığı için eski "kaptan.pin yoksa sorgulama"
  // koşulu, sayfa yenilendikten sonra stok gizlemeyi tamamen kapatıyordu.
  const t = tarayiciKur({ rpc: ad => ad === "stok_gizli_kodlar"
    ? { data: ["ABC12345678", "XYZ87654321"], error: null } : { data: null, error: null } });
  t.ss.setItem("gurok_kaptan_token", "TKN_K");
  t.ev('oturumDamgala("gurok_kaptan")');
  t.ev('tokenGeriYukle("gurok_kaptan")');
  const gizli = await t.ev("stokGizliYukle()");
  ok("stok sorgusu yapıldı", t.cagrilar.some(c => c.ad === "stok_gizli_kodlar"));
  ok("gizli kodlar döndü", gizli.size === 2, "size=" + gizli.size);
  ok("sorgu token ile gitti", t.cagrilar[0] && t.cagrilar[0].arg.p_token === "TKN_K");
}

console.log("=== 7. stokGizliYukle: oturum yokken sorgu atmıyor ===");
{
  const t = tarayiciKur({ rpc: () => ({ data: [], error: null }) });
  const gizli = await t.ev("stokGizliYukle()");
  ok("boş küme", gizli.size === 0);
  ok("gereksiz RPC yok", t.cagrilar.length === 0);
}

console.log("=== 8. katalogGetir: token gönderiyor, eski imzaya düşmüyor ===");
{
  const t = tarayiciKur({ rpc: () => ({ data: [{ k: "A" }], error: null }) });
  t.ev('TOKEN = "TKN_A"');
  const d = await t.ev('katalogGetir("CSM101")');
  ok("katalog döndü", Array.isArray(d) && d.length === 1);
  ok("tek çağrı (fallback yok)", t.cagrilar.length === 1);
  ok("p_token gitti", t.cagrilar[0].arg.p_token === "TKN_A");
  ok("p_kaptan_pin gitmedi", t.cagrilar[0].arg.p_kaptan_pin === undefined);
  ok("p_sifre gitmedi", t.cagrilar[0].arg.p_sifre === undefined);
}

console.log("=== 9. katalogGetir: yetki hatası yutulmuyor ===");
{
  const t = tarayiciKur({ rpc: () => ({ data: { ok: false, hata: "Yetki gerekli" }, error: null }) });
  t.ev('TOKEN = "SAHTE"');
  ok("null döndü", (await t.ev('katalogGetir("CSM101")')) === null);
}

console.log("=== 10. Çıkış ===");
{
  const t = tarayiciKur({ rpc: () => ({ data: { ok: true }, error: null }) });
  t.ev('TOKEN = "TKN_C"');
  await t.ev("oturumuKapat()");
  ok("oturum_iptal çağrıldı", t.cagrilar.some(c => c.ad === "oturum_iptal" && c.arg.p_token === "TKN_C"));
  ok("TOKEN temizlendi", t.ev("TOKEN") === null);
  t.ev('tokenKaydet("gurok_depo")');
  ok("sessionStorage'daki token silindi", t.ss.getItem("gurok_depo_token") === null);
}

console.log("=== 11. miktarHaritasiTemizle (attribute enjeksiyonu koruması) ===");
{
  const t = tarayiciKur({});
  const kirli = { "ABC12345678": 5, '" autofocus onfocus=alert(1) x="': 3,
                  "ABC12345679": -2, "ABC12345670": "9" };
  const temiz = t.ev("miktarHaritasiTemizle(" + JSON.stringify(kirli) + ")");
  ok("geçerli kod geçti", temiz["ABC12345678"] === 5);
  ok("enjeksiyon anahtarı elendi",
      Object.keys(temiz).every(k => /^[A-Z]{3}[0-9]{8}$/.test(k)), JSON.stringify(Object.keys(temiz)));
  ok("negatif elendi", temiz["ABC12345679"] === undefined);
  ok("sayıya çevrilen geçti", temiz["ABC12345670"] === 9);
}

};

if (require.main === module) {
  const { sonuc } = require("./yardimci");
  module.exports().then(() => process.exit(sonuc() ? 0 : 1));
}
