/* depo.html ve admin.html: şifreyle giriş, token'la oturum sürdürme.
   İki sayfa aynı akışı kullandığı için testler ortak yazıldı. */

const { ok, tarayiciKur } = require("./yardimci");

const SAYFALAR = [
  { sayfa: "depo.html",  girisRpc: "depo_giris",  anahtar: "gurok_depo",  eskiSifre: "gurok_depo_sifre" },
  { sayfa: "admin.html", girisRpc: "admin_giris", anahtar: "gurok_admin", eskiSifre: "gurok_admin_sifre" },
];

module.exports = async function () {

for (const s of SAYFALAR) {
  const kur = o => tarayiciKur(Object.assign({
    sayfa: s.sayfa,
    dosyalar: ["veri.js", "mutfak.js", "ortak.js", "tuketim.js", "mutabakat.js", "depo_sablon.js"],
  }, o));

  console.log("\n########## " + s.sayfa + " ##########");

  console.log("=== 1. Doğru şifre ===");
  {
    const t = kur({ rpc: ad => ad === s.girisRpc
      ? { data: { ok: true, token: "TKN_S" }, error: null } : { data: [], error: null } });
    t.getEl("sifre").value = "cokGizliSifre";
    await t.ev("giris()");
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
    await t.ev("giris()");
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
    await t.ev("giris()");
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
    ok("şifre kutusu boş", t.getEl("sifre").value === "");
    if (s.sayfa === "depo.html") {
      // Otomatik tazeleme 15 saniyede bir sorgu atıyor; durdurulmazsa
      // çıkıştan sonra ölü token ile sorgulamaya devam ederdi.
      ok("otomatik tazeleme durduruldu",
          t.zamanlayicilar.acilan.length > 0 &&
          t.zamanlayicilar.kapanan.length >= t.zamanlayicilar.acilan.length,
          "acilan=" + t.zamanlayicilar.acilan.length + " kapanan=" + t.zamanlayicilar.kapanan.length);
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

};

if (require.main === module) {
  const { sonuc } = require("./yardimci");
  module.exports().then(() => process.exit(sonuc() ? 0 : 1));
}
