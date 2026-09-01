/* depo.html ve admin.html: giriş, oturum sürdürme, çıkış.

   Depo'nun İKİ giriş yolu var:
     giris()            -> kullanıcı adı + PIN (kişisel, kalıcı yol)
     ortakSifreGiris()  -> herkesin bildiği ortak şifre (GEÇİCİ, kapatılacak)
   Admin yalnızca ortak şifre kullanıyor.                                     */

const { ok, tarayiciKur, KOK } = require("./yardimci");

const DEPO_DOSYALARI = ["veri.js", "mutfak.js", "ortak.js", "tuketim.js", "mutabakat.js", "depo_sablon.js"];

const SAYFALAR = [
  { sayfa: "depo.html",  girisRpc: "depo_giris",  anahtar: "gurok_depo",
    eskiSifre: "gurok_depo_sifre",  fn: "ortakSifreGiris()", dosyalar: DEPO_DOSYALARI },
  { sayfa: "admin.html", girisRpc: "admin_giris", anahtar: "gurok_admin",
    eskiSifre: "gurok_admin_sifre", fn: "giris()",           dosyalar: DEPO_DOSYALARI },
];

module.exports = async function () {

/* ================= Ortak şifre ile giriş (iki sayfa da) ================= */

for (const s of SAYFALAR) {
  const kur = o => tarayiciKur(Object.assign({ sayfa: s.sayfa, dosyalar: s.dosyalar }, o));

  console.log("\n########## " + s.sayfa + " — ortak şifre ##########");

  console.log("=== 1. Doğru şifre ===");
  {
    const t = kur({ rpc: ad => ad === s.girisRpc
      ? { data: { ok: true, token: "TKN_S" }, error: null } : { data: [], error: null } });
    t.getEl("sifre").value = "cokGizliSifre";
    await t.ev(s.fn);
    ok("giriş bayrağı açıldı", t.ev("GIRISLI") === true);
    ok("TOKEN alındı", t.ev("TOKEN") === "TKN_S");
    ok("token saklandı", t.ss.getItem(s.anahtar + "_token") === "TKN_S");
    ok("şifre hiçbir yere yazılmadı",
        !Array.from(t.ss._map.values()).some(v => String(v).indexOf("cokGizliSifre") >= 0),
        JSON.stringify(Array.from(t.ss._map.entries())));
    const sifreGecen = t.cagrilar.filter(c => JSON.stringify(c.arg || {}).indexOf("cokGizliSifre") >= 0);
    ok("şifre yalnızca giriş RPC'sine gitti",
        sifreGecen.length === 1 && sifreGecen[0].ad === s.girisRpc,
        JSON.stringify(sifreGecen.map(c => c.ad)));
    ok("sonraki çağrılar token ile",
        t.cagrilar.filter(c => c.ad !== s.girisRpc).every(c => !c.arg || c.arg.p_sifre === undefined));
  }

  console.log("=== 2. Yanlış şifre ===");
  {
    const t = kur({ rpc: () => ({ data: { ok: false, hata: "Sifre hatali" }, error: null }) });
    t.getEl("sifre").value = "yanlis";
    await t.ev(s.fn);
    ok("giriş yapılmadı", t.ev("GIRISLI") === false);
    ok("TOKEN yok", t.ev("TOKEN") === null);
    ok("hata gösterildi", /Şifre hatalı/.test(t.getEl("hata").textContent), t.getEl("hata").textContent);
    // N-2: eski p_sifre yolu silindi; ikinci bir deneme OLMAMALI.
    ok("eski şifre yoluna düşmedi (tek RPC)", t.cagrilar.length === 1,
        JSON.stringify(t.cagrilar.map(c => c.ad)));
    ok("şifre kutusu temizlendi", t.getEl("sifre").value === "");
  }

  console.log("=== 3. Kilitli hesap ===");
  {
    const t = kur({ rpc: () => ({ data: { ok: false,
      hata: "Cok fazla hatali deneme. 15 dakika sonra tekrar deneyin." }, error: null }) });
    t.getEl("sifre").value = "x";
    await t.ev(s.fn);
    ok("kilit mesajı ekranda", /Çok fazla hatalı deneme/.test(t.getEl("hata").textContent),
        t.getEl("hata").textContent);
  }

  console.log("=== 4. Yenileme: token'la oturum sürüyor ===");
  {
    const t = kur({ oturum: [[s.anahtar + "_token", "TKN_Y"], [s.anahtar + "_zaman", String(Date.now())]],
                    rpc: () => ({ data: [], error: null }) });
    ok("giriş bayrağı açık", t.ev("GIRISLI") === true);
    ok("TOKEN yüklendi", t.ev("TOKEN") === "TKN_Y");
  }

  console.log("=== 5. Eski sürümden kalan düz şifre kaydı temizleniyor ===");
  {
    const t = kur({ oturum: [[s.eskiSifre, "ESKI_DUZ_SIFRE"], [s.anahtar + "_zaman", String(Date.now())]],
                    rpc: () => ({ data: [], error: null }) });
    ok("düz şifre kaydı silindi", t.ss.getItem(s.eskiSifre) === null);
    ok("şifreyle otomatik giriş yapılmadı", t.ev("GIRISLI") === false);
  }

  console.log("=== 6. Çıkış ===");
  {
    // Paylaşılan bilgisayar: oturumu kasten kapatabilmek şart.
    const t = kur({ oturum: [[s.anahtar + "_token", "TKN_C"], [s.anahtar + "_zaman", String(Date.now())]],
                    rpc: () => ({ data: { ok: true }, error: null }) });
    ok("önce giriş yapılmış", t.ev("GIRISLI") === true);
    await t.ev("cikisYap()");
    ok("sunucuya oturum_iptal gitti",
        t.cagrilar.some(c => c.ad === "oturum_iptal" && c.arg.p_token === "TKN_C"),
        JSON.stringify(t.cagrilar.map(c => c.ad)));
    ok("TOKEN temizlendi", t.ev("TOKEN") === null);
    ok("giriş bayrağı kapandı", t.ev("GIRISLI") === false);
    ok("sessionStorage'daki token silindi", t.ss.getItem(s.anahtar + "_token") === null);
    ok("kilit ekranı geri geldi", t.getEl("kilit").style.display === "");
    ok("ana ekran gizlendi", t.getEl("ana").style.display === "none");
    if (s.sayfa === "depo.html") {
      // Otomatik tazeleme 15 saniyede bir sorgu atıyor; durdurulmazsa
      // çıkıştan sonra ölü token ile sorgulamaya devam ederdi.
      ok("otomatik tazeleme durduruldu",
          t.zamanlayicilar.acilan.length > 0 &&
          t.zamanlayicilar.kapanan.length >= t.zamanlayicilar.acilan.length,
          "acilan=" + t.zamanlayicilar.acilan.length + " kapanan=" + t.zamanlayicilar.kapanan.length);
      ok("kimlik temizlendi", t.ev("DEPOCU") === null);
    } else {
      ok("şifre kutusu boş", t.getEl("sifre").value === "");
    }
  }

  console.log("=== 7. Oturum süresi dolmuş ===");
  {
    const t = kur({ oturum: [[s.anahtar + "_token", "ESKI"],
                             [s.anahtar + "_zaman", String(Date.now() - 13 * 3600 * 1000)]],
                    rpc: () => ({ data: [], error: null }) });
    ok("giriş yapılmadı", t.ev("GIRISLI") === false);
    ok("TOKEN yüklenmedi", t.ev("TOKEN") === null);
  }
}

/* ================= Depo: kullanıcı adı + PIN ================= */

const depoKur = o => tarayiciKur(Object.assign({ sayfa: "depo.html", dosyalar: DEPO_DOSYALARI }, o));

console.log("\n########## depo.html — kullanıcı adı + PIN ##########");

console.log("=== 8. Doğru kullanıcı adı + PIN ===");
{
  const t = depoKur({ rpc: ad => ad === "kaptan_giris"
    ? { data: { ok: true, kod: "depocu1", ad: "Depo Personeli", departman: "hepsi",
                rol: "depo", token: "TKN_D" }, error: null }
    : { data: [], error: null } });
  t.getEl("depoKod").value = "DEPOCU1";        // büyük harf de olmalı
  t.getEl("depoPin").value = "111111";
  await t.ev("giris()");
  ok("giriş yapıldı", t.ev("GIRISLI") === true);
  ok("TOKEN alındı", t.ev("TOKEN") === "TKN_D");
  ok("kim girdiği biliniyor", (t.ev("DEPOCU") || {}).ad === "Depo Personeli",
      JSON.stringify(t.ev("DEPOCU")));
  ok("ad başlıkta gösteriliyor", /Depo Personeli/.test(t.getEl("depoKim").textContent),
      t.getEl("depoKim").textContent);
  ok("PIN hiçbir yere yazılmadı",
      !Array.from(t.ss._map.values()).some(v => String(v) === "111111"),
      JSON.stringify(Array.from(t.ss._map.entries())));
  const pinGecen = t.cagrilar.filter(c => JSON.stringify(c.arg || {}).indexOf("111111") >= 0);
  ok("PIN yalnızca kaptan_giris'e gitti",
      pinGecen.length === 1 && pinGecen[0].ad === "kaptan_giris",
      JSON.stringify(pinGecen.map(c => c.ad)));
  ok("PIN kutusu temizlendi", t.getEl("depoPin").value === "");
}

console.log("=== 9. Yanlış PIN ===");
{
  const t = depoKur({ rpc: () => ({ data: { ok: false, hata: "Kaptan kodu veya PIN hatali" }, error: null }) });
  t.getEl("depoKod").value = "depocu1";
  t.getEl("depoPin").value = "000000";
  await t.ev("giris()");
  ok("giriş yapılmadı", t.ev("GIRISLI") === false);
  ok("hata gösterildi", /PIN hatalı/.test(t.getEl("hata").textContent), t.getEl("hata").textContent);
  ok("tek RPC çağrısı", t.cagrilar.length === 1, JSON.stringify(t.cagrilar.map(c => c.ad)));
}

console.log("=== 10. Kilitli kullanıcı ===");
{
  const t = depoKur({ rpc: () => ({ data: { ok: false,
    hata: "Cok fazla hatali deneme. 15 dakika sonra tekrar deneyin." }, error: null }) });
  t.getEl("depoKod").value = "depocu1";
  t.getEl("depoPin").value = "000000";
  await t.ev("giris()");
  ok("kilit mesajı ekranda", /Çok fazla hatalı deneme/.test(t.getEl("hata").textContent),
      t.getEl("hata").textContent);
}

console.log("=== 11. Kaptan hesabıyla DEPO ekranına girilemez ===");
{
  const t = depoKur({ rpc: ad => ad === "kaptan_giris"
    ? { data: { ok: true, kod: "maraz", ad: "Bir Kaptan", departman: "bar",
                rol: "kaptan", token: "TKN_K" }, error: null }
    : { data: { ok: true }, error: null } });
  t.getEl("depoKod").value = "maraz";
  t.getEl("depoPin").value = "123456";
  await t.ev("giris()");
  ok("giriş REDDEDİLDİ", t.ev("GIRISLI") === false);
  ok("açık mesaj verildi", /depo personeline ait değil/i.test(t.getEl("hata").textContent),
      t.getEl("hata").textContent);
  // Sunucuda oturum açıldı; sahipsiz bırakmadan kapatılmalı.
  ok("açılan oturum sunucuda kapatıldı",
      t.cagrilar.some(c => c.ad === "oturum_iptal" && c.arg.p_token === "TKN_K"),
      JSON.stringify(t.cagrilar.map(c => c.ad)));
  ok("TOKEN bırakılmadı", t.ev("TOKEN") === null);
}

console.log("=== 12. Yenilemeden sonra kim olduğu korunuyor ===");
{
  const t = depoKur({ oturum: [["gurok_depo_token", "TKN_R"], ["gurok_depo_zaman", String(Date.now())],
                               ["gurok_depo_ad", "Depo Personeli"]],
                      rpc: () => ({ data: [], error: null }) });
  ok("oturum sürdü", t.ev("GIRISLI") === true);
  ok("ad geri geldi", (t.ev("DEPOCU") || {}).ad === "Depo Personeli", JSON.stringify(t.ev("DEPOCU")));
  ok("başlıkta görünüyor", /Depo Personeli/.test(t.getEl("depoKim").textContent));
}

console.log("=== 13. Giriş kutuları arasında geçiş ===");
{
  // Başlangıç durumu HTML özniteliğinde; sahte DOM öznitelik okumaz, dosyaya bak.
  const html = require("fs").readFileSync(require("path").join(KOK, "depo.html"), "utf8");
  ok("başlangıçta kişisel giriş açık (ortak şifre gizli)",
      /id="ortakGiris"[^>]*style="display:none"/.test(html));

  const t = depoKur({});
  t.ev("ortakSifreGoster(true)");
  ok("ortak şifre kutusu açıldı",
      t.getEl("kisiGiris").style.display === "none" && t.getEl("ortakGiris").style.display === "");
  t.ev("ortakSifreGoster(false)");
  ok("kişisel girişe dönüldü",
      t.getEl("kisiGiris").style.display === "" && t.getEl("ortakGiris").style.display === "none");
}

};

if (require.main === module) {
  const { sonuc } = require("./yardimci");
  module.exports().then(() => process.exit(sonuc() ? 0 : 1));
}
